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
  /// Ordering rules use **wrap-aware (cross-midnight) math**. The evening
  /// build-up — wakeUp -> windDown -> lockdown — is expected to run in the
  /// same evening, so we require those three to be non-decreasing in
  /// minutes-of-day (e.g. 22:30 <= 23:00 <= 23:30).
  ///
  /// The lockdown -> unlock window legitimately crosses midnight (lockdown
  /// 23:30, unlock 06:00). Because unlock is the *morning* end of the window,
  /// it is NOT required to be numerically after lockdown. We only flag a
  /// genuinely contradictory case: unlock landing back inside the evening
  /// build-up (i.e. unlock at or after wakeUp on the same clock), which would
  /// mean the lockdown window swallows the whole evening and never reaches a
  /// distinct morning. Anything that resolves to a sane "lock tonight, unlock
  /// tomorrow morning" window is accepted.
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
    if (violations.isEmpty) {
      final wake = wakeUp.minutesOfDay;
      final wind = windDown.minutesOfDay;
      final lock = lockdown.minutesOfDay;
      final unlockM = unlock.minutesOfDay;

      // Evening build-up must be non-decreasing within the same evening.
      if (wind < wake) {
        violations.add('windDown must be at or after wakeUp');
      }
      if (lock < wind) {
        violations.add('lockdown must be at or after windDown');
      }

      // Wrap-aware lockdown -> unlock check. Measure the length of the
      // lockdown window walking forward (mod 24h). A zero-length window
      // (unlock == lockdown) is contradictory; a window long enough to wrap
      // back past wakeUp would swallow the evening entirely.
      const dayMinutes = 24 * 60;
      final lockWindow = (unlockM - lock + dayMinutes) % dayMinutes;
      if (lockWindow == 0) {
        violations.add('unlock must differ from lockdown');
      } else {
        // Distance from lockdown forward to wakeUp (the start of the next
        // evening build-up). If the lockdown window is longer than that, the
        // window has wrapped past the next wake time — contradictory.
        final lockToWake = (wake - lock + dayMinutes) % dayMinutes;
        if (lockToWake != 0 && lockWindow > lockToWake) {
          violations.add('unlock falls after the next wakeUp; '
              'the lockdown window swallows the evening');
        }
      }
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
