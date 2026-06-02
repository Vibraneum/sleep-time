import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/config.dart';
import 'package:sleep_time/core/guardian_tools.dart';

// The legacy text parser moved to guardian_tools.dart and was renamed
// parseGeminiDecision/cleanGeminiResponse. These assertions migrated from the
// original negotiation_engine_test.dart so the Gemini fallback stays covered
// regardless of which file a reader opens. The Anthropic tool-use path and the
// request body shape are covered in guardian_tools_test.dart and
// anthropic_request_test.dart.

void main() {
  group('Negotiation parsing (Gemini legacy fallback)', () {
    test('parses grant decisions and clamps absurd minutes', () {
      final decision = parseGeminiDecision(
        'fine. but this is ridiculous.\n{"decision": "grant", "minutes": 999}',
      );

      expect(decision.granted, isTrue);
      expect(decision.minutesGranted, AppConfig.maxGrantedMinutes);
      expect(decision.message, 'fine. but this is ridiculous.');
    });

    test('parses deny decisions and strips json line', () {
      final decision = parseGeminiDecision(
        'no. go to sleep.\n{"decision": "deny"}',
      );

      expect(decision.granted, isFalse);
      expect(decision.minutesGranted, 0);
      expect(decision.message, 'no. go to sleep.');
    });

    test('falls back to plain text when no json exists', () {
      final decision = parseGeminiDecision('absolutely not.');

      expect(decision.granted, isFalse);
      expect(decision.message, 'absolutely not.');
    });

    test('cleanGeminiResponse strips the decision line', () {
      final cleaned = cleanGeminiResponse(
        'ten minutes.\n{"decision": "grant", "minutes": 10}',
      );
      expect(cleaned, 'ten minutes.');
    });
  });
}
