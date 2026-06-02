import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/secure_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureKeyStore round-trip', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('write -> read returns the stored value', () async {
      final store = SecureKeyStore();
      await store.write(SecureKeyStore.anthropicApiKey, 'sk-ant-123');
      expect(await store.read(SecureKeyStore.anthropicApiKey), 'sk-ant-123');
    });

    test('read of an unset key returns null', () async {
      final store = SecureKeyStore();
      expect(await store.read(SecureKeyStore.geminiApiKey), isNull);
    });

    test('delete removes the value', () async {
      final store = SecureKeyStore();
      await store.write(SecureKeyStore.pokeApiKey, 'poke-xyz');
      await store.delete(SecureKeyStore.pokeApiKey);
      expect(await store.read(SecureKeyStore.pokeApiKey), isNull);
    });

    test('readAll returns every stored secret', () async {
      final store = SecureKeyStore();
      await store.write(SecureKeyStore.anthropicApiKey, 'a');
      await store.write(SecureKeyStore.geminiApiKey, 'g');
      await store.write(SecureKeyStore.pokeApiKey, 'p');

      final all = await store.readAll();
      expect(all[SecureKeyStore.anthropicApiKey], 'a');
      expect(all[SecureKeyStore.geminiApiKey], 'g');
      expect(all[SecureKeyStore.pokeApiKey], 'p');
    });
  });

  group('resolveKeyImport precedence', () {
    test('secure storage wins over everything', () {
      final d = resolveKeyImport(
        secureValue: 'secure',
        envValue: 'env',
        legacyPrefValue: 'legacy',
        compileTimeValue: 'compile',
      );
      expect(d.source, KeyImportSource.secure);
      expect(d.value, 'secure');
    });

    test('env wins when secure is empty', () {
      final d = resolveKeyImport(
        secureValue: '',
        envValue: 'env',
        legacyPrefValue: 'legacy',
        compileTimeValue: 'compile',
      );
      expect(d.source, KeyImportSource.env);
      expect(d.value, 'env');
    });

    test('legacy pref wins when secure + env are empty', () {
      final d = resolveKeyImport(
        secureValue: null,
        envValue: null,
        legacyPrefValue: 'legacy',
        compileTimeValue: 'compile',
      );
      expect(d.source, KeyImportSource.legacyPref);
      expect(d.value, 'legacy');
    });

    test('compile-time is the last resort', () {
      final d = resolveKeyImport(
        secureValue: '',
        envValue: '  ',
        legacyPrefValue: null,
        compileTimeValue: 'compile',
      );
      expect(d.source, KeyImportSource.compileTime);
      expect(d.value, 'compile');
    });

    test('none when nothing is available', () {
      final d = resolveKeyImport(
        secureValue: null,
        envValue: null,
        legacyPrefValue: null,
        compileTimeValue: null,
      );
      expect(d.source, KeyImportSource.none);
      expect(d.value, '');
    });

    test('values are trimmed', () {
      final d = resolveKeyImport(secureValue: '  trimmed  ');
      expect(d.value, 'trimmed');
    });
  });
}
