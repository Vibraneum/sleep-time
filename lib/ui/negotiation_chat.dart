import 'package:flutter/material.dart';
import '../core/negotiation_engine.dart';

class NegotiationChat extends StatefulWidget {
  final NegotiationEngine engine;
  final int grantsUsedTonight;
  final void Function(int minutes) onGranted;

  const NegotiationChat({
    super.key,
    required this.engine,
    required this.grantsUsedTonight,
    required this.onGranted,
  });

  @override
  State<NegotiationChat> createState() => _NegotiationChatState();
}

class _ChatMessage {
  final String text;
  final bool isUser;
  _ChatMessage({required this.text, required this.isUser});
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
    if (text.isEmpty || _isLoading || _negotiationOver) return;

    _controller.clear();
    setState(() {
      _messages.add(_ChatMessage(text: text, isUser: true));
      _isLoading = true;
    });
    _scrollToBottom();

    try {
      final decision = await widget.engine.negotiate(text);
      setState(() {
        _messages.add(_ChatMessage(text: decision.message, isUser: false));
        _isLoading = false;
      });

      if (decision.granted) {
        _negotiationOver = true;
        await Future.delayed(const Duration(seconds: 2));
        widget.onGranted(decision.minutesGranted);
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
          ),
          if (msg.isUser) const SizedBox(width: 38),
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
