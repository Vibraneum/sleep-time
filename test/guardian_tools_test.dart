import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/config.dart';
import 'package:sleep_time/core/guardian_tools.dart';
import 'package:sleep_time/core/negotiation_engine.dart';
import 'package:sleep_time/core/schedule_guardrails.dart' show ScheduleScope;

void main() {
  group('guardianDecisionFromToolUse', () {
    test('guardian_action grant clamps absurd minutes', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'grant',
        'minutes': 999,
        'message': 'fine. but this is ridiculous.',
      });

      expect(d.action, GuardianAction.grant);
      expect(d.granted, isTrue);
      expect(d.minutesGranted, AppConfig.maxGrantedMinutes);
      expect(d.message, 'fine. but this is ridiculous.');
    });

    test('guardian_action grant defaults to 5 when minutes missing', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'grant',
        'message': 'five. go.',
      });

      expect(d.action, GuardianAction.grant);
      expect(d.minutesGranted, 5);
    });

    test('guardian_action deny keeps session open (action=deny)', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'deny',
        'message': 'no. go to sleep.',
      });

      expect(d.action, GuardianAction.deny);
      expect(d.granted, isFalse);
      expect(d.minutesGranted, 0);
      expect(d.message, 'no. go to sleep.');
    });

    test('guardian_action minimize', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'minimize',
        'message': 'fine. working.',
      });

      expect(d.action, GuardianAction.minimize);
      expect(d.message, 'fine. working.');
    });

    test('guardian_action close', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'close',
        'message': 'goodnight.',
      });

      expect(d.action, GuardianAction.close);
    });

    test('guardian_action unknown action falls back to deny', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'banana',
        'message': 'whatever.',
      });

      expect(d.action, GuardianAction.deny);
      expect(d.message, 'no.');
    });

    test('unlock_app carries identifier and clamps minutes', () {
      final d = guardianDecisionFromToolUse('unlock_app', {
        'app_identifier': 'com.example.notes',
        'minutes': 600,
        'message': 'notes only. ten max — wait, sixty.',
      });

      expect(d.action, GuardianAction.unlockApp);
      expect(d.appIdentifier, 'com.example.notes');
      expect(d.appMinutes, 60);
      expect(d.message, 'notes only. ten max — wait, sixty.');
    });

    test('unlock_app missing identifier falls back to deny', () {
      final d = guardianDecisionFromToolUse('unlock_app', {
        'minutes': 10,
        'message': 'sure.',
      });

      expect(d.action, GuardianAction.deny);
      expect(d.message, 'no.');
    });

    test('adjust_schedule carries field/hour/minute/reason', () {
      final d = guardianDecisionFromToolUse('adjust_schedule', {
        'field': 'lockdown',
        'hour': 23,
        'minute': 45,
        'scope': 'tonight',
        'reason': 'one-off deadline',
        'message': 'fifteen more minutes of runway. tonight only.',
      });

      expect(d.action, GuardianAction.adjustSchedule);
      expect(d.scheduleField, 'lockdown');
      expect(d.scheduleHour, 23);
      expect(d.scheduleMinute, 45);
      expect(d.scheduleReason, 'one-off deadline');
      expect(d.message, 'fifteen more minutes of runway. tonight only.');
    });

    test('end_session maps to unlock', () {
      final d = guardianDecisionFromToolUse('end_session', {
        'message': 'go. handle it. do not abuse this.',
      });

      expect(d.action, GuardianAction.unlock);
      expect(d.message, 'go. handle it. do not abuse this.');
    });

    test('control_app minimize maps to controlApp with the identifier', () {
      final d = guardianDecisionFromToolUse('control_app', {
        'app_identifier': 'discord',
        'action': 'minimize',
        'message': 'discord, away. you don\'t need it.',
      });

      expect(d.action, GuardianAction.controlApp);
      expect(d.controlAppIdentifier, 'discord');
      expect(d.controlAppAction, 'minimize');
      expect(d.message, 'discord, away. you don\'t need it.');
    });

    test('control_app block normalizes to minimize (block + minimize, never kill)',
        () {
      final d = guardianDecisionFromToolUse('control_app', {
        'app_identifier': 'chrome',
        'action': 'block',
        'message': 'no browsing.',
      });

      expect(d.action, GuardianAction.controlApp);
      // 'block' is normalized to 'minimize' — we NEVER kill/terminate.
      expect(d.controlAppAction, 'minimize');
    });

    test('control_app allow is preserved', () {
      final d = guardianDecisionFromToolUse('control_app', {
        'app_identifier': 'code',
        'action': 'allow',
        'message': 'fine, vscode only.',
      });

      expect(d.action, GuardianAction.controlApp);
      expect(d.controlAppAction, 'allow');
    });

    test('control_app unknown action falls back to deny', () {
      final d = guardianDecisionFromToolUse('control_app', {
        'app_identifier': 'discord',
        'action': 'nuke',
        'message': 'gone.',
      });

      expect(d.action, GuardianAction.deny);
      expect(d.message, 'no.');
    });

    test('control_app blank identifier falls back to deny', () {
      final d = guardianDecisionFromToolUse('control_app', {
        'app_identifier': '   ',
        'action': 'minimize',
        'message': 'away.',
      });

      expect(d.action, GuardianAction.deny);
    });

    test('save_memory carries type + text', () {
      final d = guardianDecisionFromToolUse('save_memory', {
        'memory_type': 'constraint',
        'text': 'works night shifts wed/thu',
        'message': 'noted.',
      });

      expect(d.action, GuardianAction.saveMemory);
      expect(d.memoryType, 'constraint');
      expect(d.memoryText, 'works night shifts wed/thu');
      expect(d.message, 'noted.');
    });

    test('save_memory blank text falls back to deny', () {
      final d = guardianDecisionFromToolUse('save_memory', {
        'memory_type': 'preference',
        'text': '   ',
        'message': 'ok.',
      });

      expect(d.action, GuardianAction.deny);
    });

    test('unknown tool falls back to deny', () {
      final d = guardianDecisionFromToolUse('teleport', {
        'message': 'beam me up.',
      });

      expect(d.action, GuardianAction.deny);
      expect(d.message, 'no.');
    });

    test('missing message falls back to deny', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'grant',
        'minutes': 5,
      });

      expect(d.action, GuardianAction.deny);
      expect(d.message, 'no.');
    });

    test('blank message falls back to deny', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'deny',
        'message': '   ',
      });

      expect(d.action, GuardianAction.deny);
      expect(d.message, 'no.');
    });
  });

  group('six-tool round-trip coverage', () {
    // Every tool the guardian can call must map to the right GuardianAction and
    // carry its payload fields. This is the canonical coverage check.
    test('guardian_action -> grant', () {
      final d = guardianDecisionFromToolUse('guardian_action', {
        'action': 'grant',
        'minutes': 10,
        'message': 'ten minutes. go.',
      });
      expect(d.action, GuardianAction.grant);
      expect(d.minutesGranted, 10);
    });

    test('unlock_app -> unlockApp', () {
      final d = guardianDecisionFromToolUse('unlock_app', {
        'app_identifier': 'com.example.notes',
        'minutes': 15,
        'message': 'notes only.',
      });
      expect(d.action, GuardianAction.unlockApp);
      expect(d.appIdentifier, 'com.example.notes');
      expect(d.appMinutes, 15);
    });

    test('adjust_schedule -> adjustSchedule', () {
      final d = guardianDecisionFromToolUse('adjust_schedule', {
        'field': 'lockdown',
        'hour': 23,
        'minute': 45,
        'scope': 'permanent',
        'reason': 'new work schedule',
        'message': 'moved.',
      });
      expect(d.action, GuardianAction.adjustSchedule);
      expect(d.scheduleField, 'lockdown');
      expect(d.scheduleHour, 23);
      expect(d.scheduleMinute, 45);
      expect(d.scheduleScope, ScheduleScope.permanent);
      expect(d.scheduleReason, 'new work schedule');
    });

    test('control_app -> controlApp', () {
      final d = guardianDecisionFromToolUse('control_app', {
        'app_identifier': 'discord',
        'action': 'minimize',
        'message': 'away.',
      });
      expect(d.action, GuardianAction.controlApp);
      expect(d.controlAppIdentifier, 'discord');
      expect(d.controlAppAction, 'minimize');
    });

    test('save_memory -> saveMemory', () {
      final d = guardianDecisionFromToolUse('save_memory', {
        'memory_type': 'goal',
        'text': 'finishing a thesis',
        'message': 'got it.',
      });
      expect(d.action, GuardianAction.saveMemory);
      expect(d.memoryType, 'goal');
      expect(d.memoryText, 'finishing a thesis');
    });

    test('end_session -> unlock', () {
      final d = guardianDecisionFromToolUse('end_session', {
        'message': 'go.',
      });
      expect(d.action, GuardianAction.unlock);
    });
  });

  group('extractPartialJsonStringField', () {
    test('complete value', () {
      expect(
        extractPartialJsonStringField('{"message":"hello there"}', 'message'),
        'hello there',
      );
    });

    test('value still arriving (no closing quote yet)', () {
      expect(
        extractPartialJsonStringField('{"message":"hello the', 'message'),
        'hello the',
      );
    });

    test('partial mid-stream right after opening quote', () {
      expect(
        extractPartialJsonStringField('{"message":"', 'message'),
        '',
      );
    });

    test('key present but colon/value not yet -> null', () {
      expect(
        extractPartialJsonStringField('{"message"', 'message'),
        isNull,
      );
      expect(
        extractPartialJsonStringField('{"message":', 'message'),
        isNull,
      );
    });

    test('key not present yet -> null', () {
      expect(
        extractPartialJsonStringField('{"action":"deny"', 'message'),
        isNull,
      );
      expect(
        extractPartialJsonStringField('{', 'message'),
        isNull,
      );
      expect(
        extractPartialJsonStringField('', 'message'),
        isNull,
      );
    });

    test('escaped quote inside the value does not terminate early', () {
      expect(
        extractPartialJsonStringField(
            r'{"message":"she said \"no\" firmly"}', 'message'),
        'she said "no" firmly',
      );
    });

    test('escaped quote mid-stream (still open)', () {
      expect(
        extractPartialJsonStringField(
            r'{"message":"she said \"no', 'message'),
        'she said "no',
      );
    });

    test('newline / tab / backslash escapes are unescaped', () {
      expect(
        extractPartialJsonStringField(
            r'{"message":"line1\nline2\ttab\\end"}', 'message'),
        'line1\nline2\ttab\\end',
      );
    });

    test('message key after other keys', () {
      expect(
        extractPartialJsonStringField(
          '{"action":"grant","minutes":10,"message":"fine. ten."}',
          'message',
        ),
        'fine. ten.',
      );
    });

    test('message key after other keys, still arriving', () {
      expect(
        extractPartialJsonStringField(
          '{"action":"grant","minutes":10,"message":"fine. te',
          'message',
        ),
        'fine. te',
      );
    });

    test('trailing lone backslash (escape payload not yet streamed) is dropped',
        () {
      expect(
        extractPartialJsonStringField(r'{"message":"almost\', 'message'),
        'almost',
      );
    });

    test('partial \\u escape not yet complete is dropped', () {
      expect(
        extractPartialJsonStringField(r'{"message":"snow \u26', 'message'),
        'snow ',
      );
    });

    test('complete \\u escape is decoded', () {
      expect(
        extractPartialJsonStringField(r'{"message":"ABC"}', 'message'),
        'ABC',
      );
    });

    test('extracts a different field by name', () {
      expect(
        extractPartialJsonStringField(
            '{"reason":"deadline","message":"ok"}', 'reason'),
        'deadline',
      );
    });
  });

  group('Gemini legacy parser', () {
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
  });

  group('cleanGeminiResponse strips leaked action labels (#2)', () {
    test('strips a bare "deny request" line', () {
      final cleaned = cleanGeminiResponse('no. go to sleep.\ndeny request');
      expect(cleaned, 'no. go to sleep.');
    });

    test('strips a bare standalone decision word', () {
      final cleaned = cleanGeminiResponse('not happening.\ndeny');
      expect(cleaned, 'not happening.');
    });

    test('strips a "Decision: deny" label line', () {
      final cleaned = cleanGeminiResponse('morning you will thank me.\nDecision: deny');
      expect(cleaned, 'morning you will thank me.');
    });

    test('strips a markdown "**Action:** grant" label line', () {
      final cleaned =
          cleanGeminiResponse('fine. five minutes.\n**Action:** grant');
      expect(cleaned, 'fine. five minutes.');
    });

    test('strips "outcome = lock"', () {
      final cleaned = cleanGeminiResponse('locking it down.\noutcome = lock');
      expect(cleaned, 'locking it down.');
    });

    test('keeps legitimate prose that merely mentions a word', () {
      // A sentence that contains "deny" mid-line is NOT a bare label and stays.
      final cleaned =
          cleanGeminiResponse("i'm not going to deny you forever, but no.");
      expect(cleaned, "i'm not going to deny you forever, but no.");
    });

    test('collapses to "no." when only a label remains', () {
      final cleaned = cleanGeminiResponse('deny request');
      expect(cleaned, 'no.');
    });
  });
}
