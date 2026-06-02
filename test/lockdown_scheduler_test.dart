import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_time/core/lockdown_scheduler.dart';
import 'package:sleep_time/core/schedule.dart';
import 'package:sleep_time/core/schedule_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ScheduleStore.resetForTest();
  });

  LockdownScheduler makeScheduler({
    void Function(LockdownState)? onState,
    void Function(List<String>, int)? onSelective,
  }) {
    return LockdownScheduler(
      onStateChange: onState ?? (_) {},
      onSelectiveGrant: onSelective,
    );
  }

  group('grantSelective', () {
    test('enters granted with allow-list + expiry and is selective', () {
      final scheduler = makeScheduler();
      scheduler.grantSelective(allow: ['chrome.exe'], minutes: 20);

      expect(scheduler.state, LockdownState.granted);
      expect(scheduler.isSelectiveGrant, isTrue);
      expect(scheduler.grantAllow, ['chrome.exe']);
      expect(scheduler.grantExpiry, isNotNull);
      expect(scheduler.grantsUsedTonight, 1);
      scheduler.dispose();
    });

    test('does NOT permanently unlock (overlay stays armed)', () {
      final scheduler = makeScheduler();
      scheduler.grantSelective(allow: ['chrome.exe'], minutes: 20);
      expect(scheduler.permanentlyUnlocked, isFalse);
      scheduler.dispose();
    });

    test('fires onSelectiveGrant with resolved allow-list + sanitized minutes',
        () {
      List<String>? gotAllow;
      int? gotMinutes;
      final scheduler = makeScheduler(
        onSelective: (allow, minutes) {
          gotAllow = allow;
          gotMinutes = minutes;
        },
      );
      // 999 should clamp to the configured max.
      scheduler.grantSelective(allow: ['Code.exe'], minutes: 999);
      expect(gotAllow, ['Code.exe']);
      expect(gotMinutes, 120); // AppConfig.maxGrantedMinutes
      scheduler.dispose();
    });
  });

  group('full grant still behaves as before', () {
    test('grantExtension enters granted with no allow-list (not selective)', () {
      final scheduler = makeScheduler();
      scheduler.grantExtension(15);

      expect(scheduler.state, LockdownState.granted);
      expect(scheduler.isSelectiveGrant, isFalse);
      expect(scheduler.grantAllow, isEmpty);
      expect(scheduler.grantExpiry, isNotNull);
      expect(scheduler.permanentlyUnlocked, isFalse);
      scheduler.dispose();
    });

    test('grantExtension after a selective grant clears the allow-list', () {
      final scheduler = makeScheduler();
      scheduler.grantSelective(allow: ['chrome.exe'], minutes: 10);
      expect(scheduler.isSelectiveGrant, isTrue);

      scheduler.grantExtension(10);
      expect(scheduler.isSelectiveGrant, isFalse);
      expect(scheduler.grantAllow, isEmpty);
      scheduler.dispose();
    });
  });

  group('M4: revert reentrancy guard', () {
    test('a ScheduleStore notify during _updateState does not recurse', () {
      // start() subscribes _onScheduleChanged -> _updateState to the store.
      // revertTonightNudges() calls notifyListeners() synchronously, which
      // re-enters _updateState through that subscription. The reentrancy guard
      // must drop the nested call so this completes without a stack overflow.
      final scheduler = makeScheduler();
      scheduler.start();

      // Seed a tonight nudge so revertTonightNudges() actually mutates + notifies.
      ScheduleStore.instance.apply(
        SleepSchedule.defaults.copyWith(lockdown: const ScheduleTime(23, 45)),
        source: ScheduleSource.aiTonight,
      );

      // This notifies listeners; the guard prevents the nested _updateState
      // from recursing. No exception / overflow == pass.
      expect(ScheduleStore.instance.revertTonightNudges, returnsNormally);
      expect(ScheduleStore.instance.current, SleepSchedule.defaults);

      scheduler.stop();
      scheduler.dispose();
    });
  });

  group('fullUnlock', () {
    test('permanently unlocks and clears any selective allow-list', () {
      final scheduler = makeScheduler();
      scheduler.grantSelective(allow: ['chrome.exe'], minutes: 10);
      scheduler.fullUnlock();

      expect(scheduler.permanentlyUnlocked, isTrue);
      expect(scheduler.state, LockdownState.unlocked);
      expect(scheduler.grantAllow, isEmpty);
      expect(scheduler.grantExpiry, isNull);
      scheduler.dispose();
    });
  });
}
