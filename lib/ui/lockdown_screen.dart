import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../core/lockdown_scheduler.dart';
import '../core/negotiation_engine.dart';
import '../core/config.dart';
import '../core/schedule_store.dart';
import '../platform/windows_lockdown.dart';
import '../platform/windows_lock_state.dart';
import 'negotiation_chat.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

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

  Future<void> _onMinimize(int minutes) async {
    // Use the guardian's real granted minutes (fall back to a small default if
    // the model omitted a duration). Previously hardcoded to 30 (M1 note).
    final grantMinutes = minutes > 0 ? minutes : AppConfig.minGrantedMinutes;
    widget.scheduler.grantExtension(grantMinutes);
    await WindowsLockdown.deactivate();
    if (Platform.isWindows && !AppConfig.simulateLockdown) {
      try {
        await windowManager.minimize();
      } catch (_) {}
    }
  }

  /// Selective per-app unlock: keep the overlay armed but allow [identifier]
  /// (a friendly name or image name) for [minutes]. Resolution to an image
  /// name happens in [WindowsLockdown] via the scheduler's onSelectiveGrant.
  void _onUnlockApp(String identifier, int minutes) {
    final allow = WindowsAppResolver.resolveAll([identifier]);
    final grantMinutes = minutes > 0 ? minutes : AppConfig.minGrantedMinutes;
    if (allow.isEmpty) {
      // Nothing resolvable — degrade to a normal timed grant rather than
      // silently doing nothing.
      widget.scheduler.grantExtension(grantMinutes);
      return;
    }
    widget.scheduler.grantSelective(allow: allow, minutes: grantMinutes);
    setState(() => _showChat = false);
  }

  Future<void> _onClose() async {
    widget.scheduler.fullUnlock();
    await WindowsLockdown.deactivate();
    // In simulate mode (or on mobile) just return to the home screen instead
    // of killing the process — closing makes no sense in dev / on Android.
    if (AppConfig.simulateLockdown || !Platform.isWindows) {
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (_) => false,
        );
      }
      return;
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  void _onUnlock() {
    widget.scheduler.fullUnlock();
    WindowsLockdown.deactivate();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (_) => false,
      );
    }
  }

  /// The engine already applied the schedule change (through the guardrails and
  /// ScheduleStore) before returning, so we only need to refresh the UI — the
  /// schedule card and unlock-time text rebuild via ScheduleStore listeners.
  void _onAdjustSchedule(GuardianDecision decision) {
    if (mounted) setState(() {});
  }

  @override
  Future<void> onWindowClose() async {
    if (AppConfig.simulateLockdown) return;
    if (widget.scheduler.state == LockdownState.locked) {
      await windowManager.focus();
      return;
    }
    await windowManager.destroy();
  }

  @override
  Future<void> onWindowBlur() async {
    if (AppConfig.simulateLockdown) return;
    if (!WindowsLockdown.isLocked) return;
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
    } catch (_) {}
  }

  @override
  Future<void> onWindowMinimize() async {
    if (AppConfig.simulateLockdown) return;
    if (!WindowsLockdown.isLocked) return;
    try {
      await windowManager.restore();
      await windowManager.focus();
    } catch (_) {}
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

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Widget _buildLockedView() {
    return Stack(
      children: [
        if (AppConfig.simulateLockdown)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9500).withAlpha(40),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFFF9500).withAlpha(120),
                  ),
                ),
                child: const Text(
                  'SAFE MODE — simulated lockdown',
                  style: TextStyle(
                    color: Color(0xFFFF9500),
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        Center(
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
          ListenableBuilder(
            listenable: ScheduleStore.instance,
            builder: (context, _) => Text(
              'Unlocks at ${AppConfig.formatTime(AppConfig.unlockHour, AppConfig.unlockMinute)}',
              style: TextStyle(
                color: Colors.white.withAlpha(40),
                fontSize: 12,
              ),
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
        ),
        Positioned(
          bottom: 24,
          right: 24,
          child: GestureDetector(
            onTap: _openSettings,
            child: Icon(
              Icons.settings_rounded,
              color: Colors.white.withAlpha(30),
              size: 20,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatView() {
    // Tell the engine whether we're inside lockdown so the guardrails can
    // forbid the AI from moving tonight's lockdown once it has started. The
    // chat is reachable from both locked and granted states.
    _engine.lockdownActive = widget.scheduler.state == LockdownState.locked ||
        widget.scheduler.state == LockdownState.granted;
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
            onMinimize: _onMinimize,
            onClose: _onClose,
            onUnlock: _onUnlock,
            onUnlockApp: _onUnlockApp,
            onAdjustSchedule: _onAdjustSchedule,
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
