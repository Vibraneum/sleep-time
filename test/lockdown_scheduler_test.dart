import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_time/core/lockdown_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
