import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/permission_gating.dart';
import 'package:sleep_time/platform/android_lockdown.dart';

void main() {
  group('PermissionGating hard gates', () {
    test('overlay, usageAccess, exactAlarm are hard gates', () {
      expect(PermissionGating.isHardGate(OnboardingPermission.overlay), isTrue);
      expect(
          PermissionGating.isHardGate(OnboardingPermission.usageAccess), isTrue);
      expect(
          PermissionGating.isHardGate(OnboardingPermission.exactAlarm), isTrue);
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
        overlay: true,
        usageAccess: true,
        exactAlarm: false, // missing hard gate
        accessibility: true,
        batteryExemption: true,
        notifications: true,
      );
      expect(PermissionGating.canFinish(status), isFalse);
    });

    test('true when all hard gates granted, regardless of optional ones', () {
      const status = AndroidPermissionStatus(
        overlay: true,
        usageAccess: true,
        exactAlarm: true,
        // optional ones all false — must NOT block finishing
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
      expect(missing, contains(OnboardingPermission.exactAlarm));
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
