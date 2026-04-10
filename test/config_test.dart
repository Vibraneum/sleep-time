import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/config.dart';

void main() {
  group('AppConfig schedule windows', () {
    test('detects wind-down window before lockdown', () {
      expect(AppConfig.isWindDownTime(DateTime(2026, 1, 1, 23, 15)), isTrue);
      expect(AppConfig.isLockdownTime(DateTime(2026, 1, 1, 23, 15)), isFalse);
    });

    test('detects overnight lockdown window', () {
      expect(AppConfig.isLockdownTime(DateTime(2026, 1, 1, 23, 30)), isTrue);
      expect(AppConfig.isLockdownTime(DateTime(2026, 1, 2, 5, 59)), isTrue);
      expect(AppConfig.isLockdownTime(DateTime(2026, 1, 2, 6, 0)), isFalse);
    });

    test('formats times in 12-hour format', () {
      expect(AppConfig.formatTime(0, 0), '12:00 AM');
      expect(AppConfig.formatTime(12, 5), '12:05 PM');
      expect(AppConfig.formatTime(23, 0), '11:00 PM');
    });

    test('uses concierge Gemini key when BYOK is off', () {
      AppConfig.aiProvider = AiProvider.gemini;
      AppConfig.useBringYourOwnKey = false;
      AppConfig.conciergeGeminiApiKey = 'concierge';
      AppConfig.geminiApiKey = 'user';

      expect(AppConfig.activeApiKey, 'concierge');
    });

    test('clamps granted minutes to a safe range', () {
      expect(AppConfig.sanitizeGrantedMinutes(-5), 1);
      expect(AppConfig.sanitizeGrantedMinutes(5), 5);
      expect(AppConfig.sanitizeGrantedMinutes(999), 120);
    });
  });
}
