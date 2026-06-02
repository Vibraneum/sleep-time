import 'package:flutter/foundation.dart';

import 'schedule_store.dart';

enum AiProvider { gemini, anthropic }

/// App configuration — schedule, providers, keys, and state helpers.
class AppConfig {
  static String conciergeGeminiApiKey = '';
  static String geminiApiKey = '';
  static String anthropicApiKey = '';
  static String pokeApiKey = '';
  static AiProvider aiProvider = AiProvider.gemini;
  static bool useBringYourOwnKey = false;
  static String geminiModel = 'gemini-2.5-flash';
  static String anthropicModel = 'claude-sonnet-4-5';
  static String safeWord = 'dontdie';

  /// Off by default. The previous default of `true` silently registered the
  /// app to launch with Windows the first time it ran — invasive for anyone
  /// just trying the app out. Users can opt in from Settings.
  static bool runAtStartup = false;

  /// When true, all platform lockdown side effects (full-screen, always-on-top,
  /// refocus loops, registry writes, Android device-admin / kiosk calls) are
  /// short-circuited. The UI still simulates the locked / granted / unlocked
  /// states so you can exercise the flow safely.
  ///
  /// Defaults to `true` in debug builds so running `flutter run` on your dev
  /// machine cannot accidentally lock you out. Release builds default to
  /// `false`. Both can be overridden by the user (Settings) or at compile
  /// time via `--dart-define=SIMULATE_LOCKDOWN=true|false`.
  static bool simulateLockdown = kDebugMode;

  // Schedule — single source of truth lives in ScheduleStore. These getters
  // delegate so every existing reader keeps working unchanged.
  static int get wakeUpHour => ScheduleStore.instance.current.wakeUp.hour;
  static int get wakeUpMinute => ScheduleStore.instance.current.wakeUp.minute;
  static int get windDownHour => ScheduleStore.instance.current.windDown.hour;
  static int get windDownMinute =>
      ScheduleStore.instance.current.windDown.minute;
  static int get lockdownHour => ScheduleStore.instance.current.lockdown.hour;
  static int get lockdownMinute =>
      ScheduleStore.instance.current.lockdown.minute;
  static int get unlockHour => ScheduleStore.instance.current.unlock.hour;
  static int get unlockMinute => ScheduleStore.instance.current.unlock.minute;

  static const int minGrantedMinutes = 1;
  static const int maxGrantedMinutes = 120;

  static const String agentAutonomyNote =
      'You have full autonomy over granting or denying time. '
      'There are no hard limits. Use your judgment based on the reason, '
      'the time of night, and the user\'s history.';

  static int _minutesOfDay(int hour, int minute) => (hour * 60) + minute;

  static bool _isWithinWindow({
    required int startMinutes,
    required int endMinutes,
    required int currentMinutes,
  }) {
    if (startMinutes == endMinutes) return true;
    if (startMinutes < endMinutes) {
      return currentMinutes >= startMinutes && currentMinutes < endMinutes;
    }
    return currentMinutes >= startMinutes || currentMinutes < endMinutes;
  }

  static String get effectiveGeminiApiKey =>
      useBringYourOwnKey ? geminiApiKey : conciergeGeminiApiKey;

  static String get activeApiKey {
    switch (aiProvider) {
      case AiProvider.gemini:
        return effectiveGeminiApiKey;
      case AiProvider.anthropic:
        return anthropicApiKey;
    }
  }

  static String get activeModel {
    switch (aiProvider) {
      case AiProvider.gemini:
        return geminiModel;
      case AiProvider.anthropic:
        return anthropicModel;
    }
  }

  static String get providerLabel {
    switch (aiProvider) {
      case AiProvider.gemini:
        return 'Gemini';
      case AiProvider.anthropic:
        return 'Anthropic';
    }
  }

  static bool get hasUsableAiKey => activeApiKey.trim().isNotEmpty;

  static int sanitizeGrantedMinutes(int minutes) {
    return minutes.clamp(minGrantedMinutes, maxGrantedMinutes);
  }

  static bool isLockdownTime([DateTime? now]) {
    final time = now ?? DateTime.now();
    return _isWithinWindow(
      startMinutes: _minutesOfDay(lockdownHour, lockdownMinute),
      endMinutes: _minutesOfDay(unlockHour, unlockMinute),
      currentMinutes: _minutesOfDay(time.hour, time.minute),
    );
  }

  static bool isWindDownTime([DateTime? now]) {
    final time = now ?? DateTime.now();
    return _isWithinWindow(
      startMinutes: _minutesOfDay(windDownHour, windDownMinute),
      endMinutes: _minutesOfDay(lockdownHour, lockdownMinute),
      currentMinutes: _minutesOfDay(time.hour, time.minute),
    );
  }

  static bool isAwakeTime([DateTime? now]) {
    final time = now ?? DateTime.now();
    return _isWithinWindow(
      startMinutes: _minutesOfDay(wakeUpHour, wakeUpMinute),
      endMinutes: _minutesOfDay(unlockHour, unlockMinute),
      currentMinutes: _minutesOfDay(time.hour, time.minute),
    );
  }

  static DateTime lockdownStartForDate(DateTime time) {
    final candidate = DateTime(
      time.year,
      time.month,
      time.day,
      lockdownHour,
      lockdownMinute,
    );
    if (!candidate.isAfter(time)) {
      return candidate;
    }
    final previous = time.subtract(const Duration(days: 1));
    return DateTime(
      previous.year,
      previous.month,
      previous.day,
      lockdownHour,
      lockdownMinute,
    );
  }

  static String formatTime(int hour, int minute) {
    final h = hour % 24;
    final period = h >= 12 ? 'PM' : 'AM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${minute.toString().padLeft(2, '0')} $period';
  }

  static String formatDateTimeWithZone(DateTime time) {
    final date =
        '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
    final clock = formatTime(time.hour, time.minute);
    final offset = time.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final absOffset = offset.abs();
    final offsetText =
        '$sign${absOffset.inHours.toString().padLeft(2, '0')}:${(absOffset.inMinutes % 60).toString().padLeft(2, '0')}';
    return '$date $clock ${time.timeZoneName} (UTC$offsetText)';
  }
}
