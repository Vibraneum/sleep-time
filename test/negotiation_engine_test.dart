import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/config.dart';
import 'package:sleep_time/core/negotiation_engine.dart';

void main() {
  group('Negotiation parsing', () {
    test('parses grant decisions and clamps absurd minutes', () {
      final decision = parseGuardianDecision(
        'fine. but this is ridiculous.\n{"decision": "grant", "minutes": 999}',
      );

      expect(decision.granted, isTrue);
      expect(decision.minutesGranted, AppConfig.maxGrantedMinutes);
      expect(decision.message, 'fine. but this is ridiculous.');
    });

    test('parses deny decisions and strips json line', () {
      final decision = parseGuardianDecision(
        'no. go to sleep.\n{"decision": "deny"}',
      );

      expect(decision.granted, isFalse);
      expect(decision.minutesGranted, 0);
      expect(decision.message, 'no. go to sleep.');
    });

    test('falls back to plain text when no json exists', () {
      final decision = parseGuardianDecision('absolutely not.');

      expect(decision.granted, isFalse);
      expect(decision.message, 'absolutely not.');
    });
  });
}
