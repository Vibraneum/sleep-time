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

  _ChatMessage({required this.text, required this.isUser, this.scheduleNote});
}

class _NegotiationChatState extends State<NegotiationChat> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final List<_ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _negotiationOver = false;

  @override
  void initState() {
    super.initState();
    _startSession();
  }

  Future<void> _startSession() async {
    setState(() => _isLoading = true);
    try {
      await widget.engine.startSession();
      // The first response from startSession is the greeting
      final greeting = widget.engine.sessionId.isNotEmpty
          ? _getGreeting()
          : "set your gemini api key in settings.";
      _messages.add(_ChatMessage(text: greeting, isUser: false));
    } catch (_) {
      _messages.add(
          _ChatMessage(text: "couldn't connect. check your api key.", isUser: false));
    }
    setState(() => _isLoading = false);
  }

  String _getGreeting() {
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

      // adjustSchedule stays in chat (like deny) — application is M3.
      final isTerminal = decision.action != GuardianAction.none &&
          decision.action != GuardianAction.deny &&
          decision.action != GuardianAction.adjustSchedule;

      if (isTerminal) {
        _negotiationOver = true;
        await Future.delayed(const Duration(seconds: 2));
        switch (decision.action) {
          case GuardianAction.grant:
            widget.onGranted(decision.minutesGranted);
          case GuardianAction.minimize:
            widget.onMinimize?.call(decision.minutesGranted);
          case GuardianAction.close:
            widget.onClose?.call();
          case GuardianAction.unlock:
            widget.onUnlock?.call();
          case GuardianAction.unlockApp:
            widget.onUnlockApp?.call(
              decision.appIdentifier ?? '',
              decision.appMinutes ?? 0,
            );
          default:
            break;
        }
      } else if (decision.action == GuardianAction.adjustSchedule) {
        // The engine already ran the proposal through the guardrails and
        // ScheduleStore before returning. We've shown the guardian's message
        // and the truthful outcome chip; just notify the host (to refresh the
        // schedule UI) and stay in the chat — adjust_schedule is not terminal.
        widget.onAdjustSchedule?.call(decision);
      }
    } catch (e) {
      setState(() {
        _messages.add(
            _ChatMessage(text: "something broke. try again.", isUser: false));
        _isLoading = false;
      });
    }

    _scrollToBottom();
    _focusNode.requestFocus();
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
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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

  Widget _buildMessage(_ChatMessage msg) {
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
