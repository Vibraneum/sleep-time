import 'dart:async';

import 'package:flutter/material.dart';
import '../core/config.dart';
import '../core/negotiation_engine.dart';

class NegotiationChat extends StatefulWidget {
  final NegotiationEngine engine;
  final int grantsUsedTonight;
  final void Function(int minutes) onGranted;
  final void Function(int minutes)? onMinimize;
  final void Function()? onClose;
  final void Function()? onUnlock;
  final void Function(String identifier, int minutes)? onUnlockApp;
  final void Function(GuardianDecision decision)? onAdjustSchedule;

  /// Block+minimize / allow a distraction. Never terminates a process.
  final void Function(String identifier, String action)? onControlApp;

  /// Optional externally-owned focus node for the chat TextField. When the host
  /// (LockdownScreen) supplies this, it can re-request keyboard focus on
  /// onWindowFocus after a native foreground reclaim so typing is never lost.
  final FocusNode? inputFocusNode;

  /// True when this chat opens after a grant (the overlay is in a live grant).
  /// Shows a "clock running" banner but keeps the input enabled — the chat is
  /// continuous and unlimited.
  final bool grantActive;

  /// Optional tap target to open Settings from the chat header path. Used so a
  /// user trapped behind a missing API key can configure it without escaping.
  final void Function()? onOpenSettings;

  const NegotiationChat({
    super.key,
    required this.engine,
    required this.grantsUsedTonight,
    required this.onGranted,
    this.onMinimize,
    this.onClose,
    this.onUnlock,
    this.onUnlockApp,
    this.onAdjustSchedule,
    this.onControlApp,
    this.inputFocusNode,
    this.grantActive = false,
    this.onOpenSettings,
  });

  @override
  State<NegotiationChat> createState() => _NegotiationChatState();
}

class _ChatMessage {
  /// Mutable so a guardian bubble can grow token-by-token while streaming and
  /// be finalized in place.
  String text;
  final bool isUser;

  /// When set on a guardian message, a small info chip is shown beneath the
  /// bubble describing the real outcome of an adjust_schedule call.
  String? scheduleNote;

  /// System messages render as a centered banner (e.g. "guardian offline —
  /// configure API key") with an inline action, not a guardian chat bubble.
  final bool isSystem;

  /// True while the guardian's reply is still arriving over the stream. Drives
  /// the thinking indicator (before the first token) and the blinking cursor
  /// (once text is flowing). Cleared when the bubble is finalized.
  bool streaming;

  /// True when this is a degraded "guardian unreachable" reply (the engine
  /// flagged the decision offline after retries). Renders amber with a retry
  /// hint so it never reads as a real, cruel-sounding refusal. Set via cascade
  /// when the bubble is finalized, so it isn't a constructor argument.
  bool offline = false;

  _ChatMessage({
    required this.text,
    required this.isUser,
    this.isSystem = false,
    this.streaming = false,
  });
}

