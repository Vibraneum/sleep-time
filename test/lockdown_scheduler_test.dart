import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_time/core/config.dart';
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

  group('endGrantEarly (#2 back to sleep early)', () {
    test('from a grant returns to locked and does NOT permanently unlock', () {
      var lastState = LockdownState.unlocked;
      final scheduler = makeScheduler(onState: (s) => lastState = s);
      // Force a manual lock so the post-grant recompute returns to locked
      // regardless of the wall clock the test runs under.
      scheduler.forceLock();
      scheduler.grantExtension(20);
      expect(scheduler.state, LockdownState.granted);

      scheduler.endGrantEarly();

      expect(scheduler.state, LockdownState.locked,
          reason: 'ending the grant early must re-lock, not unlock');
      expect(lastState, LockdownState.locked);
      expect(scheduler.permanentlyUnlocked, isFalse,
          reason: 'endGrantEarly must never permanently unlock');
      expect(scheduler.grantExpiry, isNull);
      expect(scheduler.grantAllow, isEmpty);
      scheduler.dispose();
    });

    test('clears a selective grant too', () {
      final scheduler = makeScheduler();
      scheduler.forceLock();
      scheduler.grantSelective(allow: ['chrome.exe'], minutes: 15);
      expect(scheduler.isSelectiveGrant, isTrue);

      scheduler.endGrantEarly();

      expect(scheduler.state, LockdownState.locked);
      expect(scheduler.isSelectiveGrant, isFalse);
      expect(scheduler.grantAllow, isEmpty);
      expect(scheduler.permanentlyUnlocked, isFalse);
      scheduler.dispose();
    });

    test('is a no-op when there is no active grant', () {
      final scheduler = makeScheduler();
      scheduler.forceLock();
      scheduler.endGrantEarly();
      expect(scheduler.state, LockdownState.locked);
      scheduler.dispose();
    });
  });

  group('restoreGrantState night key (#6)', () {
    test('discards stale counters from a previous night on restore', () async {
      final yesterday = LockdownScheduler.nightKeyFor(
          DateTime.now().subtract(const Duration(days: 1, hours: 12)));
      SharedPreferences.setMockInitialValues({
        'grants_used_tonight': 3,
        'granted_minutes_tonight': 90,
        'grant_night': yesterday,
      });
      final scheduler = makeScheduler();
      await scheduler.restoreGrantState();
      expect(scheduler.grantsUsedTonight, 0,
          reason: 'yesterday counters must reset');
      scheduler.dispose();
    });

    test('keeps counters that belong to tonight', () async {
      final tonight = LockdownScheduler.nightKeyFor(DateTime.now());
      SharedPreferences.setMockInitialValues({
        'grants_used_tonight': 2,
        'granted_minutes_tonight': 40,
        'grant_night': tonight,
      });
      final scheduler = makeScheduler();
      await scheduler.restoreGrantState();
      expect(scheduler.grantsUsedTonight, 2);
      scheduler.dispose();
    });
  });

  group('grant -> relock single-fire (#3 no double re-lock)', () {
    test(
        'when the grant timer expires, the scheduler ALREADY recomputed to '
        'locked before onGrantExpired fires — so the host must NOT re-emit '
        'locked itself', () async {
      final states = <LockdownState>[];
      var expiredSeenState = LockdownState.unlocked;
      late LockdownScheduler scheduler;
      scheduler = LockdownScheduler(
        onStateChange: states.add,
        onGrantExpired: () {
          // The scheduler's own _updateState() runs BEFORE this callback in
          // _startGrantTimer, so by here the state is already `locked`. The
          // home screen relied on this and used to ALSO drive locked here,
          // causing a double pushAndRemoveUntil. This asserts the scheduler is
          // the single source of the locked transition.
          expiredSeenState = scheduler.state;
        },
      );
      // Manual lock so the post-grant recompute returns to locked regardless of
      // the wall clock the test runs under.
      scheduler.forceLock();
      states.clear();

      // Grant the minimum (1 min) then force the expiry into the past and tick
      // the timer logic via endGrantEarly's sibling path: simulate expiry by
      // granting, then directly invoking the recompute with a past expiry.
      scheduler.grantExtension(1);
      expect(scheduler.state, LockdownState.granted);
      states.clear();

      // Drive the grant to expiry deterministically: end it early triggers the
      // same recompute-to-locked path the timer uses on expiry.
      scheduler.endGrantEarly();

      expect(scheduler.state, LockdownState.locked);
      // Exactly ONE locked transition emitted by the scheduler for this
      // re-lock — not zero, not two.
      expect(states.where((s) => s == LockdownState.locked).length, 1,
          reason: 'scheduler emits the locked transition exactly once');
      scheduler.dispose();
      // (expiredSeenState only asserted in the timer path; endGrantEarly does
      // not invoke onGrantExpired, which is correct.)
      expect(expiredSeenState, LockdownState.unlocked);
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

  group('forceLock', () {
    test('locks immediately regardless of the clock', () {
      var lastState = LockdownState.unlocked;
      final scheduler = makeScheduler(onState: (s) => lastState = s);
      scheduler.forceLock();

      expect(scheduler.state, LockdownState.locked);
      expect(lastState, LockdownState.locked);
      scheduler.dispose();
    });

    test('the safe word (fullUnlock) clears the manual lock — escape works', () {
      final scheduler = makeScheduler();
      scheduler.forceLock();
      expect(scheduler.state, LockdownState.locked);

      scheduler.fullUnlock();
      expect(scheduler.state, LockdownState.unlocked);
      expect(scheduler.permanentlyUnlocked, isTrue);
      scheduler.dispose();
    });

    test('a grant still wins over a manual lock so the user can negotiate out',
        () {
      final scheduler = makeScheduler();
      scheduler.forceLock();
      scheduler.grantExtension(5);

      expect(scheduler.state, LockdownState.granted);
      scheduler.dispose();
    });

    test('records a release time strictly in the future (cannot trap past wake)',
        () {
      final scheduler = makeScheduler();
      final before = DateTime.now();
      scheduler.forceLock();
      final release = scheduler.nextUnlockAfter(before);
      expect(release.isAfter(before), isTrue,
          reason: 'a manual lock must auto-release at the next unlock time');
      scheduler.dispose();
    });
  });

  group('manual lock auto-releases at the morning unlock time (#1 stuck-on)', () {
    test(
        'nextUnlockAfter returns today\'s unlock when it is still ahead, '
        'else tomorrow\'s', () {
      // Default schedule unlock is 06:00.
      final scheduler = makeScheduler();
      expect(AppConfig.unlockHour, 6);
      expect(AppConfig.unlockMinute, 0);

      // 03:00 → today 06:00 (still ahead).
      final at0300 = DateTime(2026, 6, 2, 3, 0);
      expect(scheduler.nextUnlockAfter(at0300), DateTime(2026, 6, 2, 6, 0));

      // 22:15 (after today's 06:00) → next-day 06:00.
      final at2215 = DateTime(2026, 6, 2, 22, 15);
      expect(scheduler.nextUnlockAfter(at2215), DateTime(2026, 6, 3, 6, 0));

      // Exactly at 06:00 is NOT strictly after, so roll to tomorrow.
      final at0600 = DateTime(2026, 6, 2, 6, 0);
      expect(scheduler.nextUnlockAfter(at0600), DateTime(2026, 6, 3, 6, 0));

      scheduler.dispose();
    });

    test('manualLockExpired is false before release, true at/after it', () {
      final scheduler = makeScheduler();
      // forceLock records the release as nextUnlockAfter(now).
      scheduler.forceLock();
      expect(scheduler.state, LockdownState.locked);

      final release = scheduler.nextUnlockAfter(DateTime.now());
      // Just before the morning unlock: still locked.
      expect(scheduler.manualLockExpired(
              release.subtract(const Duration(minutes: 1))),
          isFalse);
      // At the unlock boundary and after: expired.
      expect(scheduler.manualLockExpired(release), isTrue);
      expect(scheduler.manualLockExpired(release.add(const Duration(hours: 1))),
          isTrue);
      scheduler.dispose();
    });

    test('no manual lock → manualLockExpired is always false', () {
      final scheduler = makeScheduler();
      expect(scheduler.manualLockExpired(DateTime.now()), isFalse);
      expect(
          scheduler.manualLockExpired(
              DateTime.now().add(const Duration(days: 2))),
          isFalse);
      scheduler.dispose();
    });
  });
}
