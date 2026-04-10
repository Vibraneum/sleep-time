import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../core/lockdown_scheduler.dart';
import '../core/negotiation_engine.dart';
import '../core/config.dart';
import 'negotiation_chat.dart';

class LockdownScreen extends StatefulWidget {
  final LockdownScheduler scheduler;
  const LockdownScreen({super.key, required this.scheduler});

  @override
  State<LockdownScreen> createState() => _LockdownScreenState();
}

class _LockdownScreenState extends State<LockdownScreen>
    with TickerProviderStateMixin, WindowListener {
  final _engine = NegotiationEngine();
  final _keyboardFocusNode = FocusNode();
  bool _showChat = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
    }
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    _pulseController.dispose();
    _keyboardFocusNode.dispose();
    _engine.dispose();
    super.dispose();
  }

  void _onGranted(int minutes) {
    widget.scheduler.grantExtension(minutes);
    setState(() => _showChat = false);
  }

  @override
  Future<void> onWindowClose() async {
    if (widget.scheduler.state == LockdownState.locked) {
      await windowManager.focus();
      return;
    }
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: KeyboardListener(
        focusNode: _keyboardFocusNode,
        onKeyEvent: (event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.f4) {
              // Blocked
            }
          }
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF0D0D1A),
          body: SafeArea(child: _buildContent()),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (widget.scheduler.state == LockdownState.granted) {
      return _buildGrantedView();
    }
    if (_showChat) return _buildChatView();
    return _buildLockedView();
  }

  Widget _buildLockedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) => Opacity(
              opacity: 0.4 + (_pulseController.value * 0.6),
              child: const Icon(
                Icons.nights_stay_rounded,
                size: 72,
                color: Color(0xFF5B5FEF),
              ),
            ),
          ),
          const SizedBox(height: 32),
          StreamBuilder(
            stream: Stream.periodic(const Duration(seconds: 1)),
            builder: (context, _) {
              final now = DateTime.now();
              return Text(
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 56,
                  fontWeight: FontWeight.w200,
                  letterSpacing: 6,
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Lockdown active',
            style: TextStyle(
              color: Colors.white.withAlpha(80),
              fontSize: 14,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Unlocks at ${AppConfig.formatTime(AppConfig.unlockHour, AppConfig.unlockMinute)}',
            style: TextStyle(
              color: Colors.white.withAlpha(40),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 56),
          GestureDetector(
            onTap: () => setState(() => _showChat = true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withAlpha(20)),
                color: Colors.white.withAlpha(8),
              ),
              child: Text(
                'Negotiate',
                style: TextStyle(
                  color: Colors.white.withAlpha(100),
                  fontSize: 15,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatView() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.white.withAlpha(12)),
            ),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _showChat = false),
                child: Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white.withAlpha(100),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF5B5FEF).withAlpha(40),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.nights_stay_rounded,
                  color: Color(0xFF5B5FEF),
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Sleep Guardian',
                style: TextStyle(
                  color: Colors.white.withAlpha(200),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: NegotiationChat(
            engine: _engine,
            grantsUsedTonight: widget.scheduler.grantsUsedTonight,
            onGranted: _onGranted,
          ),
        ),
      ],
    );
  }

  Widget _buildGrantedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.timer_outlined, size: 48, color: Color(0xFFFF9500)),
          const SizedBox(height: 24),
          Text(
            'Extension granted',
            style: TextStyle(
              color: Colors.white.withAlpha(140),
              fontSize: 14,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 16),
          StreamBuilder(
            stream: Stream.periodic(const Duration(seconds: 1)),
            builder: (context, _) {
              final remaining = widget.scheduler.grantRemaining;
              if (remaining == null) return const SizedBox.shrink();
              final mins = remaining.inMinutes;
              final secs = remaining.inSeconds % 60;
              final urgent = remaining.inMinutes < 2;
              return Text(
                '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}',
                style: TextStyle(
                  color: urgent
                      ? const Color(0xFFFF3B30)
                      : const Color(0xFFFF9500),
                  fontSize: 52,
                  fontWeight: FontWeight.w200,
                  letterSpacing: 4,
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            'remaining',
            style: TextStyle(color: Colors.white.withAlpha(50), fontSize: 12),
          ),
        ],
      ),
    );
  }
}
