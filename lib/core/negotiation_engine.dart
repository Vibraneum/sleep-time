import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'memory_service.dart';

enum GuardianAction {
  none,
  grant,
  deny,
  minimize,
  close,
  unlock,
  unlockApp,
  adjustSchedule,
}

class GuardianDecision {
  final String message;
  final GuardianAction action;
  final int minutesGranted;

  // Selective app-unlock payload (M1 tool-calling; data shape only in M0).
  final String? appIdentifier;
  final String? appLabel;
  final int? appMinutes;

  // Schedule-adjust payload (M1 tool-calling; data shape only in M0).
  final String? scheduleField;
  final int? scheduleHour;
  final int? scheduleMinute;
  final String? scheduleReason;

  GuardianDecision({
    required this.message,
    this.action = GuardianAction.none,
    this.minutesGranted = 0,
    this.appIdentifier,
    this.appLabel,
    this.appMinutes,
    this.scheduleField,
    this.scheduleHour,
    this.scheduleMinute,
    this.scheduleReason,
  });

  bool get granted => action == GuardianAction.grant;
}

@visibleForTesting
GuardianDecision parseGuardianDecision(String response) {
  for (final line in response.trim().split('\n').reversed) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) continue;
    try {
      final json = jsonDecode(trimmed) as Map<String, dynamic>;
      final decision = (json['decision'] as String?)?.toLowerCase();
      if (decision == 'grant') {
        final minutes = AppConfig.sanitizeGrantedMinutes(
          (json['minutes'] as num?)?.toInt() ?? 5,
        );
        return GuardianDecision(
          message: cleanGuardianResponse(response),
          action: GuardianAction.grant,
          minutesGranted: minutes,
        );
      }
      if (decision == 'deny' || decision == 'lock') {
        return GuardianDecision(
          message: cleanGuardianResponse(response),
          action: GuardianAction.deny,
        );
      }
      if (decision == 'minimize') {
        return GuardianDecision(
          message: cleanGuardianResponse(response),
          action: GuardianAction.minimize,
        );
      }
      if (decision == 'close' || decision == 'exit') {
        return GuardianDecision(
          message: cleanGuardianResponse(response),
          action: GuardianAction.close,
        );
      }
      if (decision == 'unlock') {
        return GuardianDecision(
          message: cleanGuardianResponse(response),
          action: GuardianAction.unlock,
        );
      }
    } catch (_) {
      continue;
    }
  }
  return GuardianDecision(message: cleanGuardianResponse(response));
}

@visibleForTesting
String cleanGuardianResponse(String response) {
  final cleaned = response
      .trim()
      .split('\n')
      .where((line) {
        final trimmed = line.trim();
        return !(trimmed.startsWith('{') && trimmed.contains('"decision"'));
      })
      .join('\n')
      .trim();
  return cleaned.isEmpty ? 'no.' : cleaned;
}

class NegotiationEngine {
  GenerativeModel? _geminiModel;
  ChatSession? _geminiChat;
  final List<Map<String, String>> _anthropicMessages = [];
  String? _personalityPrompt;
  String? _systemPrompt;
  String _sessionId = '';

  String get sessionId => _sessionId;

  Future<void> initialize() async {
    _personalityPrompt ??=
        await rootBundle.loadString('assets/prompts/personality.md');

    if (AppConfig.aiProvider == AiProvider.gemini && AppConfig.hasUsableAiKey) {
      _geminiModel = GenerativeModel(
        model: AppConfig.geminiModel,
        apiKey: AppConfig.activeApiKey,
        generationConfig: GenerationConfig(
          temperature: 0.7,
          maxOutputTokens: 500,
        ),
      );
    }
  }

