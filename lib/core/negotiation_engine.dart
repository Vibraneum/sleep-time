import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'guardian_tools.dart';
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

  // Selective app-unlock payload.
  final String? appIdentifier;
  final String? appLabel;
  final int? appMinutes;

  // Schedule-adjust payload (data only in M1; application + guardrails are M3).
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

/// Build the Anthropic Messages tool-use request body. Extracted so the
/// body-shape (tools, tool_choice, cache_control placement) is unit-testable
/// without the network.
///
/// Caching invariants:
/// - `system` is an ARRAY of blocks; the LAST block carries cache_control.
/// - The LAST tool carries cache_control.
/// - `tool_choice` is held CONSTANT for the whole session (changing it
///   mid-session invalidates the prompt cache), so the builder always emits
///   `{type: 'any'}`.
@visibleForTesting
Map<String, dynamic> buildAnthropicToolRequest({
  required String systemPrompt,
  required List<dynamic> messages,
  int maxTokens = 500,
  double temperature = 0.7,
}) {
  // System as an array of blocks; cache_control on the LAST block.
  final system = <Map<String, dynamic>>[
    {
      'type': 'text',
      'text': systemPrompt,
      'cache_control': {'type': 'ephemeral'},
    },
  ];

  // Deep-copy the tool maps so we can stamp cache_control on the last tool
  // without mutating the shared const definitions.
  final tools = GuardianTools.all
      .map((tool) => jsonDecode(jsonEncode(tool)) as Map<String, dynamic>)
      .toList();
  tools.last['cache_control'] = {'type': 'ephemeral'};

  return {
    'model': AppConfig.anthropicModel,
    'max_tokens': maxTokens,
    'temperature': temperature,
    'system': system,
    'tools': tools,
    'tool_choice': {'type': 'any'},
    'disable_parallel_tool_use': true,
    'messages': messages,
  };
}

/// Build the content list for a new user turn. When a tool_use from the prior
/// assistant turn is pending, a `tool_result` block MUST come FIRST (the API
/// 400s otherwise), followed by the user's text block.
@visibleForTesting
List<Map<String, dynamic>> buildUserTurnContent({
  required String userMessage,
  String? pendingToolUseId,
  String toolResultAck = 'noted.',
}) {
  final content = <Map<String, dynamic>>[];
  if (pendingToolUseId != null) {
    content.add({
      'type': 'tool_result',
      'tool_use_id': pendingToolUseId,
      'content': toolResultAck,
    });
  }
  content.add({'type': 'text', 'text': userMessage});
  return content;
}

class NegotiationEngine {
  GenerativeModel? _geminiModel;
  ChatSession? _geminiChat;

  // Content-block-aware history: each entry is {role, content: [...blocks]}.
  final List<dynamic> _anthropicHistory = [];
  String? _lastToolUseId;

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
    _anthropicHistory.clear();
    _lastToolUseId = null;
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

    final base = '''
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

Never stop mid-sentence. Keep answers short, but complete the sentence cleanly.''';

    _systemPrompt = '$base\n\n${_providerSuffix()}';

    if (AppConfig.aiProvider == AiProvider.gemini && _geminiModel != null) {
      _geminiChat = _geminiModel!.startChat();
      try {
        await _geminiChat!.sendMessage(Content.text(
          'SYSTEM CONTEXT (not from user):\n$_systemPrompt\n\nRespond with your opening line.',
        ));
      } catch (_) {
        _geminiChat = null;
      }
    } else if (AppConfig.aiProvider == AiProvider.anthropic) {
      // Best-effort cache warm-up. Never blocks the session if it fails.
      await _warmAnthropicCache();
    }

