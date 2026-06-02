import 'package:flutter/material.dart';

import '../core/permission_gating.dart';
import '../platform/android_lockdown.dart';

/// Stepped Android permission onboarding.
///
/// Order: notifications → overlay → usage-access (REQUIRED) → exact-alarm →
/// battery (warn only) → Accessibility (OPTIONAL, with a MANDATORY prominent
/// disclosure dialog before the redirect).
///
/// Hard gates (block "Done"): overlay + usage-access + exact-alarm
/// ([PermissionGating.hardGates]). The app is fully functional with
/// accessibility DISABLED — usage-access is the primary detector — so
/// accessibility and battery never block completion.
///
/// Permission grants happen in other apps, so we re-read status on resume
/// (both via the lifecycle observer and the native onResume push).
class PermissionsOnboardingScreen extends StatefulWidget {
  /// Called once when the user finishes (all hard gates satisfied) or chooses
  /// to leave. The host decides whether to activate the guardian.
  final VoidCallback? onComplete;

  const PermissionsOnboardingScreen({super.key, this.onComplete});

  @override
  State<PermissionsOnboardingScreen> createState() =>
      _PermissionsOnboardingScreenState();
}

class _PermissionsOnboardingScreenState
    extends State<PermissionsOnboardingScreen> with WidgetsBindingObserver {
  AndroidPermissionStatus _status = const AndroidPermissionStatus();
  String _manufacturer = '';
  bool _loading = true;

  static const _bg = Color(0xFFF0F4FA);
  static const _indigo = Color(0xFF5B5FEF);
  static const _ink = Color(0xFF1A1A2E);
  static const _muted = Color(0xFF8E8EA0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AndroidLockdown.setPermissionStatusListener((status) {
      if (mounted) setState(() => _status = status);
    });
    _refresh();
    _loadManufacturer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AndroidLockdown.setPermissionStatusListener(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final status = await AndroidLockdown.getPermissionStatus();
    if (mounted) {
      setState(() {
        _status = status;
        _loading = false;
      });
    }
  }

  Future<void> _loadManufacturer() async {
    final m = await AndroidLockdown.deviceManufacturer();
    if (mounted) setState(() => _manufacturer = m);
  }

  bool _granted(OnboardingPermission p) =>
      PermissionGating.isGranted(p, _status);

  bool get _canFinish => PermissionGating.canFinish(_status);

  Future<void> _request(OnboardingPermission perm) async {
    switch (perm) {
      case OnboardingPermission.notifications:
        await AndroidLockdown.requestNotifications();
      case OnboardingPermission.overlay:
        await AndroidLockdown.requestOverlay();
      case OnboardingPermission.usageAccess:
        await AndroidLockdown.requestUsageAccess();
      case OnboardingPermission.exactAlarm:
        await AndroidLockdown.requestExactAlarm();
      case OnboardingPermission.battery:
        await AndroidLockdown.requestBatteryExemption();
      case OnboardingPermission.accessibility:
        // MANDATORY prominent disclosure BEFORE any redirect.
        final consented = await _showAccessibilityDisclosure();
        if (consented == true) {
          await AndroidLockdown.requestAccessibility();
        }
    }
    // Status will refresh on resume; also poke now for the in-app prompt case.
    await _refresh();
  }

  Future<bool?> _showAccessibilityDisclosure() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Optional: faster bedtime lock',
          style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w600, color: _ink),
        ),
        content: const SingleChildScrollView(
          child: Text(
            'Sleep Time can use an Accessibility helper to notice which app is '
            'in front a little faster while your bedtime lock is active, so the '
            'lock screen appears more promptly.\n\n'
            'This is a Digital Wellbeing / bedtime feature. The helper only '
            'observes when you switch apps — it never reads your screen '
            'content, never taps or types for you, and never sends anything '
            'anywhere.\n\n'
            'Sleep Time works fully without this. It normally uses Usage Access '
            'instead. You can turn the helper off any time in system settings.\n\n'
            'On the next screen, enable "Sleep Time bedtime helper" to allow it.',
            style: TextStyle(fontSize: 14, color: _muted, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now', style: TextStyle(color: _muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Continue',
              style:
                  TextStyle(color: _indigo, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _finish() => widget.onComplete?.call();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: _ink,
        title: const Text('Set up permissions',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sleep Time needs a few permissions to keep your bedtime '
                    'lock working in the background. Usage Access is the most '
                    'important — it lets the guardian see which app is in front.',
                    style: TextStyle(fontSize: 14, color: _muted, height: 1.5),
                  ),
                  const SizedBox(height: 20),
                  _stepCard(
                    OnboardingPermission.notifications,
                    Icons.notifications_rounded,
                    'Notifications',
                    'Shows the persistent guardian notification and bedtime '
                        'reminders.',
                  ),
                  _stepCard(
                    OnboardingPermission.overlay,
                    Icons.layers_rounded,
                    'Display over other apps',
                    'Draws the gentle lock screen over apps at bedtime.',
                  ),
                  _stepCard(
                    OnboardingPermission.usageAccess,
                    Icons.bar_chart_rounded,
                    'Usage access',
                    'The primary way the guardian knows which app is in front. '
                        'Required.',
                  ),
                  _stepCard(
                    OnboardingPermission.exactAlarm,
                    Icons.alarm_rounded,
                    'Alarms & reminders',
                    'Fires the wind-down / lock / unlock transitions on time.',
                  ),
                  _stepCard(
                    OnboardingPermission.battery,
                    Icons.battery_charging_full_rounded,
                    'Unrestricted battery',
                    _batterySubtitle(),
                  ),
                  _stepCard(
                    OnboardingPermission.accessibility,
                    Icons.bolt_rounded,
                    'Faster lock (optional)',
                    'Optional Digital Wellbeing helper. Observe-only. The app '
                        'works fully without it.',
                  ),
                  const SizedBox(height: 16),
                  if (!_canFinish)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Grant the required permissions above (display over '
                        'apps, usage access, alarms) to continue.',
                        style: TextStyle(
                          fontSize: 13,
                          color: const Color(0xFFFF3B30).withAlpha(200),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _canFinish ? _finish : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _indigo,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            _indigo.withAlpha(60),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Done',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  String _batterySubtitle() {
    final base =
        'Keeps overnight alarms reliable. Recommended but not required.';
    final hint = _oemBatteryHint();
    return hint == null ? base : '$base\n$hint';
  }

  /// Best-effort OEM hint. Deep-linking to OEM-specific battery screens is
  /// fragile, so we only nudge the user toward the right place; the request
  /// itself always falls back to the generic battery dialog natively.
  String? _oemBatteryHint() {
    if (_manufacturer.contains('samsung')) {
      return 'On Samsung: also set Battery → Unrestricted in the app info.';
    }
    if (_manufacturer.contains('xiaomi') ||
        _manufacturer.contains('redmi') ||
        _manufacturer.contains('poco')) {
      return 'On Xiaomi/MIUI: set Battery saver → No restrictions and enable '
          'Autostart.';
    }
    if (_manufacturer.contains('oneplus') ||
        _manufacturer.contains('oppo') ||
        _manufacturer.contains('realme')) {
      return 'On OnePlus/Oppo: set Battery → Don\'t optimize and allow '
          'background activity.';
    }
    return null;
  }

  Widget _stepCard(
    OnboardingPermission perm,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final granted = _granted(perm);
    final hard = PermissionGating.isHardGate(perm);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 16,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: granted
                  ? const Color(0xFFE8F8ED)
                  : _indigo.withAlpha(24),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              granted ? Icons.check_rounded : icon,
              color: granted ? const Color(0xFF34C759) : _indigo,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _ink,
                        ),
                      ),
                    ),
                    if (hard) ...[
                      const SizedBox(width: 8),
                      _pill('Required', const Color(0xFFFF9500)),
                    ] else ...[
                      const SizedBox(width: 8),
                      _pill('Optional', _muted),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                      fontSize: 12, color: _muted, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!granted)
            TextButton(
              onPressed: () => _request(perm),
              child: const Text('Grant',
                  style: TextStyle(
                      color: _indigo, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