class _NegotiationChatState extends State<NegotiationChat> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// Owned only when the host did not supply one. When the host supplies
  /// [widget.inputFocusNode] we use that and must NOT dispose it.
  FocusNode? _ownFocusNode;
  FocusNode get _focusNode =>
      widget.inputFocusNode ?? (_ownFocusNode ??= FocusNode());

  final List<_ChatMessage> _messages = [];
  bool _isLoading = false;

  /// The guardian bubble currently being streamed into, or null when no stream
  /// is in flight. Deltas mutate this bubble's text in place.
  _ChatMessage? _streamingBubble;

  /// Monotonic id for the in-flight stream. The safe word (which can fire
  /// mid-stream) bumps this so any still-arriving deltas / the finalize step
  /// for the previous turn become no-ops and never clobber the safe-word UI.
  int _streamGeneration = 0;

  /// A TRUE end of the conversation: only the safe word and a guardian
  /// end_session/close freeze the input. A grant / minimize / app-unlock keeps
  /// the chat live and continuous (unlimited chat), so the user can keep
  /// negotiating without re-opening a fresh session that has no recall.
  bool _negotiationOver = false;

  /// Count of consecutive offline / missing-key guardian replies. After a
  /// threshold we offer a graceful degraded release so the user isn't trapped.
  int _offlineStreak = 0;
  static const int _offlineReleaseThreshold = 3;
  bool _degradedReleaseOffered = false;

  /// 60s heartbeat for the proactive silence ping. The guardian gets a "brain
  /// of its own": if the chat is open, idle, and the user hasn't spoken in a
  /// while, it nudges — at most once per [_silencePingThrottle] so it never
  /// spams.
  Timer? _heartbeat;
  static const Duration _silenceAfter = Duration(minutes: 3);
  static const Duration _silencePingThrottle = Duration(minutes: 3);

  @override
  void initState() {
    super.initState();
    _startSession();
    _heartbeat =
        Timer.periodic(const Duration(seconds: 60), (_) => _maybeSilencePing());
  }

  /// Fire a proactive silence ping when the chat is open, idle, the user has
  /// spoken at least once, and they've been silent past [_silenceAfter] — but
  /// not more than once per [_silencePingThrottle]. Never hits the network when
  /// there's no usable key (it uses the canned fallback then).
  Future<void> _maybeSilencePing() async {
    if (!mounted || _isLoading || _negotiationOver) return;
    final lastUser = widget.engine.lastUserMessageAt;
    if (lastUser == null) return; // never nudge before the user has spoken
    if (DateTime.now().difference(lastUser) < _silenceAfter) return;
    final lastProactive = widget.engine.lastProactiveAt;
    if (lastProactive != null &&
        DateTime.now().difference(lastProactive) < _silencePingThrottle) {
      return;
    }
    final generation = ++_streamGeneration;
    final bubble = _ChatMessage(text: '', isUser: false, streaming: true);
    setState(() {
      _streamingBubble = bubble;
      _messages.add(bubble);
      _isLoading = true;
    });
    _scrollToBottom();
    try {
      final decision = await widget.engine.negotiateProactive(
        ProactiveTrigger.silence,
        onDelta: (partial) {
          if (!mounted || generation != _streamGeneration) return;
          setState(() => bubble.text = partial);
          _scrollToBottom();
        },
      );
      if (!mounted || generation != _streamGeneration) return;
      setState(() {
        bubble
          ..text = decision.message
          ..streaming = false;
        _streamingBubble = null;
        _isLoading = false;
      });
      _scrollToBottom();
    } catch (_) {
      if (mounted && generation == _streamGeneration) {
        setState(() {
          // Drop the empty streaming bubble on a failed silence ping.
          _messages.remove(bubble);
          _streamingBubble = null;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _startSession() async {
    setState(() => _isLoading = true);
    try {
      await widget.engine.startSession();
      if (widget.engine.sessionId.isEmpty || !AppConfig.hasUsableAiKey) {
        // No usable key: render a real system banner (with a Settings shortcut)
        // instead of a dead guardian bubble that can only repeat itself.
        _messages.add(_ChatMessage(
          text: 'guardian offline — no api key configured.',
          isUser: false,
          isSystem: true,
        ));
        setState(() => _isLoading = false);
        return;
      }
      // The opening line is REAL model output (a proactive guardian turn)
      // through the same tool loop — not a hardcoded string, and now STREAMED
      // token-by-token. Falls back to a canned line only if the call fails.
      final generation = ++_streamGeneration;
      final bubble = _ChatMessage(text: '', isUser: false, streaming: true);
      setState(() {
        _streamingBubble = bubble;
        _messages.add(bubble);
      });
      _scrollToBottom();
      final decision = await widget.engine.negotiateProactive(
        ProactiveTrigger.open,
        onDelta: (partial) {
          if (!mounted || generation != _streamGeneration) return;
          setState(() => bubble.text = partial);
          _scrollToBottom();
        },
      );
      if (mounted && generation == _streamGeneration) {
        setState(() {
          bubble
            ..text = decision.message
            ..streaming = false;
          _streamingBubble = null;
        });
      }
    } catch (_) {
      // Drop any half-built streaming bubble before showing the fallback.
      if (_streamingBubble != null) {
        _messages.remove(_streamingBubble);
        _streamingBubble = null;
      }
      _messages.add(_ChatMessage(text: _fallbackGreeting(), isUser: false));
    }
    if (mounted) {
      setState(() => _isLoading = false);
      _scrollToBottom();
    }
  }

  /// Safe fallback opening line used only when the proactive model call cannot
  /// run (offline / no key). The live path uses real model output.
  String _fallbackGreeting() {
    if (widget.grantsUsedTonight == 0) {
      return "it's past your bedtime. what's so important it can't wait?";
    } else if (widget.grantsUsedTonight == 1) {
      return "you're back already?";
    } else {
      return "again. really.";
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // Safe word check — shut the app down completely. This MUST fire regardless
    // of loading / negotiation-over state: a safety escape that gets silently
    // dropped because a model call is in flight (_isLoading) is unacceptable.
    // So it sits ABOVE the loading/over guard below.
    if (AppConfig.safeWord.isNotEmpty &&
        text.toLowerCase() == AppConfig.safeWord.toLowerCase()) {
      _controller.clear();
      // Cancel any in-flight stream: bump the generation so its deltas/finalize
      // become no-ops, and detach the streaming bubble so the safe-word UI wins.
      _streamGeneration++;
      setState(() {
        _streamingBubble = null;
        _messages.add(_ChatMessage(text: text, isUser: true));
        _messages.add(_ChatMessage(
          text: 'safe word accepted. shutting down.',
          isUser: false,
        ));
        _negotiationOver = true;
        _isLoading = false;
      });
      _scrollToBottom();
      await Future.delayed(const Duration(seconds: 1));
      widget.onClose?.call();
      return;
    }

    if (_isLoading || _negotiationOver) return;

    _controller.clear();
    // Open a fresh stream generation and a guardian bubble in the "streaming"
    // state. Until the first delta arrives the bubble shows a thinking
    // indicator; deltas grow its text live; completion finalizes it below.
    final generation = ++_streamGeneration;
    final bubble = _ChatMessage(text: '', isUser: false, streaming: true);
    setState(() {
      _messages.add(_ChatMessage(text: text, isUser: true));
      _streamingBubble = bubble;
      _messages.add(bubble);
      _isLoading = true;
    });
    _scrollToBottom();

    try {
      final decision = await widget.engine.negotiate(
        text,
        onDelta: (partial) {
          // Ignore deltas from a superseded stream (e.g. safe word fired).
          if (!mounted || generation != _streamGeneration) return;
          setState(() => bubble.text = partial);
          _scrollToBottom();
        },
      );
      // A superseded stream (safe word mid-flight) must not clobber the UI.
      if (!mounted || generation != _streamGeneration) return;
      setState(() {
        bubble
          ..text = decision.message
          ..scheduleNote = decision.scheduleOutcomeNote
          ..offline = decision.offline
          ..streaming = false;
        _streamingBubble = null;
        _isLoading = false;
      });
      _trackOfflineStreak(decision);

      // A HARD end (only close / unlock == end_session) freezes the input. A
      // grant / minimize / app-unlock is NOT a hard end — the chat stays live
      // and continuous so the user can keep negotiating (unlimited chat). The
      // host still gets the callback to apply the grant; the chat re-opens onto
      // the SAME engine, so history survives grant -> relock -> re-open.
      final isHardEnd = decision.action == GuardianAction.close ||
          decision.action == GuardianAction.unlock;

      if (isHardEnd) {
        _negotiationOver = true;
        await Future.delayed(const Duration(seconds: 2));
        if (decision.action == GuardianAction.close) {
          widget.onClose?.call();
        } else {
          widget.onUnlock?.call();
        }
      } else {
        switch (decision.action) {
          case GuardianAction.grant:
            await Future.delayed(const Duration(seconds: 2));
            widget.onGranted(decision.minutesGranted);
          case GuardianAction.minimize:
            await Future.delayed(const Duration(seconds: 2));
            widget.onMinimize?.call(decision.minutesGranted);
          case GuardianAction.unlockApp:
            await Future.delayed(const Duration(seconds: 2));
            widget.onUnlockApp?.call(
              decision.appIdentifier ?? '',
              decision.appMinutes ?? 0,
            );
          case GuardianAction.adjustSchedule:
            // The engine already ran the proposal through the guardrails and
            // ScheduleStore before returning. We've shown the guardian's
            // message and the truthful outcome chip; just notify the host (to
            // refresh the schedule UI) and stay in the chat.
            widget.onAdjustSchedule?.call(decision);
          case GuardianAction.controlApp:
            // Block+minimize / allow a distraction. Non-terminal — the chat
            // stays live so the user can respond.
            widget.onControlApp?.call(
              decision.controlAppIdentifier ?? '',
              decision.controlAppAction ?? 'minimize',
            );
          default:
            break;
        }
      }
    } catch (e) {
      // Don't clobber the UI if this stream was superseded (safe word).
      if (mounted && generation == _streamGeneration) {
        setState(() {
          bubble
            ..text = 'something broke. try again.'
            ..streaming = false;
          _streamingBubble = null;
          _isLoading = false;
        });
      }
    }

    _scrollToBottom();
    if (!_negotiationOver) _focusNode.requestFocus();
  }

  /// Track consecutive offline / missing-key replies. The engine now flags
  /// degraded results with typed signals: [GuardianDecision.authFailure] (key
  /// missing or rejected) and [GuardianDecision.offline] (unreachable after
  /// retries). After [_offlineReleaseThreshold] in a row we offer a graceful
  /// degraded release so a stuck user isn't trapped (the only other escape
  /// being the safe word). A clean (non-degraded) reply resets the streak.
  void _trackOfflineStreak(GuardianDecision decision) {
    // An auth failure routes straight to the settings / missing-key banner — it
    // is a configuration problem, not a transient outage, so surface it now.
    if (decision.authFailure) {
      if (!_degradedReleaseOffered) {
        _degradedReleaseOffered = true;
        _messages.add(_ChatMessage(
          text: 'guardian offline — your API key is missing or rejected. '
              'fix it in settings, or release the lockdown for now.',
          isUser: false,
          isSystem: true,
        ));
      }
      return;
    }

    final looksOffline = !AppConfig.hasUsableAiKey || decision.offline;
    if (looksOffline) {
      _offlineStreak++;
    } else {
      _offlineStreak = 0;
    }
    if (_offlineStreak >= _offlineReleaseThreshold && !_degradedReleaseOffered) {
      _degradedReleaseOffered = true;
      _messages.add(_ChatMessage(
        text: 'guardian can\'t reach its brain right now. configure an API key '
            'in settings, or release the lockdown for now.',
        isUser: false,
        isSystem: true,
      ));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    // Only dispose a focus node we created. A host-supplied node is owned by
    // the host (LockdownScreen) and must outlive this widget.
    _ownFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.grantActive) _buildClockRunningBanner(),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            // The trailing typing indicator only shows when we're loading but
            // have NOT yet inserted a streaming bubble (e.g. the brief gap
            // before a stream opens). Once a streaming bubble exists it carries
            // its own thinking indicator / live text, so we don't double up.
            itemCount: _messages.length +
                ((_isLoading && _streamingBubble == null) ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _messages.length) return _buildTypingIndicator();
              return _buildMessage(_messages[index]);
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          decoration: BoxDecoration(
            color: const Color(0xFF12122A),
            border: Border(
              top: BorderSide(color: Colors.white.withAlpha(12)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  enabled: !_negotiationOver,
                  style: TextStyle(
                    color: Colors.white.withAlpha(220),
                    fontSize: 15,
                  ),
                  decoration: InputDecoration(
                    hintText: _negotiationOver
                        ? 'Done.'
                        : 'Make your case...',
                    hintStyle: TextStyle(color: Colors.white.withAlpha(50)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Colors.white.withAlpha(10),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                  textInputAction: TextInputAction.send,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _isLoading || _negotiationOver ? null : _sendMessage,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _isLoading || _negotiationOver
                        ? Colors.white.withAlpha(8)
                        : const Color(0xFF5B5FEF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.arrow_upward_rounded,
                    color: _isLoading || _negotiationOver
                        ? Colors.white.withAlpha(30)
                        : Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A small "clock running" banner shown inside the chat while a grant is
  /// live. The input stays enabled beneath it — the chat is continuous.
  Widget _buildClockRunningBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFFFF9500).withAlpha(28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.timer_outlined, size: 14, color: Color(0xFFFF9500)),
          const SizedBox(width: 8),
          Text(
            'clock running — keep talking if you need more',
            style: TextStyle(
              color: const Color(0xFFFF9500).withAlpha(220),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  /// System banner (centered) with the missing-key / degraded-release affordance
  /// rather than a dead guardian bubble.
  Widget _buildSystemMessage(_ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFF9500).withAlpha(24),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFFF9500).withAlpha(80)),
        ),
        child: Column(
          children: [
            Text(
              msg.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: const Color(0xFFFFB95E),
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => widget.onOpenSettings?.call(),
                  icon: const Icon(Icons.settings_rounded,
                      size: 16, color: Color(0xFFFFB95E)),
                  label: const Text(
                    'Go to Settings',
                    style: TextStyle(color: Color(0xFFFFB95E), fontSize: 13),
                  ),
                ),
                if (_degradedReleaseOffered) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => widget.onClose?.call(),
                    icon: const Icon(Icons.lock_open_rounded,
                        size: 16, color: Color(0xFFFFB95E)),
                    label: const Text(
                      'Release for now',
                      style: TextStyle(color: Color(0xFFFFB95E), fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessage(_ChatMessage msg) {
    if (msg.isSystem) return _buildSystemMessage(msg);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            msg.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!msg.isUser) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: const Color(0xFF5B5FEF).withAlpha(30),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.nights_stay_rounded,
                color: Color(0xFF5B5FEF),
                size: 14,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: msg.isUser
                        ? const Color(0xFF5B5FEF).withAlpha(40)
                        : msg.offline
                            ? const Color(0xFFFF9500).withAlpha(28)
                            : Colors.white.withAlpha(10),
                    borderRadius: BorderRadius.circular(16),
                    border: msg.offline
                        ? Border.all(color: const Color(0xFFFF9500).withAlpha(70))
                        : null,
                  ),
                  child: _bubbleContent(msg),
                ),
                if (msg.scheduleNote != null) ...[
                  const SizedBox(height: 6),
                  _scheduleNoteChip(msg.scheduleNote!),
                ],
                if (msg.offline) ...[
                  const SizedBox(height: 6),
                  _offlineRetryHint(),
                ],
              ],
            ),
          ),
          if (msg.isUser) const SizedBox(width: 38),
        ],
      ),
    );
  }

  /// The inner content of a guardian/user bubble. While a guardian bubble is
  /// streaming with no text yet, show an animated thinking indicator; once
  /// tokens arrive, show the live text with a subtle blinking cursor until the
  /// stream completes. Finalized / user bubbles are plain text.
  Widget _bubbleContent(_ChatMessage msg) {
    final textStyle = TextStyle(
      color: Colors.white.withAlpha(220),
      fontSize: 15,
      height: 1.4,
    );
    if (msg.streaming && msg.text.isEmpty) {
      return const _ThinkingDots();
    }
    if (msg.streaming) {
      // Live text with a trailing blinking cursor.
      return RichText(
        text: TextSpan(
          style: textStyle,
          children: [
            TextSpan(text: msg.text),
            const WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _BlinkingCursor(),
            ),
          ],
        ),
      );
    }
    return Text(msg.text, style: textStyle);
  }

  Widget _scheduleNoteChip(String note) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF5B5FEF).withAlpha(30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF5B5FEF).withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.schedule_rounded,
            size: 13,
            color: Color(0xFF8E8EFF),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              note,
              style: const TextStyle(
                color: Color(0xFF8E8EFF),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A small amber hint beneath an offline guardian bubble. Reassures the user
  /// the deny is a transient outage, not a real refusal, and points at the
  /// recovery affordances (retry / safe word).
  Widget _offlineRetryHint() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off_rounded, size: 13, color: Color(0xFFFFB95E)),
        const SizedBox(width: 6),
        Text(
          'guardian unreachable — send again, or use your safe word',
          style: TextStyle(
            color: const Color(0xFFFFB95E).withAlpha(220),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: const Color(0xFF5B5FEF).withAlpha(30),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.nights_stay_rounded,
              color: Color(0xFF5B5FEF),
              size: 14,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(10),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const _ThinkingDots(),
          ),
        ],
      ),
    );
  }
}

/// Animated three-dot "thinking" indicator shown before the first streamed
/// token arrives. Each dot fades in/out on a staggered cycle.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Stagger each dot's phase across the cycle.
            final phase = (_controller.value - i * 0.2) % 1.0;
            final t = phase < 0 ? phase + 1.0 : phase;
            // Triangle wave 0->1->0 for a smooth fade pulse.
            final pulse = t < 0.5 ? t * 2 : (1 - t) * 2;
            final alpha = (80 + pulse * 140).round().clamp(0, 255);
            return Padding(
              padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(alpha),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// A subtle blinking cursor appended to the live streaming text until the
/// guardian's reply completes.
class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor();

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final visible = _controller.value < 0.5;
        return Opacity(
          opacity: visible ? 1.0 : 0.0,
          child: Container(
            width: 2,
            height: 16,
            margin: const EdgeInsets.only(left: 2),
            color: const Color(0xFF8E8EFF),
          ),
        );
      },
    );
  }
}
