import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;

import 'anthropic_retry.dart';
import 'anthropic_stream.dart';
import 'config.dart';
import 'guardian_tools.dart';
import 'memory_service.dart';
import 'schedule.dart';
import 'schedule_guardrails.dart';
import 'schedule_store.dart';

enum GuardianAction {
  none,
  grant,
  deny,
  minimize,
  close,
  unlock,
  unlockApp,
  adjustSchedule,
  controlApp,
  saveMemory,
}

/// Synthetic triggers for an AI-initiated (proactive) turn. The guardian gets a
/// "brain of its own": instead of only replying to the user it can open the
/// conversation, ping after silence, warn before a grant expires, and nudge at
/// wind-down. Each maps to a system-authored user turn pushed through the SAME
/// Anthropic tool loop so the reply is real model output, not a hardcoded line.
enum ProactiveTrigger { open, silence, grantExpiring, windDown }

class GuardianDecision {
  final String message;
  final GuardianAction action;
  final int minutesGranted;

  // Selective app-unlock payload.
  final String? appIdentifier;
  final String? appLabel;
  final int? appMinutes;

  // App-control payload (block + minimize distractions, never kill). Carried by
  // the control_app tool so the guardian can proactively quiet a distraction.
  final String? controlAppIdentifier;
  final String? controlAppAction; // 'minimize' | 'allow'

  // save_memory payload — a durable fact the guardian chose to remember.
  final String? memoryType;
  final String? memoryText;

  // Schedule-adjust payload. Application + guardrails landed in M3.
  final String? scheduleField;
  final int? scheduleHour;
  final int? scheduleMinute;
  final String? scheduleReason;
  final ScheduleScope? scheduleScope;

  /// Set in M3 after the engine runs the proposal through the guardrails and
  /// ScheduleStore. A short, truthful outcome (e.g. "Bedtime moved to 11:45
  /// tonight") the UI can render as a chip. Null when no schedule change ran.
  final String? scheduleOutcomeNote;

  /// True when this decision is a degraded result because the guardian could
  /// not reach its brain (rate-limit / overloaded / server / network, AFTER
  /// retries were exhausted). The UI styles these amber with a retry
  /// affordance — "guardian unreachable, try again / use the safe word" — and
  /// must NOT treat the (deny) action as a real, cruel-sounding refusal.
  final bool offline;

  /// True when this decision is a degraded result because the API key is
  /// missing or rejected (401/403). The UI routes these to the settings /
  /// missing-key path rather than showing a generic deny.
  final bool authFailure;

  GuardianDecision({
    required this.message,
    this.action = GuardianAction.none,
    this.minutesGranted = 0,
    this.appIdentifier,
    this.appLabel,
    this.appMinutes,
    this.controlAppIdentifier,
    this.controlAppAction,
    this.memoryType,
    this.memoryText,
    this.scheduleField,
    this.scheduleHour,
    this.scheduleMinute,
    this.scheduleReason,
    this.scheduleScope,
    this.scheduleOutcomeNote,
    this.offline = false,
    this.authFailure = false,
  });

  /// Copy helper used by the engine to stamp the post-guardrail outcome note
  /// onto a decision produced by [guardianDecisionFromToolUse].
  GuardianDecision withScheduleOutcome(String note) => GuardianDecision(
        message: message,
        action: action,
        minutesGranted: minutesGranted,
        appIdentifier: appIdentifier,
        appLabel: appLabel,
        appMinutes: appMinutes,
        controlAppIdentifier: controlAppIdentifier,
        controlAppAction: controlAppAction,
        memoryType: memoryType,
        memoryText: memoryText,
        scheduleField: scheduleField,
        scheduleHour: scheduleHour,
        scheduleMinute: scheduleMinute,
        scheduleReason: scheduleReason,
        scheduleScope: scheduleScope,
        scheduleOutcomeNote: note,
        offline: offline,
        authFailure: authFailure,
      );

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
  // System as an array of blocks; cache_control on the LAST block. The 1h TTL
  // (GA) keeps the system+tools prefix cached across a whole bedtime session —
  // negotiation can span hours with long idle gaps, so 5m would expire between
  // turns and re-pay the write each time.
  final system = <Map<String, dynamic>>[
    {
      'type': 'text',
      'text': systemPrompt,
      'cache_control': {'type': 'ephemeral', 'ttl': '1h'},
    },
  ];

