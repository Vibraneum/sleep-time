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
  final String text;
  final bool isUser;

  /// When set on a guardian message, a small info chip is shown beneath the
  /// bubble describing the real outcome of an adjust_schedule call.
  final String? scheduleNote;

  /// System messages render as a centered banner (e.g. "guardian offline —
  /// configure API key") with an inline action, not a guardian chat bubble.
  final bool isSystem;

  _ChatMessage({
    required this.text,
    required this.isUser,
    this.scheduleNote,
    this.isSystem = false,
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
    setState(() => _isLoading = true);
    try {
      final decision =
          await widget.engine.negotiateProactive(ProactiveTrigger.silence);
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(text: decision.message, isUser: false));
        _isLoading = false;
      });
      _scrollToBottom();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
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
      // through the same tool loop — not a hardcoded string. Falls back to a
      // canned line only if the proactive call fails.
      final decision =
          await widget.engine.negotiateProactive(ProactiveTrigger.open);
      _messages.add(_ChatMessage(text: decision.message, isUser: false));
    } catch (_) {
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
      setState(() {
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
    setState(() {
      _messages.add(_ChatMessage(text: text, isUser: true));
      _isLoading = true;
    });
    _scrollToBottom();

    try {
      final decision = await widget.engine.negotiate(text);
      setState(() {
        _messages.add(_ChatMessage(
          text: decision.message,
          isUser: false,
          scheduleNote: decision.scheduleOutcomeNote,
        ));
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
      setState(() {
        _messages.add(
            _ChatMessage(text: "something broke. try again.", isUser: false));
        _isLoading = false;
      });
    }

    _scrollToBottom();
    if (!_negotiationOver) _focusNode.requestFocus();
  }

  /// Track consecutive offline / missing-key replies. The engine returns a
  /// `deny`-action bubble with one of its canned offline lines when it cannot
  /// reach the model; after [_offlineReleaseThreshold] in a row we offer a
  /// graceful degraded release so a no-key user isn't trapped (the only other
  /// escape being the safe word).
  void _trackOfflineStreak(GuardianDecision decision) {
    final looksOffline = !AppConfig.hasUsableAiKey ||
        decision.message == 'guardian is offline. try again.' ||
        decision.message == 'something broke. try again.';
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
            itemCount: _messages.length + (_isLoading ? 1 : 0),
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
                        : Colors.white.withAlpha(10),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    msg.text,
                    style: TextStyle(
                      color: Colors.white.withAlpha(220),
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ),
                if (msg.scheduleNote != null) ...[
                  const SizedBox(height: 6),
                  _scheduleNoteChip(msg.scheduleNote!),
                ],
              ],
            ),
          ),
          if (msg.isUser) const SizedBox(width: 38),
        ],
      ),
    );
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
            child: Text(
              '...',
              style: TextStyle(
                color: Colors.white.withAlpha(100),
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
