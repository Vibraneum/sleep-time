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

    test('flags evening build-up ordering violation', () {
      // windDown before wakeUp on the same evening.
      final schedule = SleepSchedule.defaults.copyWith(
        wakeUp: const ScheduleTime(23, 0),
        windDown: const ScheduleTime(22, 0),
      );
      final result = schedule.validate();
      expect(result.ok, isFalse);
      expect(
        result.violations.any((v) => v.contains('windDown')),
        isTrue,
      );
    });

    test('flags lockdown before windDown', () {
      final schedule = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(22, 45),
      );
      final result = schedule.validate();
      expect(result.ok, isFalse);
      expect(
        result.violations.any((v) => v.contains('lockdown')),
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
