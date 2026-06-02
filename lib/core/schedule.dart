// Immutable schedule value objects — the single source of truth for the
// app's bedtime schedule. Pure Dart, no platform calls, heavily unit-tested.

/// A single time-of-day point (hour + minute) in 24h form.
class ScheduleTime {
  final int hour;
  final int minute;

  const ScheduleTime(this.hour, this.minute);

  /// Minutes since midnight (0..1439 when valid).
  int get minutesOfDay => (hour * 60) + minute;

  bool get isValid =>
      hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;

  Map<String, dynamic> toMap() => {'hour': hour, 'minute': minute};

  factory ScheduleTime.fromMap(Map<String, dynamic> map) => ScheduleTime(
        (map['hour'] as num?)?.toInt() ?? 0,
        (map['minute'] as num?)?.toInt() ?? 0,
      );

  ScheduleTime copyWith({int? hour, int? minute}) =>
      ScheduleTime(hour ?? this.hour, minute ?? this.minute);

  @override
  bool operator ==(Object other) =>
      other is ScheduleTime &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() =>
      'ScheduleTime(${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')})';
}

/// Result of validating a [SleepSchedule].
class ScheduleValidation {
  final bool ok;
  final List<String> violations;

  const ScheduleValidation({required this.ok, required this.violations});
}

/// Shared, wrap-aware ordering check for a four-point schedule.
///
/// A coherent night progresses wakeUp -> windDown -> lockdown -> unlock as a
/// single forward arc around the 24h circle, with the whole arc fitting inside
/// one cycle (so it loops back to wakeUp without any boundary overtaking the
/// next). This makes BOTH same-evening schedules (22:30/23:00/23:30/06:00) and
/// cross-midnight ones (22:30/23:00/00:30/06:00) coherent, while genuinely
/// scrambled orderings stay incoherent.
///
/// This is the single source of truth for ordering: [SleepSchedule.validate]
/// and `ScheduleGuardrails._orderingOk` both call it so the two can never
/// disagree about whether an ordering is sane. Range validity (0-23h/0-59m) is
/// the caller's responsibility; this only looks at relative ordering.
bool scheduleArcIsCoherent({
  required int wakeUpMin,
  required int windDownMin,
  required int lockdownMin,
  required int unlockMin,
}) {
  const dayMinutes = 24 * 60;
  int forward(int to) => (to - wakeUpMin + dayMinutes) % dayMinutes;
  // Forward distances from wakeUp to each subsequent boundary.
  final toWind = forward(windDownMin);
  final toLock = forward(lockdownMin);
  final toUnlock = forward(unlockMin);
  // A zero gap means a boundary collides with wakeUp; reject. Then require the
  // arc to be strictly increasing and to close within one cycle.
  if (toWind == 0 || toLock == 0 || toUnlock == 0) return false;
  return toWind < toLock && toLock < toUnlock;
}

/// The full nightly schedule: when the guardian wakes, when to wind down,
/// when lockdown begins, and when it lifts.
class SleepSchedule {
  final ScheduleTime wakeUp;
  final ScheduleTime windDown;
  final ScheduleTime lockdown;
  final ScheduleTime unlock;

  const SleepSchedule({
    required this.wakeUp,
    required this.windDown,
    required this.lockdown,
    required this.unlock,
  });

  /// The shipped defaults: guardian wakes 10:30 PM, wind down 11:00 PM,
  /// lockdown 11:30 PM, unlock 6:00 AM.
  static const SleepSchedule defaults = SleepSchedule(
    wakeUp: ScheduleTime(22, 30),
    windDown: ScheduleTime(23, 0),
    lockdown: ScheduleTime(23, 30),
    unlock: ScheduleTime(6, 0),
  );

  SleepSchedule copyWith({
    ScheduleTime? wakeUp,
    ScheduleTime? windDown,
    ScheduleTime? lockdown,
    ScheduleTime? unlock,
  }) =>
      SleepSchedule(
        wakeUp: wakeUp ?? this.wakeUp,
        windDown: windDown ?? this.windDown,
        lockdown: lockdown ?? this.lockdown,
        unlock: unlock ?? this.unlock,
      );

  Map<String, dynamic> toMap() => {
        'wakeUp': wakeUp.toMap(),
        'windDown': windDown.toMap(),
        'lockdown': lockdown.toMap(),
        'unlock': unlock.toMap(),
      };

  factory SleepSchedule.fromMap(Map<String, dynamic> map) => SleepSchedule(
        wakeUp: ScheduleTime.fromMap(
            (map['wakeUp'] as Map?)?.cast<String, dynamic>() ?? const {}),
        windDown: ScheduleTime.fromMap(
            (map['windDown'] as Map?)?.cast<String, dynamic>() ?? const {}),
        lockdown: ScheduleTime.fromMap(
            (map['lockdown'] as Map?)?.cast<String, dynamic>() ?? const {}),
        unlock: ScheduleTime.fromMap(
            (map['unlock'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );

  /// Validate the schedule.
  ///
  /// Range rules: every time must be a real wall-clock time (0-23h / 0-59m).
  ///
  /// Ordering rules use **wrap-aware (cross-midnight) math** via the shared
  /// [scheduleArcIsCoherent] helper. The night is treated as one forward arc
  /// wakeUp -> windDown -> lockdown -> unlock around the 24h circle, so both a
  /// same-evening schedule (22:30/23:00/23:30/06:00) and a cross-midnight one
  /// (22:30/23:00/00:30/06:00) are accepted, while genuinely scrambled
  /// orderings (e.g. windDown before wakeUp, lockdown before windDown, or
  /// unlock collapsing onto lockdown) are rejected. The guardrails use the same
  /// helper so the human Settings path and the AI path never disagree.
  ScheduleValidation validate() {
    final violations = <String>[];

    void checkRange(String label, ScheduleTime t) {
      if (t.hour < 0 || t.hour > 23) {
        violations.add('$label hour must be 0-23 (got ${t.hour})');
      }
      if (t.minute < 0 || t.minute > 59) {
        violations.add('$label minute must be 0-59 (got ${t.minute})');
      }
    }

    checkRange('wakeUp', wakeUp);
    checkRange('windDown', windDown);
    checkRange('lockdown', lockdown);
    checkRange('unlock', unlock);

    // Only evaluate ordering when every time is in range; otherwise
    // minutesOfDay math is meaningless.
    if (violations.isEmpty &&
        !scheduleArcIsCoherent(
          wakeUpMin: wakeUp.minutesOfDay,
          windDownMin: windDown.minutesOfDay,
          lockdownMin: lockdown.minutesOfDay,
          unlockMin: unlock.minutesOfDay,
        )) {
      violations.add('schedule ordering must progress wakeUp -> windDown -> '
          'lockdown -> unlock around the clock');
    }

    return ScheduleValidation(ok: violations.isEmpty, violations: violations);
  }

  @override
  bool operator ==(Object other) =>
      other is SleepSchedule &&
      other.wakeUp == wakeUp &&
      other.windDown == windDown &&
      other.lockdown == lockdown &&
      other.unlock == unlock;

  @override
  int get hashCode => Object.hash(wakeUp, windDown, lockdown, unlock);

  @override
  String toString() =>
      'SleepSchedule(wakeUp: $wakeUp, windDown: $windDown, '
      'lockdown: $lockdown, unlock: $unlock)';
}
