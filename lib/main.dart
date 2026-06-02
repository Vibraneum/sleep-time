import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactory, databaseFactoryFfi, sqfliteFfiInit;
import 'package:window_manager/window_manager.dart';
import 'core/config.dart';
import 'core/schedule_store.dart';
import 'core/secure_key_store.dart';
import 'core/negotiable_apps.dart';
import 'core/permission_gating.dart';
import 'platform/android_lockdown.dart';
import 'platform/windows_lockdown.dart';
import 'ui/home_screen.dart';
import 'ui/setup_screen.dart';
import 'ui/permissions_onboarding_screen.dart';

/// Compile-time override for safe / simulate mode.
/// Pass `--dart-define=SIMULATE_LOCKDOWN=true|false` to flip it.
const String _simulateLockdownEnv =
    String.fromEnvironment('SIMULATE_LOCKDOWN', defaultValue: '');

/// Compile-time API-key fallbacks (lowest precedence). Kept so a build can bake
/// in a key via `--dart-define`; they are used but never persisted to secure
/// storage (they live in the binary, not as a user secret to migrate).
const String _geminiKeyCompileTime =
    String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
const String _anthropicKeyCompileTime =
    String.fromEnvironment('ANTHROPIC_API_KEY', defaultValue: '');
const String _pokeKeyCompileTime =
    String.fromEnvironment('POKE_API_KEY', defaultValue: '');

bool _setupComplete = false;

/// On Android, true when setup is done but the required (hard-gate) permissions
/// for the background guardian are not yet granted, so we route through the
/// onboarding screen before treating the guardian as active.
bool _needsAndroidOnboarding = false;

Future<void> _loadConfig({SecureKeyStore? secureKeyStore}) async {
  final prefs = await SharedPreferences.getInstance();
  final secureStore = secureKeyStore ?? SecureKeyStore();

  _setupComplete = prefs.getBool('setup_complete') ?? false;

  AppConfig.conciergeGeminiApiKey = const String.fromEnvironment(
    'CONCIERGE_GEMINI_API_KEY',
    defaultValue: '',
  );

  // Load the three secrets from encrypted-at-rest storage, with a one-time
  // import + migration: env var (runtime) > legacy plaintext prefs > compile
  // time. Anything imported from env or legacy prefs is persisted to secure
  // storage; legacy plaintext copies are then scrubbed from SharedPreferences
  // so the key never lingers in plaintext.
  AppConfig.geminiApiKey = await _importSecret(
    store: secureStore,
    prefs: prefs,
    key: SecureKeyStore.geminiApiKey,
    envName: 'GEMINI_API_KEY',
    compileTimeValue: _geminiKeyCompileTime,
  );
  var anthropicFromEnv = false;
  AppConfig.anthropicApiKey = await _importSecret(
    store: secureStore,
    prefs: prefs,
    key: SecureKeyStore.anthropicApiKey,
    envName: 'ANTHROPIC_API_KEY',
    compileTimeValue: _anthropicKeyCompileTime,
    onSource: (source) => anthropicFromEnv = source == KeyImportSource.env,
  );
  AppConfig.pokeApiKey = await _importSecret(
    store: secureStore,
    prefs: prefs,
    key: SecureKeyStore.pokeApiKey,
    envName: 'POKE_API_KEY',
    compileTimeValue: _pokeKeyCompileTime,
  );
  AppConfig.useBringYourOwnKey = prefs.getBool('use_byok') ?? true;

  AppConfig.aiProvider = AiProvider.anthropic;
  final providerName = prefs.getString('ai_provider');
  for (final provider in AiProvider.values) {
    if (provider.name == providerName) {
      AppConfig.aiProvider = provider;
      break;
    }
  }

  // Never run a provider that has no key when the other one is usable, and
  // honor a freshly-seeded Anthropic key over a stale saved preference. This
  // guards against the real failure mode where a saved `ai_provider == gemini`
  // ran the Gemini text-parser path even though only an Anthropic key was
  // present — the model emitted tool-calls as text that never executed.
  final savedProvider = AppConfig.aiProvider;
  final anthropicUsable = AppConfig.anthropicApiKey.trim().isNotEmpty;
  final geminiUsable = AppConfig.effectiveGeminiApiKey.trim().isNotEmpty;

  // Rule A (intent): an Anthropic key arriving via the env seed path, or an
  // Anthropic key present while the saved provider can't run, means the user
  // wants Anthropic.
  final savedProviderUsable = savedProvider == AiProvider.anthropic
      ? anthropicUsable
      : geminiUsable;
  if (anthropicUsable && (anthropicFromEnv || !savedProviderUsable)) {
    AppConfig.aiProvider = AiProvider.anthropic;
  } else {
    // Rule B (general safety): if the active provider has no key but the other
    // one does, switch to whichever has a key.
    AppConfig.aiProvider = AppConfig.resolveActiveProvider(
      saved: savedProvider,
      anthropicUsable: anthropicUsable,
      geminiUsable: geminiUsable,
    );
  }

  if (AppConfig.aiProvider != savedProvider) {
    await prefs.setString('ai_provider', AppConfig.aiProvider.name);
  }

  AppConfig.geminiModel =
      prefs.getString('gemini_model') ?? 'gemini-2.5-flash';
  // Upgrade a stale saved Anthropic model (e.g. an old claude-3-5-sonnet) to the
  // current default, and persist the upgrade so it sticks.
  final resolvedAnthropicModel =
      AppConfig.resolveAnthropicModel(prefs.getString('anthropic_model'));
  AppConfig.anthropicModel = resolvedAnthropicModel;
  if (prefs.getString('anthropic_model') != resolvedAnthropicModel) {
    await prefs.setString('anthropic_model', resolvedAnthropicModel);
  }

  AppConfig.safeWord = prefs.getString('safe_word') ?? 'dontdie';

  // Resolution order for simulate-lockdown:
  //   1. compile-time --dart-define=SIMULATE_LOCKDOWN=...
  //   2. previously-saved user preference
  //   3. debug builds default to ON, release builds default to OFF
  final envSim = _simulateLockdownEnv.toLowerCase();
  if (envSim == 'true' || envSim == '1') {
    AppConfig.simulateLockdown = true;
  } else if (envSim == 'false' || envSim == '0') {
    AppConfig.simulateLockdown = false;
  } else {
    AppConfig.simulateLockdown =
        prefs.getBool('simulate_lockdown') ?? kDebugMode;
  }

  // Schedule now lives in ScheduleStore (loaded in main() before runApp).

  // Auto-complete setup if key already available
  if (AppConfig.hasUsableAiKey && !_setupComplete) {
    _setupComplete = true;
    await prefs.setBool('setup_complete', true);
  }

  // Off by default — opt in from Settings to launch with Windows.
  AppConfig.runAtStartup = prefs.getBool('run_at_startup') ?? false;
  if (_setupComplete &&
      AppConfig.runAtStartup &&
      !AppConfig.simulateLockdown) {
    unawaited(WindowsLockdown.registerStartup());
  }
}

