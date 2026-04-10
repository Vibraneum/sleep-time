import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/lockdown_scheduler.dart';
import '../core/config.dart';
import '../core/memory_service.dart';
import '../platform/android_lockdown.dart';
import '../platform/windows_lockdown.dart';
import 'lockdown_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late LockdownScheduler _scheduler;
  late Future<double> _complianceFuture;
  LockdownState _currentState = LockdownState.unlocked;
  Duration? _grantRemaining;

  @override
  void initState() {
    super.initState();
    _complianceFuture = MemoryService.getComplianceRate();
    _scheduler = LockdownScheduler(
      onStateChange: _onStateChange,
      onGrantTick: (remaining) => setState(() => _grantRemaining = remaining),
      onGrantExpired: () {
        setState(() => _grantRemaining = null);
        _onStateChange(LockdownState.locked);
      },
    );
    _scheduler.start();
    if (AppConfig.simulateLockdown) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _showLockdownScreen();
      });
    }
  }

  void _onStateChange(LockdownState state) {
    if (!mounted) return;
    setState(() {
      _currentState = state;
      if (state == LockdownState.unlocked) {
        _complianceFuture = MemoryService.getComplianceRate();
      }
    });
    unawaited(_syncPlatformLockdown(state));
    if (state == LockdownState.locked) _showLockdownScreen();
  }

  Future<void> _syncPlatformLockdown(LockdownState state) async {
    switch (state) {
      case LockdownState.locked:
        await WindowsLockdown.activate();
        await AndroidLockdown.activate();
        break;
      case LockdownState.granted:
        await WindowsLockdown.grantExtension();
        await AndroidLockdown.grantExtension();
        break;
      case LockdownState.unlocked:
      case LockdownState.awake:
      case LockdownState.windDown:
      case LockdownState.inactive:
        await WindowsLockdown.deactivate();
        await AndroidLockdown.deactivate();
        break;
    }
  }

  void _showLockdownScreen() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LockdownScreen(scheduler: _scheduler)),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _scheduler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FA),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 28),
              _buildStatusCard(),
              const SizedBox(height: 16),
              _buildScheduleCard(),
              const SizedBox(height: 16),
              _buildStatsCard(),
              if (kDebugMode) ...[
                const SizedBox(height: 24),
                Center(
                  child: TextButton(
                    onPressed: _showLockdownScreen,
                    child: Text(
                      'Test Lockdown',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sleep Time',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A2E),
                letterSpacing: -0.5,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'your sleep guardian',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF8E8EA0),
              ),
            ),
          ],
        ),
        GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(10),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(
              Icons.settings_rounded,
              color: Color(0xFF8E8EA0),
              size: 22,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusCard() {
    final (icon, color, bg, label, subtitle) = switch (_currentState) {
      LockdownState.unlocked => (
          Icons.wb_sunny_rounded,
          const Color(0xFF34C759),
          const Color(0xFFE8F8ED),
          "You're free",
          'No lockdown active',
        ),
      LockdownState.awake => (
          Icons.visibility_rounded,
          const Color(0xFF5B5FEF),
          const Color(0xFFEEEEFC),
          'Guardian is watching',
          'Monitoring your activity',
        ),
      LockdownState.windDown => (
          Icons.nights_stay_rounded,
          const Color(0xFFFF9500),
          const Color(0xFFFFF3E0),
          'Time to wind down',
          'Lockdown starting soon',
        ),
      LockdownState.locked => (
          Icons.lock_rounded,
          const Color(0xFFFF3B30),
          const Color(0xFFFFE5E3),
          'Locked down',
          'Negotiate to unlock',
        ),
      LockdownState.granted => (
          Icons.timer_outlined,
          const Color(0xFFFF9500),
          const Color(0xFFFFF3E0),
          'Extension active',
          _grantRemaining != null
              ? '${_grantRemaining!.inMinutes}:${(_grantRemaining!.inSeconds % 60).toString().padLeft(2, '0')} remaining'
              : 'Time is ticking',
        ),
      LockdownState.inactive => (
          Icons.power_settings_new_rounded,
          const Color(0xFF8E8EA0),
          const Color(0xFFF0F0F5),
          'Inactive',
          'Waiting for schedule',
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF8E8EA0),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Schedule',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8E8EA0),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 14),
          _scheduleRow(
            Icons.visibility_rounded,
            'Guardian wakes',
            AppConfig.formatTime(AppConfig.wakeUpHour, AppConfig.wakeUpMinute),
            const Color(0xFF5B5FEF),
          ),
          _scheduleRow(
            Icons.nights_stay_rounded,
            'Wind down',
            AppConfig.formatTime(
                AppConfig.windDownHour, AppConfig.windDownMinute),
            const Color(0xFFFF9500),
          ),
          _scheduleRow(
            Icons.lock_rounded,
            'Lockdown',
            AppConfig.formatTime(
                AppConfig.lockdownHour, AppConfig.lockdownMinute),
            const Color(0xFFFF3B30),
          ),
          _scheduleRow(
            Icons.lock_open_rounded,
            'Unlock',
            AppConfig.formatTime(AppConfig.unlockHour, AppConfig.unlockMinute),
            const Color(0xFF34C759),
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _scheduleRow(
    IconData icon,
    String label,
    String time,
    Color color, {
    bool isLast = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const Spacer(),
          Text(
            time,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard() {
    return FutureBuilder<double>(
      future: _complianceFuture,
      builder: (context, snapshot) {
        final compliance = snapshot.data ?? 1.0;
        final percent = (compliance * 100).toStringAsFixed(0);
        final color = compliance >= 0.8
            ? const Color(0xFF34C759)
            : compliance >= 0.5
                ? const Color(0xFFFF9500)
                : const Color(0xFFFF3B30);

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(8),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '7-Day Compliance',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF8E8EA0),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    '$percent%',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: compliance,
                        backgroundColor: const Color(0xFFF0F0F5),
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                        minHeight: 8,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
