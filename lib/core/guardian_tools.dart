import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'negotiation_engine.dart' show GuardianAction, GuardianDecision;
import 'schedule_guardrails.dart' show ScheduleGuardrails, ScheduleScope;

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

  /// control_app — block + MINIMIZE (or re-allow) a distraction. NEVER kills or
  /// terminates a process (the user must not lose unsaved work). The platform
  /// layer minimizes non-allowed windows and reclaims foreground.
  static const Map<String, dynamic> controlApp = {
    'name': 'control_app',
    'description':
        'Block + minimize a distracting app, or re-allow one. This NEVER closes '
        'or kills the app — it only pushes it out of the way (minimize) or stops '
        'minimizing it (allow). Use it to quiet distractions during lockdown.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'app_identifier': {
          'type': 'string',
          'description': 'Friendly name or image name of the app to control.',
        },
        'action': {
          'type': 'string',
          'enum': ['block', 'minimize', 'allow'],
        },
        'message': {
          'type': 'string',
          'description': 'The user-facing reply. The ONLY text the user sees.',
        },
      },
      'required': ['app_identifier', 'action', 'message'],
    },
  };

  /// save_memory — persist a durable fact/pattern the guardian learned about the
  /// user so future nights reference it (learns + remembers).
  static const Map<String, dynamic> saveMemory = {
    'name': 'save_memory',
    'description':
        'Remember a durable fact, pattern, preference, or constraint about the '
        'user for future nights. Use sparingly for things worth carrying '
        'forward, not chit-chat.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'memory_type': {
          'type': 'string',
          'enum': [
            'goal',
            'mood',
            'constraint',
            'preference',
            'openLoop',
          ],
        },
        'text': {
          'type': 'string',
          'description': 'The fact to remember, in your own words.',
        },
        'message': {
          'type': 'string',
          'description': 'The user-facing reply. The ONLY text the user sees.',
        },
      },
      'required': ['memory_type', 'text', 'message'],
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

  /// The tool set in stable order. The LAST tool carries the cache_control
  /// breakpoint (added by the request builder, not here). ORDER IS STABLE:
  /// changing it would invalidate the prompt cache, so new tools are APPENDED
  /// before the trailing end_session anchor stays last is NOT required — the
  /// builder stamps cache_control on whatever is last, so we just keep this list
  /// append-only.
  static const List<Map<String, dynamic>> all = [
    guardianAction,
    unlockApp,
    adjustSchedule,
    controlApp,
    saveMemory,
    endSession,
  ];
}

/// Extract the CURRENT (possibly partial) value of a top-level string field
/// from a possibly-incomplete JSON object string. Used to surface the
/// guardian's `message` live while the tool-input JSON is still streaming in
/// over SSE.
///
/// Algorithm: find `"<field>"`, then the next `:`, then the opening `"`, then
/// read characters until an UNescaped closing `"` (value complete) or the end
/// of the buffer (value still arriving). Escapes are unescaped on the fly
/// (`\n \t \r \" \\ \/ \b \f` and `\uXXXX` best-effort). A trailing lone
/// backslash (an escape whose payload hasn't arrived yet) is dropped so we
/// never emit a dangling `\`.
///
/// Returns null when the key, its colon, or the value-opening quote has not yet
/// appeared in the buffer — i.e. there is nothing to show for [field] yet.
String? extractPartialJsonStringField(String partialJson, String field) {
  final keyToken = '"$field"';
  // Search for the key. Restart the scan whenever the colon/quote that should
  // follow turns out not to (defends against a same-named substring appearing
  // earlier in another value — unlikely for our schema but cheap to guard).
  var searchFrom = 0;
  while (true) {
    final keyIndex = partialJson.indexOf(keyToken, searchFrom);
    if (keyIndex < 0) return null;

    var i = keyIndex + keyToken.length;
    // Skip whitespace to the colon.
    while (i < partialJson.length && _isJsonWs(partialJson.codeUnitAt(i))) {
      i++;
    }
    if (i >= partialJson.length) return null; // colon not here yet
    if (partialJson.codeUnitAt(i) != _colon) {
      // Not actually our key (no colon follows) — keep looking.
      searchFrom = keyIndex + keyToken.length;
      continue;
    }
    i++; // past ':'
    // Skip whitespace to the opening quote.
    while (i < partialJson.length && _isJsonWs(partialJson.codeUnitAt(i))) {
      i++;
    }
    if (i >= partialJson.length) return null; // value-open not here yet
    if (partialJson.codeUnitAt(i) != _quote) {
      // Value is not a string (or the opening quote hasn't streamed). Nothing
      // to surface for a string field yet.
      searchFrom = keyIndex + keyToken.length;
      continue;
    }
    i++; // past opening '"'

    final sb = StringBuffer();
    while (i < partialJson.length) {
      final c = partialJson.codeUnitAt(i);
      if (c == _backslash) {
        // An escape sequence. If its payload hasn't streamed yet, stop and emit
        // what we have (drop the lone trailing backslash).
        if (i + 1 >= partialJson.length) break;
        final next = partialJson.codeUnitAt(i + 1);
        switch (next) {
          case 0x6E: // n
            sb.write('\n');
            i += 2;
          case 0x74: // t
            sb.write('\t');
            i += 2;
          case 0x72: // r
            sb.write('\r');
            i += 2;
          case 0x62: // b
            sb.write('\b');
            i += 2;
          case 0x66: // f
            sb.write('\f');
            i += 2;
          case _quote:
            sb.write('"');
            i += 2;
          case _backslash:
            sb.write('\\');
            i += 2;
          case 0x2F: // /
            sb.write('/');
            i += 2;
          case 0x75: // u — \uXXXX
            // Need 4 more hex digits. If they haven't all streamed, stop.
            if (i + 6 > partialJson.length) {
              i = partialJson.length; // force loop exit, drop partial escape
              break;
            }
            final hex = partialJson.substring(i + 2, i + 6);
            final code = int.tryParse(hex, radix: 16);
            if (code != null) {
              sb.writeCharCode(code);
            }
            i += 6;
          default:
            // Unknown escape — emit the escaped char literally.
            sb.writeCharCode(next);
            i += 2;
        }
        continue;
      }
      if (c == _quote) {
        // Unescaped closing quote — the value is complete.
        return sb.toString();
      }
      sb.writeCharCode(c);
      i++;
    }
    // Reached end of buffer without a closing quote: value still arriving.
    return sb.toString();
  }
}