  // Deep-copy the tool maps so we can stamp cache_control on the last tool
  // without mutating the shared const definitions. Same 1h TTL as the system
  // block so tools + system cache together for the session.
  final tools = GuardianTools.all
      .map((tool) => jsonDecode(jsonEncode(tool)) as Map<String, dynamic>)
      .toList();
  tools.last['cache_control'] = {'type': 'ephemeral', 'ttl': '1h'};

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

  // The tool_result string to send back on the NEXT user turn for the pending
  // tool_use. Most tools get the generic ack; adjust_schedule overrides this
  // with the truthful guardrail outcome (see one-turn-lag note below).
  String _pendingToolResultAck = 'noted.';

  /// Whether the device is currently inside lockdown (locked/granted). The UI
  /// updates this from the live LockdownState; the guardrails use it to forbid
  /// the AI from moving tonight's lockdown once we are already locked. We keep
  /// it as a settable field (rather than always recomputing from AppConfig) so
  /// a mid-grant state — where the clock says "unlocked" but the user is in an
  /// active grant inside the lockdown window — still counts as active.
  bool lockdownActive = false;

  String? _personalityPrompt;
  String? _systemPrompt;
  String _sessionId = '';

  /// Wall-clock time of the most recent USER message in this session. Used by
  /// the LockdownScreen silence heartbeat to decide whether to ping. Null until
  /// the user has said something (proactive turns do not count).
  DateTime? _lastUserMessageAt;

  /// Last time a proactive (AI-initiated) turn fired. Throttles the silence
  /// ping so the guardian never spams.
  DateTime? _lastProactiveAt;

  /// When the current lock-night session started — used for the live "time
  /// since start" memory delta.
  DateTime? _sessionStartedAt;

  String get sessionId => _sessionId;

  DateTime? get lastUserMessageAt => _lastUserMessageAt;
  DateTime? get lastProactiveAt => _lastProactiveAt;

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

