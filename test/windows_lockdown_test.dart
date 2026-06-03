import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/platform/windows_lock_state.dart';
import 'package:sleep_time/platform/windows_lockdown.dart';

void main() {
  group('WindowsLockState (de)serialization', () {
    test('round-trips a full-lock state', () {
      const state = WindowsLockState(locked: true, mode: 'full');
      final decoded = WindowsLockState.decode(state.encode());
      expect(decoded, equals(state));
      expect(decoded.locked, isTrue);
      expect(decoded.mode, 'full');
      expect(decoded.allow, isEmpty);
      expect(decoded.grantExpiryEpochMs, 0);
    });

    test('round-trips a grant state with an allow-list and expiry', () {
      const state = WindowsLockState(
        locked: true,
        mode: 'grant',
        allow: ['chrome.exe', 'Code.exe'],
        grantExpiryEpochMs: 1735689600000,
      );
      final decoded = WindowsLockState.decode(state.encode());
      expect(decoded, equals(state));
      expect(decoded.mode, 'grant');
      expect(decoded.allow, ['chrome.exe', 'Code.exe']);
      expect(decoded.grantExpiryEpochMs, 1735689600000);
    });

    test('emits the documented JSON keys', () {
      const state = WindowsLockState(
        locked: true,
        mode: 'grant',
        allow: ['chrome.exe'],
        grantExpiryEpochMs: 42,
      );
      final json = state.toJson();
      expect(json.keys,
          containsAll(['locked', 'mode', 'allow', 'grantExpiryEpochMs']));
      expect(json['locked'], true);
      expect(json['allow'], ['chrome.exe']);
    });

    test('decode tolerates missing optional fields (fail-safe defaults)', () {
      final decoded = WindowsLockState.decode('{"locked":true}');
      expect(decoded.locked, isTrue);
      expect(decoded.mode, 'full');
      expect(decoded.allow, isEmpty);
      expect(decoded.grantExpiryEpochMs, 0);
    });

    test('decode treats a missing locked field as unlocked', () {
      final decoded = WindowsLockState.decode('{}');
      expect(decoded.locked, isFalse);
    });

    test('decode drops blank / non-string allow entries', () {
      final decoded = WindowsLockState.decode(
          '{"locked":true,"allow":["chrome.exe","",123,"Code.exe"]}');
      expect(decoded.allow, ['chrome.exe', 'Code.exe']);
    });

    test('decode throws on non-object JSON', () {
      expect(() => WindowsLockState.decode('[]'), throwsFormatException);
    });
  });

  group('WindowsAppResolver friendly-name resolution', () {
    test('resolves known friendly names case-insensitively', () {
      expect(WindowsAppResolver.resolve('chrome'), 'chrome.exe');
      expect(WindowsAppResolver.resolve('Chrome'), 'chrome.exe');
      expect(WindowsAppResolver.resolve('VSCode'), 'Code.exe');
      expect(WindowsAppResolver.resolve('Visual Studio Code'), 'Code.exe');
      expect(WindowsAppResolver.resolve('spotify'), 'Spotify.exe');
    });

    test('passes through raw image names, normalizing the .exe suffix', () {
      expect(WindowsAppResolver.resolve('foo.exe'), 'foo.exe');
      expect(WindowsAppResolver.resolve('foo'), 'foo.exe');
      expect(WindowsAppResolver.resolve('Foo.EXE'), 'Foo.EXE');
    });

    test('returns null for blank input', () {
      expect(WindowsAppResolver.resolve(''), isNull);
      expect(WindowsAppResolver.resolve('   '), isNull);
    });

    test('resolveAll dedupes case-insensitively and drops blanks', () {
      final out = WindowsAppResolver.resolveAll(
          ['chrome', 'Chrome', '', 'google chrome', 'spotify']);
      expect(out, ['chrome.exe', 'Spotify.exe']);
    });
  });

  group('WindowsAppResolver allow-list matching', () {
    test('matches by case-insensitive basename', () {
      final allow = ['chrome.exe', 'Code.exe'];
      expect(WindowsAppResolver.isAllowed('chrome.exe', allow), isTrue);
      expect(WindowsAppResolver.isAllowed('CHROME.EXE', allow), isTrue);
      expect(WindowsAppResolver.isAllowed('code.exe', allow), isTrue);
      expect(WindowsAppResolver.isAllowed('spotify.exe', allow), isFalse);
    });

    test('matches a full path against a bare allow entry', () {
      final allow = ['chrome.exe'];
      expect(
        WindowsAppResolver.isAllowed(
            r'C:\Program Files\Google\Chrome\Application\chrome.exe', allow),
        isTrue,
      );
      expect(
        WindowsAppResolver.isAllowed('/usr/bin/chrome.exe', allow),
        isTrue,
      );
    });

    test('empty image or empty allow-list never matches', () {
      expect(WindowsAppResolver.isAllowed('', ['chrome.exe']), isFalse);
      expect(WindowsAppResolver.isAllowed('chrome.exe', const []), isFalse);
    });
  });

  group('app-control critical-process safelist (#7 block+minimize, never kill)',
      () {
    test('refuses core OS / session processes', () {
      expect(WindowsLockdown.isCriticalProcess('explorer'), isTrue);
      expect(WindowsLockdown.isCriticalProcess('explorer.exe'), isTrue);
      expect(WindowsLockdown.isCriticalProcess('winlogon.exe'), isTrue);
      expect(WindowsLockdown.isCriticalProcess('lsass.exe'), isTrue);
      expect(WindowsLockdown.isCriticalProcess('csrss.exe'), isTrue);
    });

    test('refuses our own enforcement processes', () {
      expect(WindowsLockdown.isCriticalProcess('sleep_time.exe'), isTrue);
      expect(
          WindowsLockdown.isCriticalProcess('sleep_time_watchdog.exe'), isTrue);
    });

    test('allows ordinary distraction apps to be minimized', () {
      expect(WindowsLockdown.isCriticalProcess('discord'), isFalse);
      expect(WindowsLockdown.isCriticalProcess('chrome'), isFalse);
      expect(WindowsLockdown.isCriticalProcess('Spotify.exe'), isFalse);
    });

    test('matching is case-insensitive on the resolved image name', () {
      expect(WindowsLockdown.isCriticalProcess('EXPLORER.EXE'), isTrue);
    });
  });
}