const int _quote = 0x22; // "
const int _backslash = 0x5C; // \
const int _colon = 0x3A; // :

bool _isJsonWs(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D; // space tab nl cr

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
      final reason = input['reason'];
      // Fail CLOSED on malformed input: an unknown field, out-of-range or
      // missing hour/minute, or an empty reason must collapse to deny rather
      // than push invalid state downstream into the guardrails/store.
      if (!ScheduleGuardrails.validFields.contains(field) ||
          hour == null ||
          hour < 0 ||
          hour > 23 ||
          minute == null ||
          minute < 0 ||
          minute > 59 ||
          reason is! String ||
          reason.trim().isEmpty) {
        return _denyFallback();
      }
      // Default to tonight when scope is absent — a tonight nudge is the
      // mostly-revertible, lower-stakes option.
      final scope = (input['scope'] as String?)?.toLowerCase() == 'permanent'
          ? ScheduleScope.permanent
          : ScheduleScope.tonight;
      return GuardianDecision(
        message: message,
        action: GuardianAction.adjustSchedule,
        scheduleField: field,
        scheduleHour: hour,
        scheduleMinute: minute,
        scheduleReason: reason,
        scheduleScope: scope,
      );
    case 'control_app':
      final identifier = input['app_identifier'];
      final action = (input['action'] as String?)?.toLowerCase();
      // Fail CLOSED: an unknown action or blank identifier collapses to deny so
      // we never push an invalid control instruction downstream.
      if (identifier is! String ||
          identifier.trim().isEmpty ||
          !(action == 'block' || action == 'minimize' || action == 'allow')) {
        return _denyFallback();
      }
      return GuardianDecision(
        message: message,
        action: GuardianAction.controlApp,
        controlAppIdentifier: identifier,
        // 'block' and 'minimize' are both "push it out of the way"; normalize
        // 'block' -> 'minimize' so the platform layer has a single verb.
        controlAppAction: action == 'block' ? 'minimize' : action,
      );
    case 'save_memory':
      final text = input['text'];
      final memoryType = input['memory_type'];
      if (text is! String ||
          text.trim().isEmpty ||
          memoryType is! String ||
          memoryType.trim().isEmpty) {
        return _denyFallback();
      }
      return GuardianDecision(
        message: message,
        action: GuardianAction.saveMemory,
        memoryType: memoryType,
        memoryText: text,
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

/// Matches a BARE action/decision label line the Gemini model sometimes leaks
/// next to (or instead of) its JSON decision object — e.g. `deny request`,
/// `Decision: deny`, `**Action:** grant`, `outcome = lock`. These must never
/// reach the chat bubble. Anchored to the whole (trimmed, lower-cased) line.
final RegExp _bareActionLabel = RegExp(
  r'^\*{0,2}(action|decision|result|outcome)\s*[:=]?\s*\*{0,2}\s*'
  r'(grant|deny|lock|minimize|close|exit|unlock)(\s+request)?\*{0,2}$',
);

/// Exact bare keywords (no label prefix) that are pure decision leakage.
const Set<String> _bareDecisionWords = {
  'grant',
  'deny',
  'lock',
  'minimize',
  'close',
  'exit',
  'unlock',
  'deny request',
  'grant request',
};

@visibleForTesting
String cleanGeminiResponse(String response) {
  final cleaned = response
      .trim()
      .split('\n')
      .where((line) {
        final trimmed = line.trim();
        // 1. The JSON decision object line.
        if (trimmed.startsWith('{') && trimmed.contains('"decision"')) {
          return false;
        }
        // 2. A bare action-label line ("deny request", "Decision: deny",
        //    "**Action:** grant", etc.) the model leaks alongside/without JSON.
        final lower = trimmed.toLowerCase();
        if (_bareActionLabel.hasMatch(lower)) return false;
        // 3. A standalone bare decision keyword on its own line.
        if (_bareDecisionWords.contains(lower)) return false;
        return true;
      })
      .join('\n')
      .trim();
  return cleaned.isEmpty ? 'no.' : cleaned;
}
