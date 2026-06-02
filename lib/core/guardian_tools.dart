import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'negotiation_engine.dart' show GuardianAction, GuardianDecision;

/// The Anthropic Messages tool-use toolset for the guardian, plus strict
/// mapping from a tool_use block to a [GuardianDecision].
///
/// The guardian emits EXACTLY ONE tool call per turn (tool_choice: any +
/// disable_parallel_tool_use). The `message` field on each tool is the ONLY
/// text shown to the user — the model never writes prose outside a tool call.
class GuardianTools {
  GuardianTools._();

  /// guardian_action — the everyday decision. `deny` doubles as
  /// "keep talking / no decision yet".
  static const Map<String, dynamic> guardianAction = {
    'name': 'guardian_action',
    'description':
        'Grant, deny, minimize, or close. Use "deny" to keep talking without '
        'ending the negotiation. "grant" frees the whole machine for N minutes.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['grant', 'deny', 'minimize', 'close'],
        },
        'minutes': {
          'type': 'integer',
          'description': 'Minutes to grant. Required only when action=="grant".',
          'minimum': 1,
          'maximum': 120,
        },
        'message': {
          'type': 'string',
          'description': 'The user-facing reply. This is the ONLY text the '
              'user sees.',
        },
      },
      'required': ['action', 'message'],
    },
  };

  /// unlock_app — free a single app for N minutes (selective unlock).
  static const Map<String, dynamic> unlockApp = {
    'name': 'unlock_app',
    'description':
        'Free a single named app for N minutes without lifting the whole '
        'lockdown.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'app_identifier': {
          'type': 'string',
          'description': 'Platform identifier of the app to unlock.',
        },
        'minutes': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 60,
        },
        'message': {
          'type': 'string',
          'description': 'The user-facing reply. The ONLY text the user sees.',
        },
      },
      'required': ['app_identifier', 'minutes', 'message'],
    },
  };

  /// adjust_schedule — move bedtime/wake. Data only in M1; application + the
  /// guardrails land in M3.
  static const Map<String, dynamic> adjustSchedule = {
    'name': 'adjust_schedule',
    'description':
        'Move a schedule boundary (wind down, lockdown, unlock, wake up) for '
        'tonight or permanently.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'field': {
          'type': 'string',
          'enum': ['windDown', 'lockdown', 'unlock', 'wakeUp'],
        },
        'hour': {
          'type': 'integer',
          'minimum': 0,
          'maximum': 23,
        },
        'minute': {
          'type': 'integer',
          'minimum': 0,
          'maximum': 59,
        },
        'scope': {
          'type': 'string',
          'enum': ['tonight', 'permanent'],
        },
        'reason': {
          'type': 'string',
          'description': 'Why the change is justified.',
        },
        'message': {
          'type': 'string',
          'description': 'The user-facing reply. The ONLY text the user sees.',
        },
      },
      'required': ['field', 'hour', 'minute', 'scope', 'reason', 'message'],
    },
  };

  /// end_session — the deliberate, rare full-night release.
  static const Map<String, dynamic> endSession = {
    'name': 'end_session',
    'description':
        'Lift the lockdown fully for the rest of the night. Rare — only for '
        'genuine emergencies or fully earned trust.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'message': {
          'type': 'string',
          'description': 'The user-facing reply. The ONLY text the user sees.',
        },
      },
      'required': ['message'],
    },
  };

  /// The 4-tool set in stable order. The LAST tool carries the cache_control
  /// breakpoint (added by the request builder, not here).
  static const List<Map<String, dynamic>> all = [
    guardianAction,
    unlockApp,
    adjustSchedule,
    endSession,
  ];
}

/// Safe fallback used whenever a tool call is malformed, unknown, or missing
/// its required user-facing `message`. The guardian can never produce a blank
/// bubble or silently fall through to [GuardianAction.none].
GuardianDecision _denyFallback() =>
    GuardianDecision(message: 'no.', action: GuardianAction.deny);