    return _sessionId;
  }

  /// Provider-specific system-prompt suffix. Keeps personality.md
  /// provider-neutral: Anthropic gets tool guidance, Gemini gets the legacy
  /// JSON-last-line instruction.
  String _providerSuffix() {
    switch (AppConfig.aiProvider) {
      case AiProvider.anthropic:
        return 'You act ONLY by calling exactly one tool per reply. The user-facing '
            'text goes in that tool\'s `message` field — never write prose outside a '
            'tool call. Use guardian_action with "deny" to keep talking without '
            'ending the negotiation.';
      case AiProvider.gemini:
        return 'When making a final grant/deny/lock decision, put the JSON decision '
            'object on the last line.';
    }
  }

  Future<void> _warmAnthropicCache() async {
    try {
      final body = buildAnthropicToolRequest(
        systemPrompt: _systemPrompt ?? '',
        messages: const [
          {'role': 'user', 'content': 'warmup'},
        ],
        maxTokens: 1,
      );
      await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: _anthropicHeaders(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Cache warm-up is best-effort.
    }
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

    final decision = await _sendToProvider(userMessage);

    await MemoryService.saveMessage(ConversationMessage(
      role: 'guardian',
      content: decision.message,
      sessionId: _sessionId,
    ));

    if (decision.action != GuardianAction.none) {
      final tonightGrantCount = await MemoryService.getTonightGrantCount();
      await MemoryService.saveNegotiation(NegotiationRecord(
        userReason: userMessage,
        granted: decision.granted,
        minutesGranted: decision.minutesGranted,
        guardianResponse: decision.message,
        grantNumber:
            decision.granted ? tonightGrantCount + 1 : tonightGrantCount,
      ));
    }

    return decision;
  }

  Future<GuardianDecision> _sendToProvider(String userMessage) async {
    switch (AppConfig.aiProvider) {
      case AiProvider.gemini:
        if (_geminiChat == null) await startSession();
        if (_geminiChat == null) {
          return GuardianDecision(
            message: 'guardian is offline. try again.',
            action: GuardianAction.deny,
          );
        }
        try {
          final response = await _geminiChat!
              .sendMessage(Content.text(userMessage))
              .timeout(const Duration(seconds: 30));
          return geminiDecisionFromText(response.text ?? 'no.');
        } catch (_) {
          return GuardianDecision(
            message: 'something broke. try again.',
            action: GuardianAction.deny,
          );
        }
      case AiProvider.anthropic:
        return _sendAnthropicToolUse(userMessage);
    }
  }

  Map<String, String> _anthropicHeaders() => {
        'content-type': 'application/json',
        'x-api-key': AppConfig.activeApiKey,
        'anthropic-version': '2023-06-01',
      };

  Future<GuardianDecision> _sendAnthropicToolUse(String userMessage) async {
    // History-shape invariant: if a tool_use is pending from the previous
    // assistant turn, the tool_result block comes FIRST in this user turn.
    _anthropicHistory.add({
      'role': 'user',
      'content': buildUserTurnContent(
        userMessage: userMessage,
        pendingToolUseId: _lastToolUseId,
      ),
    });
    _lastToolUseId = null;

    final body = buildAnthropicToolRequest(
      systemPrompt: _systemPrompt ?? '',
      messages: _anthropicHistory,
    );

    http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: _anthropicHeaders(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      return GuardianDecision(
        message: 'something broke. try again.',
        action: GuardianAction.deny,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return GuardianDecision(
        message: 'guardian is offline. try again.',
        action: GuardianAction.deny,
      );
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return GuardianDecision(
        message: 'something broke. try again.',
        action: GuardianAction.deny,
      );
    }

    final content = json['content'] as List<dynamic>? ?? const [];

    // Find the single tool_use block.
    Map<String, dynamic>? toolUse;
    for (final block in content) {
      if (block is Map<String, dynamic> && block['type'] == 'tool_use') {
        toolUse = block;
        break;
      }
    }

    if (toolUse == null) {
      // No tool_use found — never reach the text parser on the Anthropic path.
      return GuardianDecision(
        message: 'no.',
        action: GuardianAction.deny,
      );
    }

    // Append the assistant content (incl. the tool_use block) to history and
    // track the tool_use_id for the next turn's tool_result.
    _anthropicHistory.add({'role': 'assistant', 'content': content});
    _lastToolUseId = toolUse['id'] as String?;

    final toolName = toolUse['name'] as String? ?? '';
    final input = (toolUse['input'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    return guardianDecisionFromToolUse(toolName, input);
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
    _anthropicHistory.clear();
    _lastToolUseId = null;
  }
}