/// Resolve one secret on boot from secure storage, importing + migrating from
/// the lower-precedence sources as needed. Returns the resolved value (trimmed,
/// empty if nothing is available) and performs the side effects:
///   - env / legacy-pref imports are written into [store] (encrypted at rest)
///   - a legacy plaintext copy in [prefs] is removed after migration
/// Compile-time values are used but never persisted.
Future<String> _importSecret({
  required SecureKeyStore store,
  required SharedPreferences prefs,
  required String key,
  required String envName,
  required String compileTimeValue,
  void Function(KeyImportSource source)? onSource,
}) async {
  final decision = resolveKeyImport(
    secureValue: await store.read(key),
    envValue: Platform.environment[envName],
    legacyPrefValue: prefs.getString(key),
    compileTimeValue: compileTimeValue,
  );

  onSource?.call(decision.source);

  switch (decision.source) {
    case KeyImportSource.env:
      await store.write(key, decision.value);
      break;
    case KeyImportSource.legacyPref:
      await store.write(key, decision.value);
      await prefs.remove(key);
      break;
    case KeyImportSource.secure:
    case KeyImportSource.compileTime:
    case KeyImportSource.none:
      break;
  }

  return decision.value;
}

Future<void> _initWindowManager() async {
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(420, 740),
    minimumSize: Size(420, 680),
    center: true,
    title: 'Sleep Time',
    skipTaskbar: false,
  );

  // waitUntilReadyToShow ensures the window exists before we touch it —
  // critical when launched from the Windows startup registry where the
  // compositor may not be fully ready.
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  if (Platform.isWindows) {
    await _initWindowManager();
  }

  // Clean up any leftover lockdown state from a previous crash.
  await WindowsLockdown.restoreSystemState();

  await ScheduleStore.instance.loadFromPrefs();
  await _loadConfig();
  await NegotiableAppStore.instance.load();
  await _initAndroidGuardian();
  runApp(const SleepTimeApp());
}

/// On Android, hand the bedtime schedule to the native background guardian and
/// start it once setup is complete and we are not in safe/simulate mode. The
/// native service is the background backstop (alarms + persistent notification);
/// the in-app Dart scheduler still drives the foreground UI. We also re-push the
/// schedule to native whenever the in-app schedule changes.
///
/// Everything here is guarded so it is a no-op off-Android, before setup, in
/// safe mode, and when the native plugin is missing.
Future<void> _initAndroidGuardian() async {
  if (!Platform.isAndroid) return;

  // Keep native alarms in sync with in-app schedule edits. The native side
  // re-reads FlutterSharedPreferences, so we must wait for ScheduleStore's
  // persistence to land BEFORE signalling the recompute — otherwise native
  // reschedules off the OLD schedule (#9).
  ScheduleStore.instance.addListener(() {
    unawaited(ScheduleStore.instance.persistenceSettled
        .then((_) => AndroidLockdown.setSchedule()));
  });

  if (!_setupComplete || AppConfig.simulateLockdown) return;

  // The guardian is only meaningfully "active" once the required permissions
  // (overlay + usage access + exact alarm) are granted. If they are missing,
  // route the user through onboarding first instead of silently starting a
  // guardian that cannot enforce.
  final status = await AndroidLockdown.getPermissionStatus();
  if (!PermissionGating.canFinish(status)) {
    _needsAndroidOnboarding = true;
    return;
  }

  unawaited(() async {
    await AndroidLockdown.startGuardian();
    await AndroidLockdown.setSchedule();
  }());
}

class SleepTimeApp extends StatelessWidget {
  const SleepTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sleep Time',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF0F4FA),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B5FEF),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: !_setupComplete
          ? const SetupScreen()
          : _needsAndroidOnboarding
              ? const _AndroidOnboardingGate()
              : const HomeScreen(),
    );
  }
}

/// First-run gate: shows the permission onboarding, then activates the native
/// guardian and replaces itself with the home screen once the required
/// permissions are satisfied.
class _AndroidOnboardingGate extends StatelessWidget {
  const _AndroidOnboardingGate();

  @override
  Widget build(BuildContext context) {
    return PermissionsOnboardingScreen(
      onComplete: () {
        _needsAndroidOnboarding = false;
        unawaited(() async {
          await AndroidLockdown.startGuardian();
          await AndroidLockdown.setSchedule();
        }());
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (_) => false,
        );
      },
    );
  }
}
