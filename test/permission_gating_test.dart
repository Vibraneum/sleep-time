import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/permission_gating.dart';
import 'package:sleep_time/platform/android_lockdown.dart';

void main() {
  group('PermissionGating hard gates', () {
    test('overlay, usageAccess are hard gates', () {
      expect(PermissionGating.isHardGate(OnboardingPermission.overlay), isTrue);
      expect(
          PermissionGating.isHardGate(OnboardingPermission.usageAccess), isTrue);
    });

    test('exactAlarm is NOT a hard gate (inexact fallback exists)', () {
      // Exact-alarm denial must not trap the user in onboarding: the alarm
      // scheduler has an idle-resilient inexact fallback.
      expect(PermissionGating.isHardGate(OnboardingPermission.exactAlarm),
          isFalse);
    });

    test('accessibility, battery, notifications are NOT hard gates', () {
      expect(PermissionGating.isHardGate(OnboardingPermission.accessibility),
          isFalse);
      expect(PermissionGating.isHardGate(OnboardingPermission.battery), isFalse);
      expect(PermissionGating.isHardGate(OnboardingPermission.notifications),
          isFalse);
    });
  });

  group('PermissionGating.canFinish', () {
    test('false when any hard gate missing', () {
      const status = AndroidPermissionStatus(
        overlay: false, // missing hard gate
        usageAccess: true,
        exactAlarm: true,
        accessibility: true,
        batteryExemption: true,
        notifications: true,
      );
      expect(PermissionGating.canFinish(status), isFalse);
    });

    test('true when hard gates granted even if exactAlarm is denied', () {
      const status = AndroidPermissionStatus(
        overlay: true,
        usageAccess: true,
        // exactAlarm denied — inexact fallback covers it, must NOT block.
        exactAlarm: false,
        accessibility: false,
        batteryExemption: false,
        notifications: false,
      );
      expect(PermissionGating.canFinish(status), isTrue);
    });

    test('missingHardGates lists exactly the ungranted hard gates', () {
      const status = AndroidPermissionStatus(
        overlay: true,
        usageAccess: false,
        exactAlarm: false,
      );
      final missing = PermissionGating.missingHardGates(status);
      expect(missing, contains(OnboardingPermission.usageAccess));
      // exactAlarm is no longer a hard gate, so it must NOT be listed.
      expect(missing, isNot(contains(OnboardingPermission.exactAlarm)));
      expect(missing, isNot(contains(OnboardingPermission.overlay)));
    });

    test('app works with accessibility disabled (UsageStats-only)', () {
      // Documents the core M5 invariant: accessibility off must still finish.
      const usageStatsOnly = AndroidPermissionStatus(
        overlay: true,
        usageAccess: true,
        exactAlarm: true,
        accessibility: false,
      );
      expect(PermissionGating.canFinish(usageStatsOnly), isTrue);
    });
  });
}
