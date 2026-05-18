import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactory, databaseFactoryFfi, sqfliteFfiInit;
import 'package:window_manager/window_manager.dart';
import 'core/config.dart';
import 'platform/windows_lockdown.dart';
import 'ui/home_screen.dart';
import 'ui/setup_screen.dart';

/// Compile-time override for safe / simulate mode.
/// Pass `--dart-define=SIMULATE_LOCKDOWN=true|false` to flip it.
const String _simulateLockdownEnv =
    String.fromEnvironment('SIMULATE_LOCKDOWN', defaultValue: '');

bool _setupComplete = false;

Future<void> _loadConfig() async {
  final prefs = await SharedPreferences.getInstance();

  _setupComplete = prefs.getBool('setup_complete') ?? false;

  AppConfig.conciergeGeminiApiKey = const String.fromEnvironment(
    'CONCIERGE_GEMINI_API_KEY',
    defaultValue: '',
  );
  AppConfig.geminiApiKey = prefs.getString('gemini_api_key') ??
      const String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
  AppConfig.anthropicApiKey = prefs.getString('anthropic_api_key') ??
      const String.fromEnvironment('ANTHROPIC_API_KEY', defaultValue: '');
  AppConfig.pokeApiKey = prefs.getString('poke_api_key') ??
      const String.fromEnvironment('POKE_API_KEY', defaultValue: '');
  AppConfig.useBringYourOwnKey = prefs.getBool('use_byok') ?? true;

  AppConfig.aiProvider = AiProvider.gemini;
  final providerName = prefs.getString('ai_provider');
  for (final provider in AiProvider.values) {
    if (provider.name == providerName) {
      AppConfig.aiProvider = provider;
      break;
    }
  }

  AppConfig.geminiModel =
      prefs.getString('gemini_model') ?? 'gemini-2.5-flash';
  AppConfig.anthropicModel =
      prefs.getString('anthropic_model') ?? 'claude-haiku-4-5-20251001';

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

  AppConfig.wakeUpHour = prefs.getInt('wakeup_hour') ?? 22;
  AppConfig.wakeUpMinute = prefs.getInt('wakeup_minute') ?? 30;
  AppConfig.windDownHour = prefs.getInt('winddown_hour') ?? 23;
  AppConfig.windDownMinute = prefs.getInt('winddown_minute') ?? 0;
  AppConfig.lockdownHour = prefs.getInt('lockdown_hour') ?? 23;
  AppConfig.lockdownMinute = prefs.getInt('lockdown_minute') ?? 30;
  AppConfig.unlockHour = prefs.getInt('unlock_hour') ?? 6;
  AppConfig.unlockMinute = prefs.getInt('unlock_minute') ?? 0;

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

  await _loadConfig();
  runApp(const SleepTimeApp());
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
      home: _setupComplete ? const HomeScreen() : const SetupScreen(),
    );
  }
}
