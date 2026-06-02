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

    test('C1: aiTonight cross-midnight lockdown (23:30 -> 00:30) is granted',
        () {
      // Baseline lockdown 23:30 (the shipped default). An AI tonight nudge to
      // 00:30 crosses midnight; with the wrap-aware validate() this MUST be
      // granted and persisted to current (it was silently rejected before the
      // C1a fix, while the engine still claimed success).
      final store = ScheduleStore.instance;
      final next = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(0, 30),
      );
      final result = store.apply(next, source: ScheduleSource.aiTonight);

      expect(result.granted, isTrue, reason: result.reasons.join('; '));
      expect(store.current.lockdown, const ScheduleTime(0, 30));
      // aiTonight does not move the baseline.
      expect(store.baseline.lockdown, const ScheduleTime(23, 30));
    });

    test('C1: a genuinely incoherent apply is rejected and leaves current',
        () {
      final store = ScheduleStore.instance;
      // lockdown 22:45 lands before windDown 23:00 on the arc — incoherent.
      final bad = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(22, 45),
      );
      final result = store.apply(bad, source: ScheduleSource.aiTonight);

      expect(result.granted, isFalse);
      expect(result.outcome, ScheduleOutcome.rejected);
      expect(store.current, SleepSchedule.defaults);
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

    test('sets lastChangeSource and lastChangeNote on apply', () {
      final store = ScheduleStore.instance;
      final next = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(23, 45),
      );
      store.apply(next,
          source: ScheduleSource.aiTonight, reason: 'one-off deadline');
      expect(store.lastChangeSource, ScheduleSource.aiTonight);
      expect(store.lastChangeNote, 'one-off deadline');
    });

    test('clearLastChangeNotice resets the banner notice', () {
      final store = ScheduleStore.instance;
      store.apply(
        SleepSchedule.defaults.copyWith(lockdown: const ScheduleTime(23, 45)),
        source: ScheduleSource.aiTonight,
        reason: 'x',
      );
      store.clearLastChangeNotice();
      expect(store.lastChangeSource, isNull);
      expect(store.lastChangeNote, isNull);
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

  group('ScheduleStore.revertTonightNudges', () {
    test('restores baseline for aiTonight-changed fields', () {
      final store = ScheduleStore.instance;
      store.apply(
        SleepSchedule.defaults.copyWith(lockdown: const ScheduleTime(23, 45)),
        source: ScheduleSource.aiTonight,
        reason: 'tonight nudge',
      );
      expect(store.current.lockdown, const ScheduleTime(23, 45));
      expect(store.tonightNudgedFields, contains('lockdown'));

      store.revertTonightNudges();

      expect(store.current.lockdown, SleepSchedule.defaults.lockdown);
      expect(store.current, SleepSchedule.defaults);
      expect(store.tonightNudgedFields, isEmpty);
      expect(store.lastChangeSource, ScheduleSource.system);
    });

    test('leaves aiPermanent changes intact (those moved the baseline)', () {
      final store = ScheduleStore.instance;
      final permanent = SleepSchedule.defaults.copyWith(
        lockdown: const ScheduleTime(23, 45),
      );
      store.apply(permanent, source: ScheduleSource.aiPermanent);
      expect(store.baseline, permanent);

      store.revertTonightNudges();

      // No tonight nudges to revert; the permanent change stays.
      expect(store.current, permanent);
      expect(store.baseline, permanent);
    });

    test('leaves userSettings changes intact', () {
      final store = ScheduleStore.instance;
      final human = SleepSchedule.defaults.copyWith(
        unlock: const ScheduleTime(7, 0),
      );
      store.apply(human, source: ScheduleSource.userSettings);

      store.revertTonightNudges();

      expect(store.current, human);
      expect(store.baseline, human);
    });

    test('reverts only the nudged field, preserving an earlier permanent change',
        () {
      final store = ScheduleStore.instance;
      // Permanent unlock change moves the baseline.
      final permanent = SleepSchedule.defaults.copyWith(
        unlock: const ScheduleTime(7, 0),
      );
      store.apply(permanent, source: ScheduleSource.aiPermanent);
      // Tonight nudge to lockdown only.
      store.apply(
        permanent.copyWith(lockdown: const ScheduleTime(23, 50)),
        source: ScheduleSource.aiTonight,
      );

      store.revertTonightNudges();

      // lockdown reverts to baseline (23:30), but the permanent 07:00 unlock
      // survives because it's part of the baseline now.
      expect(store.current.lockdown, SleepSchedule.defaults.lockdown);
      expect(store.current.unlock, const ScheduleTime(7, 0));
    });

    test('no-op when nothing was nudged', () {
      final store = ScheduleStore.instance;
      var notified = 0;
      store.addListener(() => notified++);
      store.revertTonightNudges();
      expect(notified, 0);
    });
  });
}
