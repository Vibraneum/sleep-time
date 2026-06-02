import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin async wrapper over [FlutterSecureStorage] for the three guardian
/// secrets. Backed by Windows DPAPI and Android Keystore /
/// EncryptedSharedPreferences, so keys are encrypted at rest and never sit in
/// plaintext SharedPreferences or in the binary.
///
/// Every method swallows platform errors and degrades to empty / no-op,
/// matching the codebase's defensive boot style: a storage failure must never
/// crash startup or settings persistence.
class SecureKeyStore {
  SecureKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  /// Storage keys for the three secrets. Names match the legacy plaintext
  /// SharedPreferences keys so migration is a straight key-for-key move.
  static const String anthropicApiKey = 'anthropic_api_key';
  static const String geminiApiKey = 'gemini_api_key';
  static const String pokeApiKey = 'poke_api_key';

  static const List<String> allKeys = [
    anthropicApiKey,
    geminiApiKey,
    pokeApiKey,
  ];

  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      // Swallow: a failed encrypted write must not crash settings save.
    }
  }

  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // Swallow.
    }
  }

  Future<Map<String, String>> readAll() async {
    try {
      return await _storage.readAll();
    } catch (_) {
      return <String, String>{};
    }
  }
}

/// Where a key's value should come from on boot, and whether it needs to be
/// persisted into / scrubbed from elsewhere.
enum KeyImportSource {
  /// Already in secure storage — use it as-is, nothing to migrate.
  secure,

  /// Seeded from a runtime environment variable — write it to secure storage.
  env,

  /// Found in legacy plaintext SharedPreferences — write it to secure storage
  /// and remove the plaintext copy (migration).
  legacyPref,

  /// Compile-time `String.fromEnvironment` fallback — use it but do not persist
  /// (it is baked into the binary, not a user secret to migrate).
  compileTime,

  /// Nothing available anywhere — leave empty.
  none,
}

/// The resolved value for a key plus how it was sourced. [value] is always
/// trimmed; for [KeyImportSource.none] it is the empty string.
class KeyImportDecision {
  const KeyImportDecision(this.source, this.value);

  final KeyImportSource source;
  final String value;
}

/// Pure precedence resolver for a single secret on boot. Decides which source
/// wins so the side-effecting caller in `main._loadConfig` (write to secure
/// storage, scrub plaintext) stays trivial and the policy stays unit-testable.
///
/// Precedence (first non-empty wins):
///   1. existing secure-storage value -> use as-is
///   2. runtime env var -> persist to secure storage
///   3. legacy plaintext SharedPreferences -> persist + scrub
///   4. compile-time `String.fromEnvironment` -> use, don't persist
///   5. nothing -> empty
KeyImportDecision resolveKeyImport({
  String? secureValue,
  String? envValue,
  String? legacyPrefValue,
  String? compileTimeValue,
}) {
  final secure = secureValue?.trim() ?? '';
  if (secure.isNotEmpty) {
    return KeyImportDecision(KeyImportSource.secure, secure);
  }
  final env = envValue?.trim() ?? '';
  if (env.isNotEmpty) {
    return KeyImportDecision(KeyImportSource.env, env);
  }
  final legacy = legacyPrefValue?.trim() ?? '';
  if (legacy.isNotEmpty) {
    return KeyImportDecision(KeyImportSource.legacyPref, legacy);
  }
  final compile = compileTimeValue?.trim() ?? '';
  if (compile.isNotEmpty) {
    return KeyImportDecision(KeyImportSource.compileTime, compile);
  }
  return const KeyImportDecision(KeyImportSource.none, '');
}
