import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_time/core/schedule.dart';
import 'package:sleep_time/core/schedule_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ScheduleStore.resetForTest();
  });

  group('ScheduleStore.apply', () {
    test('returns defaults before loadFromPrefs without crashing', () {
      expect(ScheduleStore.instance.current, SleepSchedule.defaults);
      expect(ScheduleStore.instance.baseline, SleepSchedule.defaults);
    });

    test('grants a valid change, updates current and notifies', () {
      final store = ScheduleStore.instance;
      var notified = 0;
      store.addListener(() => notified++);

      final next = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(23, 45),
      );
      final result = store.apply(next, source: ScheduleSource.userSettings);

      expect(result.granted, isTrue);
      expect(result.outcome, ScheduleOutcome.granted);
      expect(store.current, next);
      expect(notified, 1);
    });

    test('moves the baseline for userSettings source', () {
      final store = ScheduleStore.instance;
      final next = SleepSchedule.defaults.copyWith(
        unlock: const ScheduleTime(7, 0),
      );
      store.apply(next, source: ScheduleSource.userSettings);
      expect(store.baseline, next);
    });

    test('does NOT move the baseline for aiTonight source', () {
      final store = ScheduleStore.instance;
      final next = SleepSchedule.defaults.copyWith(
        unlock: const ScheduleTime(7, 0),
      );
      store.apply(next, source: ScheduleSource.aiTonight);
      expect(store.current, next);
      expect(store.baseline, SleepSchedule.defaults);
    });

    test('rejects an invalid change without mutating or notifying', () {
      final store = ScheduleStore.instance;
      var notified = 0;
      store.addListener(() => notified++);

      final bad = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(24, 0),
      );
      final result = store.apply(bad, source: ScheduleSource.userSettings);

      expect(result.granted, isFalse);
      expect(result.outcome, ScheduleOutcome.rejected);
      expect(result.reasons, isNotEmpty);
      expect(store.current, SleepSchedule.defaults);
      expect(notified, 0);
    });

    test('loadFromPrefs reads existing pref keys into current and baseline',
        () async {
      SharedPreferences.setMockInitialValues({
        'wakeup_hour': 21,
        'wakeup_minute': 15,
        'winddown_hour': 22,
        'winddown_minute': 0,
        'lockdown_hour': 22,
        'lockdown_minute': 30,
        'unlock_hour': 5,
        'unlock_minute': 30,
      });
      ScheduleStore.resetForTest();

      await ScheduleStore.instance.loadFromPrefs();
      final s = ScheduleStore.instance.current;
      expect(s.wakeUp, const ScheduleTime(21, 15));
      expect(s.lockdown, const ScheduleTime(22, 30));
      expect(s.unlock, const ScheduleTime(5, 30));
      expect(ScheduleStore.instance.baseline, s);
    });
  });
}
