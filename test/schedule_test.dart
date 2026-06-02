import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/schedule.dart';

void main() {
  group('SleepSchedule.validate', () {
    test('accepts the shipped defaults', () {
      final result = SleepSchedule.defaults.validate();
      expect(result.ok, isTrue);
      expect(result.violations, isEmpty);
    });

    test('accepts the cross-midnight default window (23:30 -> 06:00)', () {
      // lockdown after midnight reaches unlock the next morning — valid.
      final result = SleepSchedule.defaults.validate();
      expect(result.ok, isTrue);
    });

    test('accepts a cross-midnight lockdown (00:30) with the default window',
        () {
      // The default-style schedule with lockdown nudged past midnight:
      // wake 22:30, wind 23:00, lockdown 00:30, unlock 06:00. The forward arc
      // wake -> wind -> lockdown -> unlock stays coherent across midnight, so
      // this MUST validate (it previously failed the non-wrap evening rule).
      final schedule = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(0, 30),
      );
      final result = schedule.validate();
      expect(result.ok, isTrue, reason: result.violations.join('; '));
    });

    test('accepts a cross-midnight windDown (00:15) on the arc', () {
      // wake 23:00, wind 00:15, lock 00:45, unlock 06:30 — a fully post-midnight
      // build-up that is still a coherent forward arc.
      final schedule = SleepSchedule(
        wakeUp: const ScheduleTime(23, 0),
        windDown: const ScheduleTime(0, 15),
        lockdown: const ScheduleTime(0, 45),
        unlock: const ScheduleTime(6, 30),
      );
      expect(schedule.validate().ok, isTrue);
    });

    test('flags an out-of-range hour', () {
      final schedule = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(24, 0),
      );
      final result = schedule.validate();
      expect(result.ok, isFalse);
      expect(
        result.violations.any((v) => v.contains('hour must be 0-23')),
        isTrue,
      );
    });

    test('flags an out-of-range minute', () {
      final schedule = SleepSchedule.defaults.copyWith(
        wakeUp: const ScheduleTime(22, 60),
      );
      final result = schedule.validate();
      expect(result.ok, isFalse);
      expect(
        result.violations.any((v) => v.contains('minute must be 0-59')),
        isTrue,
      );
    });

    test('flags an incoherent arc (windDown before wakeUp)', () {
      // wake 23:00, windDown 22:00: the forward arc wake -> wind is nearly a
      // full cycle while lock/unlock sit just after wake, so the ordering is
      // genuinely incoherent and must be rejected.
      final schedule = SleepSchedule.defaults.copyWith(
        wakeUp: const ScheduleTime(23, 0),
        windDown: const ScheduleTime(22, 0),
      );
      final result = schedule.validate();
      expect(result.ok, isFalse);
      expect(
        result.violations.any((v) => v.contains('ordering')),
        isTrue,
      );
    });

    test('flags lockdown before windDown (incoherent arc)', () {
      // lockdown 22:45 lands before windDown 23:00 on the arc — incoherent.
      final schedule = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(22, 45),
      );
      final result = schedule.validate();
      expect(result.ok, isFalse);
      expect(
        result.violations.any((v) => v.contains('ordering')),
        isTrue,
      );
    });

    test('flags unlock equal to lockdown', () {
      final schedule = SleepSchedule.defaults.copyWith(
        unlock: const ScheduleTime(23, 30),
      );
      final result = schedule.validate();
      expect(result.ok, isFalse);
    });

    test('accepts a same-evening morning unlock that does not swallow the day',
        () {
      // lock 23:30, unlock 05:00 — well before the 22:30 wake.
      final schedule = SleepSchedule.defaults.copyWith(
        unlock: const ScheduleTime(5, 0),
      );
      expect(schedule.validate().ok, isTrue);
    });
  });

  group('scheduleArcIsCoherent (shared helper)', () {
    test('same-evening default arc is coherent', () {
      expect(
        scheduleArcIsCoherent(
          wakeUpMin: 22 * 60 + 30,
          windDownMin: 23 * 60,
          lockdownMin: 23 * 60 + 30,
          unlockMin: 6 * 60,
        ),
        isTrue,
      );
    });

    test('cross-midnight lockdown arc is coherent', () {
      expect(
        scheduleArcIsCoherent(
          wakeUpMin: 22 * 60 + 30,
          windDownMin: 23 * 60,
          lockdownMin: 30, // 00:30
          unlockMin: 6 * 60,
        ),
        isTrue,
      );
    });

    test('collapsed boundaries (unlock == lockdown) are incoherent', () {
      expect(
        scheduleArcIsCoherent(
          wakeUpMin: 22 * 60 + 30,
          windDownMin: 23 * 60,
          lockdownMin: 23 * 60 + 30,
          unlockMin: 23 * 60 + 30,
        ),
        isFalse,
      );
    });

    test('scrambled order (lockdown before windDown) is incoherent', () {
      expect(
        scheduleArcIsCoherent(
          wakeUpMin: 22 * 60 + 30,
          windDownMin: 23 * 60,
          lockdownMin: 22 * 60 + 45,
          unlockMin: 6 * 60,
        ),
        isFalse,
      );
    });
  });

  group('SleepSchedule mutation + serialization', () {
    test('copyWith replaces only the named field', () {
      final next = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(23, 45),
      );
      expect(next.lockdown, const ScheduleTime(23, 45));
      expect(next.wakeUp, SleepSchedule.defaults.wakeUp);
      expect(next.windDown, SleepSchedule.defaults.windDown);
      expect(next.unlock, SleepSchedule.defaults.unlock);
    });

    test('toMap/fromMap round-trips', () {
      final original = SleepSchedule.defaults.copyWith(
        wakeUp: const ScheduleTime(21, 15),
      );
      final restored = SleepSchedule.fromMap(original.toMap());
      expect(restored, original);
    });

    test('equality and hashCode track field values', () {
      final a = SleepSchedule.defaults;
      final b = SleepSchedule.defaults.copyWith();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('ScheduleTime', () {
    test('minutesOfDay computes correctly', () {
      expect(const ScheduleTime(0, 0).minutesOfDay, 0);
      expect(const ScheduleTime(6, 0).minutesOfDay, 360);
      expect(const ScheduleTime(23, 30).minutesOfDay, 1410);
    });

    test('toMap/fromMap round-trips', () {
      const t = ScheduleTime(7, 45);
      expect(ScheduleTime.fromMap(t.toMap()), t);
    });
  });
}
