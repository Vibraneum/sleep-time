import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_time/core/negotiable_apps.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NegotiableAppStore.instance.resetForTest();
  });

  group('NegotiableAppStore persistence', () {
    test('add persists and survives a reload', () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store.add(
          const NegotiableApp(package: 'com.example.chat', label: 'Chat'));

      // Fresh in-memory view, same backing prefs.
      store.resetForTest();
      await store.load();

      expect(store.isApproved('com.example.chat'), isTrue);
      expect(store.apps.single.label, 'Chat');
    });

    test('remove persists', () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store.add(
          const NegotiableApp(package: 'com.example.a', label: 'A'));
      await store.remove('com.example.a');

      store.resetForTest();
      await store.load();
      expect(store.isApproved('com.example.a'), isFalse);
    });

    test('add replaces a duplicate package rather than duplicating', () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store
          .add(const NegotiableApp(package: 'com.x', label: 'Old label'));
      await store
          .add(const NegotiableApp(package: 'com.x', label: 'New label'));
      expect(store.apps.length, 1);
      expect(store.apps.single.label, 'New label');
    });
  });

  group('NegotiableAppStore.resolve (friendly-label → package)', () {
    test('resolves exact package', () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store.add(const NegotiableApp(
          package: 'com.google.android.youtube', label: 'YouTube'));
      final r = store.resolve('com.google.android.youtube');
      expect(r?.package, 'com.google.android.youtube');
    });

    test('resolves case-insensitive label', () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store.add(const NegotiableApp(
          package: 'com.google.android.youtube', label: 'YouTube'));
      expect(store.resolve('youtube')?.package,
          'com.google.android.youtube');
      expect(store.resolve('YOUTUBE')?.package,
          'com.google.android.youtube');
    });

    test('resolves loose contains match', () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store.add(const NegotiableApp(
          package: 'com.whatsapp', label: 'WhatsApp Messenger'));
      expect(store.resolve('whatsapp')?.package, 'com.whatsapp');
    });

    test('returns null for an unapproved app (unlock_app is constrained)',
        () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      await store
          .add(const NegotiableApp(package: 'com.whatsapp', label: 'WhatsApp'));
      // A different app the guardian might try to free must not resolve.
      expect(store.resolve('com.instagram.android'), isNull);
      expect(store.resolve('Instagram'), isNull);
    });

    test('empty identifier resolves to null', () async {
      final store = NegotiableAppStore.instance;
      await store.load();
      expect(store.resolve(''), isNull);
      expect(store.resolve('   '), isNull);
    });
  });
}
