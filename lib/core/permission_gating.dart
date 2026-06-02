import 'package:flutter/foundation.dart';

import '../platform/android_lockdown.dart';

/// The distinct Android permissions the onboarding flow walks through, in order.
enum OnboardingPermission {
  notifications,
  overlay,
  usageAccess,
  exactAlarm,
  battery,
  accessibility,
}

/// Pure gating logic for the Android permission onboarding, kept free of any
/// widget/platform code so it can be unit-tested (see test/permission_gating_test.dart).
///
/// Hard gates (block "continue" until granted): usage-access, overlay.
/// Optional (never block): exact-alarm, accessibility, battery, notifications.
/// Exact-alarm is RECOMMENDED, not required: the alarm scheduler has an
/// idle-resilient inexact fallback (setAndAllowWhileIdle), so a denied/absent
/// exact-alarm permission must not trap the user in onboarding or stop the
/// guardian from starting. A missing notification permission only weakens
/// reminders, so it does not block either.
@immutable
class PermissionGating {
  const PermissionGating._();

  /// The permissions that, while missing, block progressing past onboarding.
  static const Set<OnboardingPermission> hardGates = {
    OnboardingPermission.overlay,
    OnboardingPermission.usageAccess,
  };

  /// Whether [perm] is a hard gate.
  static bool isHardGate(OnboardingPermission perm) => hardGates.contains(perm);

  /// Read the granted state of [perm] from a native [status] snapshot.
  static bool isGranted(
    OnboardingPermission perm,
    AndroidPermissionStatus status,
  ) {
    switch (perm) {
      case OnboardingPermission.notifications:
        return status.notifications;
      case OnboardingPermission.overlay:
        return status.overlay;
      case OnboardingPermission.usageAccess:
        return status.usageAccess;
      case OnboardingPermission.exactAlarm:
        return status.exactAlarm;
      case OnboardingPermission.battery:
        return status.batteryExemption;
      case OnboardingPermission.accessibility:
        return status.accessibility;
    }
  }

  /// True when every HARD-gate permission is granted, i.e. onboarding may be
  /// considered complete and the guardian can be activated.
  static bool canFinish(AndroidPermissionStatus status) {
    return hardGates.every((p) => isGranted(p, status));
  }

  /// The hard gates that are still missing (for surfacing what's left).
  static List<OnboardingPermission> missingHardGates(
    AndroidPermissionStatus status,
  ) {
    return hardGates.where((p) => !isGranted(p, status)).toList();
  }
}