  /// Start (or RESUME) the lock-night session. Idempotent within a lock-night:
  /// once a session exists we keep it so `_anthropicHistory` survives the
  /// LockdownScreen lifecycle (grant -> relock spawns a fresh LockdownScreen,
  /// but the engine is owned above it and persists). Pass [force]=true on the
  /// nightly reset to deliberately start a brand-new session.
  Future<String> startSession({bool force = false}) async {
    await initialize();

    // Resume an existing session rather than wiping history. This is what makes
    // the chat "unlimited + continuous": re-opening the chat after a grant does
    // NOT re-greet from scratch or forget what was already said.
    if (!force && _sessionId.isNotEmpty) {
      return _sessionId;
    }

    _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    _sessionStartedAt = DateTime.now();
    _anthropicHistory.clear();
    _lastToolUseId = null;
    _geminiChat = null;

    if (!AppConfig.hasUsableAiKey) {
      return _sessionId;
    }

    final memoryContext = await MemoryService.buildNegotiationContext();
    final now = DateTime.now();
    final currentLocalTime = AppConfig.formatDateTimeWithZone(now);
    final onSchedule = AppConfig.isLockdownTime(now);
    // Authoritative framing: this chat is ONLY reachable while the screen is
    // locked or in a grant, so if the guardian is talking to the user at all,
    // the user is locked out RIGHT NOW — possibly via a manual "sleep now" the
    // user triggered themselves, which is independent of the bedtime schedule
    // and the wall clock. This holds even when `lockdownActive` hasn't been set
    // yet and even when the clock falls outside the scheduled window.
    final runtimeMode = StringBuffer()
      ..writeln(
          'YOU ARE CURRENTLY HOLDING THE USER LOCKED OUT. This conversation is '
          'only reachable while the screen is locked or in a grant — so if you '
          'are reading this, the user is locked out RIGHT NOW.')
      ..writeln(
          'The lock may be a scheduled bedtime lockdown OR a manual "sleep now" '
          'the user triggered themselves; a manual lock is independent of the '
          'bedtime schedule and the wall clock, so it can be active at any hour.')
      ..writeln(
          'NEVER tell the user "there\'s no lock", "nothing to turn off", or '
          '"i\'m off duty" while in this chat — you ARE actively enforcing a '
          'lock.')
      ..writeln(
          'You always have the power to release them: guardian_action grant '
          '(frees the machine for N minutes), unlock_app (frees one app), or '
          'end_session (lifts the lock for the night). Whether you release is '
          'your judgment.')
      ..write(onSchedule
          ? 'Schedule context: the current time is inside the scheduled bedtime '
              'lockdown window.'
          : 'Schedule context: the current time is OUTSIDE the scheduled bedtime '
              'window, so this is almost certainly a manual "sleep now" lock.');
    if (lockdownActive) {
      runtimeMode.write(
          ' (Confirmed: the lockdown screen reports the lock is active.)');
    }

    final base = '''
$_personalityPrompt

---

$memoryContext

---

CURRENT LOCAL WALL CLOCK: $currentLocalTime
IMPORTANT: treat the local wall clock above as authoritative. if it says PM, do not call it AM. if it says evening, do not pretend it is morning.
current mode:
$runtimeMode
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
            'object on the LAST line ONLY, e.g. {"decision":"deny"}. NEVER write '
            'the decision word, an action label, or words like "deny request" / '
            '"Decision: grant" / "Action: lock" anywhere else in your reply. Your '
            'visible text is ONLY your in-character message — the decision lives '
            'solely in that final JSON line.';
    }
  }

  Future<void> _warmAnthropicCache() async {
    try {
      final body = buildAnthropicToolRequest(
        systemPrompt: _systemPrompt ?? '',
        messages: const [
          {'role': 'user', 'content': 'warmup'},
        ],
        // max_tokens MUST be >=1 here: the API rejects max_tokens:0 together
        // with tool_choice:{type:'any'} (400), and this request always carries
        // tool_choice:any. 1 token of prefill is enough to write the cache.
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

  /// [onDelta], when provided, routes the Anthropic branch through real-time
  /// streaming: it is called with the current (growing) guardian `message`
  /// snapshot as the tool-input JSON arrives token-by-token. Gemini and the
  /// no-key / debug paths ignore it (non-streaming) — they simply never call
  /// it, so the UI shows a thinking indicator then the final bubble.
  Future<GuardianDecision> negotiate(
    String userMessage, {
    void Function(String partialMessage)? onDelta,
  }) async {
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

    _lastUserMessageAt = DateTime.now();

    if (!AppConfig.hasUsableAiKey) {
      return GuardianDecision(message: _missingKeyMessage());
    }

    await MemoryService.saveMessage(ConversationMessage(
      role: 'user',
      content: userMessage,
      sessionId: _sessionId,
    ));

    final decision = await _sendToProvider(userMessage, onDelta: onDelta);

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

  /// Synthetic-user prompts for each proactive trigger. These are authored as a
  /// SYSTEM-tagged user turn so the model knows the user did NOT actually type
  /// them (per personality.md's proactive section) and replies in character.
  static String _proactivePrompt(ProactiveTrigger trigger) {
    switch (trigger) {
      case ProactiveTrigger.open:
        return '[SYSTEM: the lockdown just opened and the user opened the chat. '
            'send your opening line. be proactive and in character. do not wait '
            'for them to speak first.]';
      case ProactiveTrigger.silence:
        return '[SYSTEM: the user has gone silent for a few minutes mid-chat. '
            'nudge them once, in character — short. do not repeat yourself.]';
      case ProactiveTrigger.grantExpiring:
        return '[SYSTEM: the current grant expires in about 2 minutes and the '
            'screen will re-lock. warn them once, in character — short.]';
      case ProactiveTrigger.windDown:
        return '[SYSTEM: it is wind-down time — lockdown starts soon. nudge the '
            'user to start wrapping up, in character — short.]';
    }
  }

  /// AI-initiated ("brain of its own") turn. Pushes a synthetic, SYSTEM-tagged
  /// user turn through the SAME Anthropic tool loop so the guardian's opening
  /// line / silence ping / grant-expiry warning / wind-down nudge is REAL model
  /// output rendered as a guardian bubble — not a hardcoded string. Falls back
  /// to a safe canned line only when offline / no key. Throttled by the caller.
  Future<GuardianDecision> negotiateProactive(
    ProactiveTrigger trigger, {
    void Function(String partialMessage)? onDelta,
  }) async {
    if (_sessionId.isEmpty) {
      await startSession();
    }
    _lastProactiveAt = DateTime.now();

    if (!AppConfig.hasUsableAiKey) {
      return GuardianDecision(message: _proactiveFallback(trigger));
    }

    // Gemini fallback path has no tool loop; use a canned in-character line so
    // we never block. The headline proactive experience is the Anthropic path.
    if (AppConfig.aiProvider != AiProvider.anthropic) {
      return GuardianDecision(message: _proactiveFallback(trigger));
    }

    final decision = onDelta != null
        ? await _sendAnthropicToolUseStreaming(
            _proactivePrompt(trigger),
            onDelta: onDelta,
          )
        : await _sendAnthropicToolUse(_proactivePrompt(trigger));

    await MemoryService.saveMessage(ConversationMessage(
      role: 'guardian',
      content: decision.message,
      sessionId: _sessionId,
    ));
    return decision;
  }

  String _proactiveFallback(ProactiveTrigger trigger) {
    switch (trigger) {
      case ProactiveTrigger.open:
        if (lockdownActive) {
          return "it's past your bedtime. what's so important it can't wait?";
        }
        return "i'm here. what do you need?";
      case ProactiveTrigger.silence:
        return 'still there? sleep is waiting.';
      case ProactiveTrigger.grantExpiring:
        return 'two minutes left. wrap it up.';
      case ProactiveTrigger.windDown:
        return 'start wrapping up. lockdown is close.';
    }
  }

  /// Reset the session for a brand-new lock-night (clears history + last-message
  /// tracking). The caller (host) invokes this on the nightly reset so a fresh
  /// night doesn't carry the previous night's conversation.
  Future<void> resetSession() async {
    _lastUserMessageAt = null;
    _lastProactiveAt = null;
    await startSession(force: true);
  }

  Future<GuardianDecision> _sendToProvider(
    String userMessage, {
    void Function(String partialMessage)? onDelta,
  }) async {
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
        return onDelta != null
            ? _sendAnthropicToolUseStreaming(userMessage, onDelta: onDelta)
            : _sendAnthropicToolUse(userMessage);
    }
  }

  Map<String, String> _anthropicHeaders() => {
        'content-type': 'application/json',
        'x-api-key': AppConfig.activeApiKey,
        'anthropic-version': '2023-06-01',
      };

  /// Degraded result when the guardian cannot reach its brain after retries
  /// (rate-limit / overloaded / server / network). NOT a real refusal — flagged
  /// `offline` so the UI shows an amber, retryable "unreachable" state. Rendered
  /// as a deny so the chat stays live (the user can retry or use the safe word).
  static GuardianDecision _offlineResult() => GuardianDecision(
        message:
            "can't reach the guardian right now. try again in a moment — or use your safe word.",
        action: GuardianAction.deny,
        offline: true,
      );

  /// Degraded result when the API key is missing or rejected (401/403). Routes
  /// the user to the settings / missing-key path rather than a generic deny.
  GuardianDecision _authFailureResult() => GuardianDecision(
        message: _missingKeyMessage(),
        action: GuardianAction.deny,
        authFailure: true,
      );

  /// Single-shot POST with classification metadata. Returns the response (when
  /// the request completed) plus the thrown error (when it did not) so the
  /// retry loop can classify without re-catching. Never throws.
  Future<({http.Response? response, Object? error})> _postAnthropicOnce(
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: _anthropicHeaders(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      return (response: response, error: null);
    } catch (e) {
      return (response: null, error: e);
    }
  }

  /// Non-streaming POST WITH retry: exponential backoff + jitter on 429/500/529
  /// and transport failures (max 3 retries), honoring a 429 `Retry-After`.
  /// Returns the successful [http.Response], or null when the outcome was a
  /// non-retryable error or retries were exhausted — with [outClass] carrying
  /// the final classification so the caller can route auth vs offline.
  Future<http.Response?> _postAnthropicWithRetry(
    Map<String, dynamic> body, {
    required void Function(AnthropicErrorClass cls) onClass,
    BackoffConfig config = const BackoffConfig(),
  }) async {
    AnthropicErrorClass cls = AnthropicErrorClass.retryable;
    for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
      final result = await _postAnthropicOnce(body);
      final response = result.response;
      final status = response?.statusCode;
      cls = classifyAnthropic(status, result.error);

      if (cls == AnthropicErrorClass.ok) {
        onClass(cls);
        return response;
      }
      // Non-retryable (auth / client error): surface immediately.
      if (cls != AnthropicErrorClass.retryable) {
        onClass(cls);
        return null;
      }
      // Retryable. If this was the last allowed attempt, give up.
      if (attempt == config.maxRetries) break;
      final retryAfter =
          status == 429 ? parseRetryAfter(response?.headers) : null;
      await Future<void>.delayed(
        backoffDelay(attempt, retryAfter: retryAfter, config: config),
      );
    }
    onClass(cls);
    return null;
  }

  /// Build the next Anthropic user turn LOCALLY (without mutating
  /// _anthropicHistory). History-shape invariant: if a tool_use is pending from
  /// the previous assistant turn, the tool_result block comes FIRST in this
  /// user turn. Injects a small LIVE memory delta per turn (grant count,
  /// denials tonight, time since session start) rather than re-baking the
  /// cached system prompt — the cached system prompt stays byte-stable so the
  /// prompt cache keeps hitting, while the model still sees fresh state.
  Future<Map<String, dynamic>> _buildNextUserTurn(String userMessage) async {
    final memoryDelta = await _buildMemoryDelta();
    final turnText =
        memoryDelta.isEmpty ? userMessage : '$memoryDelta\n\n$userMessage';
    return <String, dynamic>{
      'role': 'user',
      'content': buildUserTurnContent(
        userMessage: turnText,
        pendingToolUseId: _lastToolUseId,
        toolResultAck: _pendingToolResultAck,
      ),
    };
  }

  /// Commit a successful turn to history and map it to a final decision. Shared
  /// by the streaming and non-streaming paths so the tool_result-FIRST ordering
  /// and tool_use_id tracking stay byte-identical between them. [content] is the
  /// assistant content block list to persist; [toolName]/[toolInput]/[toolId]
  /// are the parsed tool_use fields.
  ///
  /// Do NOT mutate _anthropicHistory / _lastToolUseId / _pendingToolResultAck
  /// until the request has succeeded and parsed — otherwise a timeout / non-2xx
  /// / bad-JSON leaves the local session out of sync with the provider.
  Future<GuardianDecision> _commitAnthropicTurn({
    required Map<String, dynamic> nextUserTurn,
    required List<dynamic> content,
    required String toolName,
    required Map<String, dynamic> toolInput,
    required String? toolId,
  }) async {
    // Success: NOW commit the user turn + assistant content (incl. the tool_use
    // block) to history and track the tool_use_id for the next turn's
    // tool_result. _pendingToolResultAck resets to the generic ack here; only
    // adjust_schedule re-sets it below.
    _anthropicHistory.add(nextUserTurn);
    _anthropicHistory.add({'role': 'assistant', 'content': content});
    _lastToolUseId = toolId;
    _pendingToolResultAck = 'noted.';

    final decision = guardianDecisionFromToolUse(toolName, toolInput);

    if (decision.action == GuardianAction.adjustSchedule) {
      return _applyScheduleAdjustment(decision);
    }
    if (decision.action == GuardianAction.saveMemory) {
      await _persistGuardianMemory(decision);
      // save_memory is a side effect, not a UI action — present it like a deny
      // (keep-talking) so the chat stays live and the guardian's message shows.
      return GuardianDecision(
        message: decision.message,
        action: GuardianAction.deny,
      );
    }
    return decision;
  }

  Future<GuardianDecision> _sendAnthropicToolUse(String userMessage) async {
    // Defend the auth path even before the request: a blank key is an auth
    // failure, not an offline state — route it to settings.
    if (!AppConfig.hasUsableAiKey) {
      return _authFailureResult();
    }

    final nextUserTurn = await _buildNextUserTurn(userMessage);

    final body = buildAnthropicToolRequest(
      systemPrompt: _systemPrompt ?? '',
      messages: [..._anthropicHistory, nextUserTurn],
    );

    AnthropicErrorClass cls = AnthropicErrorClass.ok;
    final response = await _postAnthropicWithRetry(
      body,
      onClass: (c) => cls = c,
    );

    if (response == null) {
      // No usable response. Route by classification: auth -> settings path;
      // everything else (retryable exhausted / client error) -> offline-style.
      return cls == AnthropicErrorClass.auth
          ? _authFailureResult()
          : _offlineResult();
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      // 2xx but undecodable body — treat as a transient offline blip.
      return _offlineResult();
    }

    final content = json['content'] as List<dynamic>? ?? const [];
    final stopReason = json['stop_reason'] as String?;

    return _mapAnthropicContent(
      nextUserTurn: nextUserTurn,
      content: content,
      stopReason: stopReason,
    );
  }

  /// Map a parsed Anthropic response (content blocks + stop_reason) to a final
  /// decision and commit the turn. Shared by the non-streaming path and the
  /// streaming reconstruction so stop_reason handling is identical.
  ///
  /// stop_reason handling (tool_choice:any normally yields `tool_use`):
  ///   - `refusal` -> an in-character safe deny; do not parse a tool block that
  ///     isn't there.
  ///   - `max_tokens` -> use a complete tool_use block if one was produced,
  ///     otherwise a safe deny (our messages are short, so this is rare).
  Future<GuardianDecision> _mapAnthropicContent({
    required Map<String, dynamic> nextUserTurn,
    required List<dynamic> content,
    required String? stopReason,
  }) {
    if (stopReason == 'refusal') {
      // The model declined to emit a tool call. Stay in character; do NOT try
      // to parse a tool block that isn't there.
      return Future.value(GuardianDecision(
        message: 'not happening. go to sleep.',
        action: GuardianAction.deny,
      ));
    }

    // Find the single tool_use block.
    Map<String, dynamic>? toolUse;
    for (final block in content) {
      if (block is Map<String, dynamic> && block['type'] == 'tool_use') {
        toolUse = block;
        break;
      }
    }

    if (toolUse == null) {
      // No tool_use found (incl. max_tokens with no complete block) — never
      // reach the text parser on the Anthropic path; safe deny.
      return Future.value(GuardianDecision(
        message: 'no.',
        action: GuardianAction.deny,
      ));
    }

    final toolName = toolUse['name'] as String? ?? '';
    final input = (toolUse['input'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    return _commitAnthropicTurn(
      nextUserTurn: nextUserTurn,
      content: content,
      toolName: toolName,
      toolInput: input,
      toolId: toolUse['id'] as String?,
    );
  }

  /// Real-time STREAMING variant of [_sendAnthropicToolUse]. Builds the SAME
  /// request body (prompt-caching breakpoints, tool_choice:any,
  /// disable_parallel_tool_use, tool_result-first history) plus
  /// `'stream': true`, reads the SSE event stream, and surfaces the guardian's
  /// `message` field live via [onDelta] as the tool-input JSON arrives.
  ///
  /// Robust fallback: ANY stream error (network, non-2xx, malformed SSE, no
  /// tool_use, undecodable final JSON) falls back to the non-streaming
  /// [_sendAnthropicToolUse] path so the chat never hard-breaks. History is
  /// only committed once on success — the fallback path builds its own turn, so
  /// the tool_result-first ordering is never doubled.
  Future<GuardianDecision> _sendAnthropicToolUseStreaming(
    String userMessage, {
    required void Function(String partialMessage) onDelta,
  }) async {
    // Blank key is auth, not offline — route to settings before any network.
    if (!AppConfig.hasUsableAiKey) {
      return _authFailureResult();
    }

    final nextUserTurn = await _buildNextUserTurn(userMessage);

    final body = buildAnthropicToolRequest(
      systemPrompt: _systemPrompt ?? '',
      messages: [..._anthropicHistory, nextUserTurn],
    )..['stream'] = true;

    // CONNECT-phase retry only: we retry establishing the stream (before any
    // SSE byte is consumed) on 429/500/529 + transport failures. Once deltas
    // start flowing we do NOT silently re-stream — a mid-stream drop falls
    // through to the non-streaming fallback, which builds its own fresh turn
    // (so the tool_result-first ordering is never doubled / double-committed).
    final client = http.Client();
    try {
      const config = BackoffConfig();
      http.StreamedResponse? streamed;
      AnthropicErrorClass connectClass = AnthropicErrorClass.retryable;

      for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
        http.StreamedResponse? attemptResp;
        Object? attemptErr;
        try {
          final request = http.Request(
            'POST',
            Uri.parse('https://api.anthropic.com/v1/messages'),
          )
            ..headers.addAll(_anthropicHeaders())
            ..body = jsonEncode(body);
          attemptResp =
              await client.send(request).timeout(const Duration(seconds: 30));
        } catch (e) {
          attemptErr = e;
        }

        final status = attemptResp?.statusCode;
        connectClass = classifyAnthropic(status, attemptErr);

        if (connectClass == AnthropicErrorClass.ok) {
          streamed = attemptResp;
          break;
        }
        // Non-2xx response we won't keep: drain so the socket can close.
        if (attemptResp != null) {
          await attemptResp.stream.drain<void>().catchError((_) {});
        }
        // Auth / client error: don't retry. Auth routes to settings; a client
        // error falls back to the non-streaming path which surfaces the same.
        if (connectClass == AnthropicErrorClass.auth) {
          return _authFailureResult();
        }
        if (connectClass != AnthropicErrorClass.retryable) {
          return _sendAnthropicToolUse(userMessage);
        }
        if (attempt == config.maxRetries) break;
        final retryAfter =
            status == 429 ? parseRetryAfter(attemptResp?.headers) : null;
        await Future<void>.delayed(
          backoffDelay(attempt, retryAfter: retryAfter, config: config),
        );
      }

      if (streamed == null) {
        // Connect retries exhausted on a retryable class. Don't double-commit
        // by re-streaming; fall through to the non-streaming path (which also
        // retries and will surface the offline result if still unreachable).
        return _sendAnthropicToolUse(userMessage);
      }

      final parser = SseParser();
      final acc = AnthropicStreamAccumulator(
        extractMessage: extractPartialJsonStringField,
      );

      void process(SseEvent event) {
        Map<String, dynamic> data;
        try {
          final decoded = jsonDecode(event.data);
          if (decoded is! Map) return;
          data = decoded.cast<String, dynamic>();
        } catch (_) {
          return; // tolerate a malformed single event
        }
        final snapshot = acc.handleEvent(event.type, data);
        if (snapshot != null) onDelta(snapshot);
      }

      await for (final chunk
          in streamed.stream.transform(utf8.decoder).timeout(
                const Duration(seconds: 30),
              )) {
        for (final event in parser.add(chunk)) {
          process(event);
        }
      }
      final tail = parser.flush();
      if (tail != null) process(tail);

      // stop_reason captured from message_delta. A refusal means there is no
      // tool block to parse — return an in-character safe deny rather than
      // falling through to the non-streaming retry (which would just re-refuse).
      if (acc.stopReason == 'refusal') {
        return GuardianDecision(
          message: 'not happening. go to sleep.',
          action: GuardianAction.deny,
        );
      }

      // Assemble the final tool-input JSON and map it. If anything is missing
      // (no tool block, undecodable JSON — incl. a max_tokens cutoff that left
      // the tool input incomplete), fall back to non-streaming.
      final toolName = acc.toolName;
      final toolInputJson = acc.toolInputJson;
      if (toolName == null || toolInputJson.trim().isEmpty) {
        return _sendAnthropicToolUse(userMessage);
      }
      final Map<String, dynamic> input = acc.decodeToolInput();
      if (input.isEmpty) {
        return _sendAnthropicToolUse(userMessage);
      }

      // Reconstruct the assistant content block to persist EXACTLY as the
      // non-streaming path would have received it.
      final toolUseBlock = <String, dynamic>{
        'type': 'tool_use',
        'id': acc.toolUseId,
        'name': toolName,
        'input': input,
      };

      return _commitAnthropicTurn(
        nextUserTurn: nextUserTurn,
        content: [toolUseBlock],
        toolName: toolName,
        toolInput: input,
        toolId: acc.toolUseId,
      );
    } catch (_) {
      // Network drop / timeout / unexpected error mid-stream: fall back to the
      // non-streaming path (which builds its own fresh turn). Never hard-break.
      return _sendAnthropicToolUse(userMessage);
    } finally {
      client.close();
    }
  }

  /// Persist a guardian-authored memory. Best-effort; failures are swallowed to
  /// match the rest of the persistence layer.
  Future<void> _persistGuardianMemory(GuardianDecision decision) async {
    final text = decision.memoryText;
    if (text == null || text.trim().isEmpty) return;
    final type = MemoryType.values.firstWhere(
      (t) => t.name == decision.memoryType,
      orElse: () => MemoryType.preference,
    );
    await MemoryService.saveMemory(MemoryItem(type: type, text: text));
  }

  /// Run an `adjust_schedule` proposal through the guardrails, apply it (or
  /// not) via [ScheduleStore], and stage a truthful tool_result for the NEXT
  /// user turn.
  ///
  /// ONE-TURN-LAG NOTE: the guardian's own `message` was already produced in
  /// the SAME turn it called the tool, so it is shown to the user immediately
  /// and may not match what the guardrails actually did. The truthful
  /// correction (`_pendingToolResultAck`) only reaches the model on the user's
  /// NEXT turn, as the tool_result block. So if the model promised "moved to
  /// 1 AM" but the guardrails clamped to 12:30, the user sees the optimistic
  /// line now, and the model can self-correct on its next reply. The
  /// `scheduleOutcomeNote` carried on the returned decision lets the UI show
  /// the real outcome immediately as a chip.
  Future<GuardianDecision> _applyScheduleAdjustment(
    GuardianDecision decision,
  ) async {
    final field = decision.scheduleField;
    final hour = decision.scheduleHour;
    final minute = decision.scheduleMinute;
    final scope = decision.scheduleScope ?? ScheduleScope.tonight;

    if (field == null || hour == null || minute == null) {
      _pendingToolResultAck = 'schedule change REJECTED (incomplete request)';
      return decision.withScheduleOutcome('Schedule change ignored.');
    }

    final store = ScheduleStore.instance;
    final budgetRaw = await MemoryService.getTonightAiScheduleBudget();
    final budget = NightlyAiBudget(
      editsUsed: budgetRaw.editsUsed,
      cumulativeLockdownDelayMin: budgetRaw.lockdownDelayMin,
      cumulativeWakeUpDriftMin: budgetRaw.wakeUpDriftMin,
      cumulativeWindDownDriftMin: budgetRaw.windDownDriftMin,
    );

    final result = ScheduleGuardrails.evaluate(
      baseline: store.baseline,
      current: store.current,
      field: field,
      hour: hour,
      minute: minute,
      scope: scope,
      budget: budget,
      lockdownActive: lockdownActive,
    );

    // The guardrails already rejected the proposal outright — nothing to apply.
    if (result.outcome == GuardrailOutcome.rejected) {
      _pendingToolResultAck =
          'schedule change $field REJECTED (${result.humanReason})';
      return decision.withScheduleOutcome(
        'Change blocked: ${result.humanReason}',
      );
    }

    // Guardrails granted or clamped: try to persist via the store. The store
    // runs its OWN validation (wrap-aware ordering + ranges) and can still
    // reject — e.g. a guardrail-approved candidate that doesn't survive
    // validate(). We MUST honor the store's verdict rather than assume success:
    // only emit GRANTED/CLAMPED when the store actually applied the change, and
    // reflect the REAL persisted schedule (store.current) in the note.
    final storeResult = store.apply(
      result.applied,
      source: scope == ScheduleScope.permanent
          ? ScheduleSource.aiPermanent
          : ScheduleSource.aiTonight,
      reason: decision.scheduleReason,
    );

    if (!storeResult.granted) {
      final why = storeResult.reasons.isNotEmpty
          ? storeResult.reasons.join('; ')
          : 'schedule rejected';
      _pendingToolResultAck = 'schedule change $field REJECTED ($why)';
      return decision.withScheduleOutcome('Change blocked: $why');
    }

    // Reflect the actually-persisted schedule, not the proposal.
    final persistedField = _timeForField(storeResult.applied, field);
    final hhmm =
        '${persistedField.hour.toString().padLeft(2, '0')}:${persistedField.minute.toString().padLeft(2, '0')}';

    switch (result.outcome) {
      case GuardrailOutcome.granted:
        _pendingToolResultAck = 'schedule change $field -> $hhmm: GRANTED';
        return decision.withScheduleOutcome(
          scope == ScheduleScope.permanent
              ? '$field moved to $hhmm permanently'
              : '$field moved to $hhmm tonight · back to baseline tomorrow',
        );
      case GuardrailOutcome.clamped:
        _pendingToolResultAck =
            'schedule change $field CLAMPED to $hhmm (${result.humanReason})';
        return decision.withScheduleOutcome(
          scope == ScheduleScope.permanent
              ? '$field set to $hhmm (${result.humanReason})'
              : '$field set to $hhmm tonight (${result.humanReason})',
        );
      case GuardrailOutcome.rejected:
        // Unreachable — handled above — but keep the switch exhaustive.
        _pendingToolResultAck =
            'schedule change $field REJECTED (${result.humanReason})';
        return decision.withScheduleOutcome(
          'Change blocked: ${result.humanReason}',
        );
    }
  }

  ScheduleTime _timeForField(SleepSchedule s, String field) {
    switch (field) {
      case 'wakeUp':
        return s.wakeUp;
      case 'windDown':
        return s.windDown;
      case 'lockdown':
        return s.lockdown;
      case 'unlock':
        return s.unlock;
      default:
        return s.lockdown;
    }
  }

  /// A short live state delta injected into each Anthropic user turn. Kept tiny
  /// and prefixed so the model treats it as backend state, not user speech.
  Future<String> _buildMemoryDelta() async {
    try {
      final grants = await MemoryService.getTonightGrantCount();
      final negotiations = await MemoryService.getRecentNegotiations(days: 1);
      final deniedTonight =
          negotiations.where((n) => !n.granted).length;
      final since = _sessionStartedAt == null
          ? 0
          : DateTime.now().difference(_sessionStartedAt!).inMinutes;
      return '[MEMORY UPDATE: grants tonight=$grants, denials tonight='
          '$deniedTonight, minutes since session start=$since]';
    } catch (_) {
      return '';
    }
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
