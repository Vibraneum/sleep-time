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

    test('simulateLockdown defaults to true in debug builds', () {
      // Tests run under `flutter test` in debug, so the default initializer
      // should evaluate to true. This guards against accidentally flipping
      // the default and ambushing developers with a real lockdown next time
      // they `flutter run`.
      expect(AppConfig.simulateLockdown, isTrue);
    });
  });

  group('AppConfig provider/model defaults', () {
    test('defaults to Anthropic with the latest Sonnet', () {
      // The guardian relies on real tool-calling (Anthropic only), so Anthropic
      // is the default provider and the default model is the current Sonnet.
      expect(AppConfig.defaultAnthropicModel, 'claude-sonnet-4-6');
    });

    test('resolveAnthropicModel upgrades stale defaults but keeps user choices',
        () {
      // Empty / unset -> default.
      expect(AppConfig.resolveAnthropicModel(null),
          AppConfig.defaultAnthropicModel);
      expect(AppConfig.resolveAnthropicModel('  '),
          AppConfig.defaultAnthropicModel);
      // Every superseded default (incl. the old claude-3-5-sonnet) -> default.
      for (final legacy in AppConfig.legacyAnthropicModels) {
        expect(AppConfig.resolveAnthropicModel(legacy),
            AppConfig.defaultAnthropicModel,
            reason: '$legacy should upgrade');
      }
      // A deliberate user-entered model is preserved verbatim.
      expect(AppConfig.resolveAnthropicModel('claude-opus-4-8'),
          'claude-opus-4-8');
    });
  });

  group('AppConfig.resolveActiveProvider', () {
    test('saved gemini + only anthropic usable -> anthropic', () {
      expect(
        AppConfig.resolveActiveProvider(
          saved: AiProvider.gemini,
          anthropicUsable: true,
          geminiUsable: false,
        ),
        AiProvider.anthropic,
      );
    });

    test('saved anthropic + only gemini usable -> gemini', () {
      expect(
        AppConfig.resolveActiveProvider(
          saved: AiProvider.anthropic,
          anthropicUsable: false,
          geminiUsable: true,
        ),
        AiProvider.gemini,
      );
    });

    test('both usable -> keep saved', () {
      expect(
        AppConfig.resolveActiveProvider(
          saved: AiProvider.gemini,
          anthropicUsable: true,
          geminiUsable: true,
        ),
        AiProvider.gemini,
      );
      expect(
        AppConfig.resolveActiveProvider(
          saved: AiProvider.anthropic,
          anthropicUsable: true,
          geminiUsable: true,
        ),
        AiProvider.anthropic,
      );
    });

    test('neither usable -> keep saved', () {
      expect(
        AppConfig.resolveActiveProvider(
          saved: AiProvider.gemini,
          anthropicUsable: false,
          geminiUsable: false,
        ),
        AiProvider.gemini,
      );
      expect(
        AppConfig.resolveActiveProvider(
          saved: AiProvider.anthropic,
          anthropicUsable: false,
          geminiUsable: false,
        ),
        AiProvider.anthropic,
      );
    });
  });
}
