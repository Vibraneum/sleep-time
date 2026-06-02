import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_time/core/negotiable_apps.dart';
import 'package:sleep_time/platform/windows_lock_state.dart';

/// H1 regression: the Windows `unlock_app` path must be gated on the
/// user-approved negotiable-app set exactly like Android. Before the fix it
/// resolved ANY guardian string straight to `<input>.exe` via
/// [WindowsAppResolver.resolve] and freed it with no approval gate.
///
/// The screen's `_onUnlockAppWindows` does:
///   1. `NegotiableAppStore.instance.resolve(identifier)` — null => NOT approved
///      => DENY (no grant). The old behavior fell back to a FULL grant, which
///      freed the WHOLE machine when the store was empty — the opposite of a
///      selective unlock (#7). It now denies with an explaining message instead.
///   2. only for an approved app, resolve its package/label to image name(s)
///      via [WindowsAppResolver.resolveAll] for the selective allow-list.
///
/// This test exercises that exact two-step chain.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NegotiableAppStore.instance.resetForTest();
  });

  group('Windows unlock_app gating', () {
    test('approved app resolves to a non-empty selective allow-list', () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store
          .add(const NegotiableApp(package: 'chrome.exe', label: 'Chrome'));

      // Step 1: gate.
      final approved = store.resolve('chrome');
      expect(approved, isNotNull);

      // Step 2: resolve to image names for the overlay allow-list.
      final allow =
          WindowsAppResolver.resolveAll([approved!.package, approved.label]);
      expect(allow, isNotEmpty);
      expect(WindowsAppResolver.isAllowed('chrome.exe', allow), isTrue);
    });

    test('unapproved app is NOT freed (no arbitrary exe in allow-list)',
        () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store
          .add(const NegotiableApp(package: 'chrome.exe', label: 'Chrome'));

      // The guardian tries to free an app the user never approved.
      final approved = store.resolve('notepad');
      expect(approved, isNull,
          reason: 'unapproved app must not pass the gate, so the Windows path '
              'DENIES (no grant) and never builds an allow-list for it');

      // Sanity: WindowsAppResolver alone WOULD have turned it into notepad.exe
      // (the very behavior the gate now prevents from reaching grantSelective).
      expect(WindowsAppResolver.resolve('notepad'), 'notepad.exe');
    });
  });
}