  Future<String> startSession() async {
    await initialize();
    _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    _anthropicMessages.clear();
    _geminiChat = null;

    if (!AppConfig.hasUsableAiKey) {
      return _sessionId;
    }

    final memoryContext = await MemoryService.buildNegotiationContext();
    final now = DateTime.now();
    final currentLocalTime = AppConfig.formatDateTimeWithZone(now);
    final runtimeMode = AppConfig.isLockdownTime(now)
        ? 'real lockdown'
        : 'manual chat opened outside lockdown schedule';

    _systemPrompt = '''
$_personalityPrompt

---

$memoryContext

---

CURRENT LOCAL WALL CLOCK: $currentLocalTime
IMPORTANT: treat the local wall clock above as authoritative. if it says PM, do not call it AM. if it says evening, do not pretend it is morning.
current mode: $runtimeMode
active provider: ${AppConfig.providerLabel}
active model: ${AppConfig.activeModel}
lockdown window: ${AppConfig.formatTime(AppConfig.lockdownHour, AppConfig.lockdownMinute)} - ${AppConfig.formatTime(AppConfig.unlockHour, AppConfig.unlockMinute)}
grants used tonight: ${await MemoryService.getTonightGrantCount()}

${AppConfig.agentAutonomyNote}

Never stop mid-sentence. Keep answers short, but complete the sentence cleanly.
When making a final grant/deny/lock decision, put the JSON decision object on the last line.
''';

    if (AppConfig.aiProvider == AiProvider.gemini && _geminiModel != null) {
      _geminiChat = _geminiModel!.startChat();
      try {
        await _geminiChat!.sendMessage(Content.text(
          'SYSTEM CONTEXT (not from user):\n$_systemPrompt\n\nRespond with your opening line.',
        ));
      } catch (_) {
        _geminiChat = null;
      }
    }

    return _sessionId;
  }

  Future<GuardianDecision> negotiate(String userMessage) async {
    if (kDebugMode && userMessage.trim().toLowerCase() == 'solara') {
      return GuardianDecision(
        message: 'fine. one minute. test it and leave.',
        action: GuardianAction.grant,
        minutesGranted: 1,
      );
    }

    if (_sessionId.isEmpty) {
      await startSession();
    }

    if (!AppConfig.hasUsableAiKey) {
      return GuardianDecision(message: _missingKeyMessage());
    }

    await MemoryService.saveMessage(ConversationMessage(
      role: 'user',
      content: userMessage,
      sessionId: _sessionId,
    ));

    final responseText = await _sendToProvider(userMessage);
    final parsed = parseGuardianDecision(responseText);

    await MemoryService.saveMessage(ConversationMessage(
      role: 'guardian',
      content: parsed.message,
      sessionId: _sessionId,
    ));

    if (parsed.action != GuardianAction.none) {
      final tonightGrantCount = await MemoryService.getTonightGrantCount();
      await MemoryService.saveNegotiation(NegotiationRecord(
        userReason: userMessage,
        granted: parsed.granted,
        minutesGranted: parsed.minutesGranted,
        guardianResponse: parsed.message,
        grantNumber: parsed.granted ? tonightGrantCount + 1 : tonightGrantCount,
      ));
    }

    return parsed;
  }

  Future<String> _sendToProvider(String userMessage) async {
    switch (AppConfig.aiProvider) {
      case AiProvider.gemini:
        if (_geminiChat == null) await startSession();
        if (_geminiChat == null) return 'guardian is offline. try again.';
        final response = await _geminiChat!
            .sendMessage(Content.text(userMessage))
            .timeout(const Duration(seconds: 30));
        return response.text ?? 'no.';
      case AiProvider.anthropic:
        return _sendAnthropic(userMessage);
    }
  }

  Future<String> _sendAnthropic(String userMessage) async {
    _anthropicMessages.add({'role': 'user', 'content': userMessage});

    final response = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'content-type': 'application/json',
        'x-api-key': AppConfig.activeApiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': AppConfig.anthropicModel,
        'max_tokens': 500,
        'temperature': 0.7,
        'system': _systemPrompt,
        'messages': _anthropicMessages,
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Anthropic request failed: ${response.statusCode} ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final content = json['content'] as List<dynamic>? ?? const [];
    final text = content
        .whereType<Map<String, dynamic>>()
        .map((part) => part['text'])
        .whereType<String>()
        .join('\n')
        .trim();

    final reply = text.isEmpty ? 'no.' : text;
    _anthropicMessages.add({'role': 'assistant', 'content': reply});
    return reply;
  }

  String _missingKeyMessage() {
    switch (AppConfig.aiProvider) {
      case AiProvider.gemini:
        if (!AppConfig.useBringYourOwnKey &&
            AppConfig.conciergeGeminiApiKey.isEmpty) {
          return 'no concierge gemini key is configured yet. add one in the app build or switch to byok.';
        }
        return 'set your gemini api key in settings or disable byok.';
      case AiProvider.anthropic:
        return 'set your anthropic api key in settings first.';
    }
  }

  void dispose() {
    _geminiChat = null;
    _anthropicMessages.clear();
  }
}