/// Strict mapping from a tool_use block to a [GuardianDecision]. Unknown tools
/// or a missing `message` collapse to the deny fallback.
GuardianDecision guardianDecisionFromToolUse(
  String toolName,
  Map<String, dynamic> input,
) {
  final message = input['message'];
  if (message is! String || message.trim().isEmpty) {
    return _denyFallback();
  }

  switch (toolName) {
    case 'guardian_action':
      final action = (input['action'] as String?)?.toLowerCase();
      switch (action) {
        case 'grant':
          final minutes = AppConfig.sanitizeGrantedMinutes(
            (input['minutes'] as num?)?.toInt() ?? 5,
          );
          return GuardianDecision(
            message: message,
            action: GuardianAction.grant,
            minutesGranted: minutes,
          );
        case 'deny':
          return GuardianDecision(
            message: message,
            action: GuardianAction.deny,
          );
        case 'minimize':
          return GuardianDecision(
            message: message,
            action: GuardianAction.minimize,
          );
        case 'close':
          return GuardianDecision(
            message: message,
            action: GuardianAction.close,
          );
        default:
          return _denyFallback();
      }
    case 'unlock_app':
      final identifier = input['app_identifier'];
      if (identifier is! String || identifier.trim().isEmpty) {
        return _denyFallback();
      }
      final minutes = ((input['minutes'] as num?)?.toInt() ?? 5).clamp(1, 60);
      return GuardianDecision(
        message: message,
        action: GuardianAction.unlockApp,
        appIdentifier: identifier,
        appMinutes: minutes,
      );
    case 'adjust_schedule':
      final field = input['field'];
      if (field is! String || field.trim().isEmpty) {
        return _denyFallback();
      }
      final hour = (input['hour'] as num?)?.toInt();
      final minute = (input['minute'] as num?)?.toInt();
      return GuardianDecision(
        message: message,
        action: GuardianAction.adjustSchedule,
        scheduleField: field,
        scheduleHour: hour,
        scheduleMinute: minute,
        scheduleReason: input['reason'] as String?,
      );
    case 'end_session':
      return GuardianDecision(
        message: message,
        action: GuardianAction.unlock,
      );
    default:
      return _denyFallback();
  }
}

/// Production entry point for the legacy Gemini text parser. Delegates to the
/// test-visible [parseGeminiDecision]; exists so the engine's quarantined
/// Gemini path can call the parser without tripping invalid_use_of
/// _visible_for_testing_member.
GuardianDecision geminiDecisionFromText(String response) =>
    parseGeminiDecision(response);

/// Legacy Gemini text parser — the model returns a JSON object on the LAST
/// line. Quarantined fallback: the pinned `google_generative_ai` package can't
/// do typed tool use. Moved here from negotiation_engine.dart and renamed.
@visibleForTesting
GuardianDecision parseGeminiDecision(String response) {
  for (final line in response.trim().split('\n').reversed) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) continue;
    try {
      final json = jsonDecode(trimmed) as Map<String, dynamic>;
      final decision = (json['decision'] as String?)?.toLowerCase();
      if (decision == 'grant') {
        final minutes = AppConfig.sanitizeGrantedMinutes(
          (json['minutes'] as num?)?.toInt() ?? 5,
        );
        return GuardianDecision(
          message: cleanGeminiResponse(response),
          action: GuardianAction.grant,
          minutesGranted: minutes,
        );
      }
      if (decision == 'deny' || decision == 'lock') {
        return GuardianDecision(
          message: cleanGeminiResponse(response),
          action: GuardianAction.deny,
        );
      }
      if (decision == 'minimize') {
        return GuardianDecision(
          message: cleanGeminiResponse(response),
          action: GuardianAction.minimize,
        );
      }
      if (decision == 'close' || decision == 'exit') {
        return GuardianDecision(
          message: cleanGeminiResponse(response),
          action: GuardianAction.close,
        );
      }
      if (decision == 'unlock') {
        return GuardianDecision(
          message: cleanGeminiResponse(response),
          action: GuardianAction.unlock,
        );
      }
    } catch (_) {
      continue;
    }
  }
  return GuardianDecision(message: cleanGeminiResponse(response));
}

@visibleForTesting
String cleanGeminiResponse(String response) {
  final cleaned = response
      .trim()
      .split('\n')
      .where((line) {
        final trimmed = line.trim();
        return !(trimmed.startsWith('{') && trimmed.contains('"decision"'));
      })
      .join('\n')
      .trim();
  return cleaned.isEmpty ? 'no.' : cleaned;
}
