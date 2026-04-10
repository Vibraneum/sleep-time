import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';
import 'core/config.dart';
import 'platform/windows_lockdown.dart';
import 'ui/home_screen.dart';
import 'ui/setup_screen.dart';

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
      prefs.getString('gemini_model') ?? 'gemini-3-flash-preview';
  AppConfig.anthropicModel =
      prefs.getString('anthropic_model') ?? 'claude-haiku-4-5-20251001';

  AppConfig.simulateLockdown = const bool.fromEnvironment(
    'SIMULATE_LOCKDOWN',
    defaultValue: false,
  );

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
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize sqflite FFI for Windows/Linux desktop
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await WindowsLockdown.restoreSystemState();
    await windowManager.setTitle('Sleep Time');
    await windowManager.setMinimumSize(const Size(420, 680));
    await windowManager.setSize(const Size(420, 740));
    await windowManager.center();
  }

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
