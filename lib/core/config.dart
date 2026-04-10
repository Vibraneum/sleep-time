enum AiProvider { gemini, anthropic }

/// App configuration — schedule, providers, keys, and state helpers.
class AppConfig {
  static String conciergeGeminiApiKey = '';
  static String geminiApiKey = '';
  static String anthropicApiKey = '';
  static String pokeApiKey = '';
  static AiProvider aiProvider = AiProvider.gemini;
  static bool useBringYourOwnKey = false;
  static String geminiModel = 'gemini-3-flash-preview';
  static String anthropicModel = 'claude-haiku-4-5-20251001';
  static bool simulateLockdown = false;

  // Schedule — all configurable
  static int wakeUpHour = 22; // 10:30 PM — guardian wakes up
  static int wakeUpMinute = 30;
  static int windDownHour = 23; // 11:00 PM — "start wrapping up"
  static int windDownMinute = 0;
  static int lockdownHour = 23; // 11:30 PM — lockdown
  static int lockdownMinute = 30;
  static int unlockHour = 6; // 6:00 AM — free
  static int unlockMinute = 0;

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
    if (simulateLockdown) return true;
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
