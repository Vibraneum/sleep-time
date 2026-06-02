import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/anthropic_stream.dart';
import 'package:sleep_time/core/guardian_tools.dart';
import 'package:sleep_time/core/negotiation_engine.dart';

void main() {
  group('AnthropicStreamAccumulator', () {
    AnthropicStreamAccumulator newAcc() => AnthropicStreamAccumulator(
          extractMessage: extractPartialJsonStringField,
        );

    test('accumulates input_json_delta fragments into the full tool input', () {
      final acc = newAcc();
      acc.handleEvent('message_start', {'message': {}});
      acc.handleEvent('content_block_start', {
        'index': 0,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_abc',
          'name': 'guardian_action',
          'input': <String, dynamic>{},
        },
      });
      // Fragmented tool-input JSON arriving over several deltas.
      acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"action":"den'},
      });
      acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': 'y","message":"no'},
      });
      acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {
          'type': 'input_json_delta',
          'partial_json': '. sleep."}',
        },
      });
      acc.handleEvent('content_block_stop', {'index': 0});
      acc.handleEvent('message_delta', {
        'delta': {'stop_reason': 'tool_use'},
      });
      acc.handleEvent('message_stop', {});

      expect(acc.toolName, 'guardian_action');
      expect(acc.toolUseId, 'toolu_abc');
      expect(acc.stopReason, 'tool_use');
      expect(acc.toolInputJson, '{"action":"deny","message":"no. sleep."}');

      final input = acc.decodeToolInput();
      expect(input['action'], 'deny');
      expect(input['message'], 'no. sleep.');
    });

    test('captures a refusal stop_reason (no tool block emitted)', () {
      // On a refusal the model emits no tool_use; the engine reads
      // acc.stopReason == "refusal" to return a safe in-character deny rather
      // than trying to parse an absent tool block.
      final acc = newAcc();
      acc.handleEvent('message_start', {'message': {}});
      acc.handleEvent('message_delta', {
        'delta': {'stop_reason': 'refusal'},
      });
      acc.handleEvent('message_stop', {});

      expect(acc.stopReason, 'refusal');
      expect(acc.toolName, isNull);
      expect(acc.toolInputJson, isEmpty);
    });

    test('emits progressive message snapshots only when the message changes',
        () {
      final acc = newAcc();
      acc.handleEvent('content_block_start', {
        'index': 0,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'guardian_action',
          'input': <String, dynamic>{},
        },
      });

      final snapshots = <String>[];
      String? push(String type, Map<String, dynamic> data) {
        final s = acc.handleEvent(type, data);
        if (s != null) snapshots.add(s);
        return s;
      }

      // Before the message key arrives, deltas about other keys emit nothing.
      push('content_block_delta', {
        'index': 0,
        'delta': {
          'type': 'input_json_delta',
          'partial_json': '{"action":"grant",',
        },
      });
      expect(snapshots, isEmpty);

      // Message key opens — empty string snapshot.
      push('content_block_delta', {
        'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': '"message":"'},
      });
      // Grow the message across deltas.
      push('content_block_delta', {
        'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': 'fine'},
      });
      push('content_block_delta', {
        'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': '. ten'},
      });
      push('content_block_delta', {
        'index': 0,
        'delta': {'type': 'input_json_delta', 'partial_json': '."}'},
      });

      expect(snapshots, ['', 'fine', 'fine. ten', 'fine. ten.']);
      expect(acc.currentMessage, 'fine. ten.');
    });

    test('reconstructs ordered [thinking(+signature), tool_use] content', () {
      final acc = newAcc();
      acc.handleEvent('message_start', {'message': {}});
      // Thinking block first (index 0): thinking_delta then signature_delta.
      acc.handleEvent('content_block_start', {
        'index': 0,
        'content_block': {'type': 'thinking', 'thinking': ''},
      });
      acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': 'is 2am too late? '},
      });
      acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': 'yeah, deny.'},
      });
      acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'signature_delta', 'signature': 'SIG_ABC123=='},
      });
      acc.handleEvent('content_block_stop', {'index': 0});
      // Tool block second (index 1).
      acc.handleEvent('content_block_start', {
        'index': 1,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_t',
          'name': 'guardian_action',
          'input': <String, dynamic>{},
        },
      });
      acc.handleEvent('content_block_delta', {
        'index': 1,
        'delta': {
          'type': 'input_json_delta',
          'partial_json': '{"action":"deny","message":"no. sleep."}',
        },
      });
      acc.handleEvent('content_block_stop', {'index': 1});
      acc.handleEvent('message_delta', {
        'delta': {'stop_reason': 'tool_use'},
      });
      acc.handleEvent('message_stop', {});

      expect(acc.toolName, 'guardian_action');
      final input = acc.decodeToolInput();
      expect(input['message'], 'no. sleep.');

      final content = acc.orderedContent(input);
      expect(content.length, 2);
      expect(content[0]['type'], 'thinking');
      expect(content[0]['thinking'], 'is 2am too late? yeah, deny.');
      expect(content[0]['signature'], 'SIG_ABC123==');
      expect(content[1]['type'], 'tool_use');
      expect(content[1]['id'], 'toolu_t');
      expect(content[1]['name'], 'guardian_action');
      expect(content[1]['input'], input);
      // The user-facing snapshot is the tool's message, never the thinking text.
      expect(acc.currentMessage, 'no. sleep.');
    });

    test('text-only stream (thinking + text, no tool) surfaces text', () {
      final acc = newAcc();
      final snapshots = <String>[];
      void push(String type, Map<String, dynamic> data) {
        final s = acc.handleEvent(type, data);
        if (s != null) snapshots.add(s);
      }

      push('message_start', {'message': {}});
      // Thinking block.
      push('content_block_start', {
        'index': 0,
        'content_block': {'type': 'thinking', 'thinking': ''},
      });
      push('content_block_delta', {
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': 'hmm, keep talking.'},
      });
      push('content_block_delta', {
        'index': 0,
        'delta': {'type': 'signature_delta', 'signature': 'SIG_T=='},
      });
      push('content_block_stop', {'index': 0});
      // Text block (no tool).
      push('content_block_start', {
        'index': 1,
        'content_block': {'type': 'text', 'text': ''},
      });
      push('content_block_delta', {
        'index': 1,
        'delta': {'type': 'text_delta', 'text': 'why '},
      });
      push('content_block_delta', {
        'index': 1,
        'delta': {'type': 'text_delta', 'text': 'now?'},
      });
      push('content_block_stop', {'index': 1});
      push('message_delta', {
        'delta': {'stop_reason': 'end_turn'},
      });
      push('message_stop', {});

      // No tool produced.
      expect(acc.toolName, isNull);
      expect(acc.toolInputJson, isEmpty);
      // The text block is surfaced live; thinking text never leaks into it.
      expect(acc.textBlock, 'why now?');
      expect(snapshots, ['why ', 'why now?']);

      // Ordered content preserves thinking(+signature) then text.
      final content = acc.orderedContent(const <String, dynamic>{});
      expect(content.length, 2);
      expect(content[0]['type'], 'thinking');
      expect(content[0]['signature'], 'SIG_T==');
      expect(content[1]['type'], 'text');
      expect(content[1]['text'], 'why now?');
    });

    test('ping and unknown events are no-ops', () {
      final acc = newAcc();
      expect(acc.handleEvent('ping', {}), isNull);
      expect(acc.handleEvent('something_new', {'foo': 'bar'}), isNull);
      expect(acc.toolName, isNull);
      expect(acc.toolInputJson, isEmpty);
    });

    test('text_delta is suppressed while a tool block is active', () {
      // When a tool_use block is being produced, the user-facing message lives
      // in the tool's `message` field — a stray text block must NOT override it.
      final acc = newAcc();
      acc.handleEvent('content_block_start', {
        'index': 0,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_x',
          'name': 'guardian_action',
          'input': <String, dynamic>{},
        },
      });
      acc.handleEvent('content_block_start', {
        'index': 1,
        'content_block': {'type': 'text'},
      });
      final s = acc.handleEvent('content_block_delta', {
        'index': 1,
        'delta': {'type': 'text_delta', 'text': 'hi'},
      });
      // Suppressed because a tool block exists.
      expect(s, isNull);
      expect(acc.toolName, 'guardian_action');
    });

    test('text_delta surfaces live when NO tool block is being produced', () {
      // A keep-talking `auto` reply (adaptive thinking) emits only a text block;
      // it should be surfaced live so the chat shows the guardian talking.
      final acc = newAcc();
      acc.handleEvent('content_block_start', {
        'index': 0,
        'content_block': {'type': 'text'},
      });
      final s = acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'hi'},
      });
      expect(s, 'hi');
      expect(acc.toolName, isNull);
      expect(acc.textBlock, 'hi');
    });
  });

  group('SseParser', () {
    test('parses a complete event from one chunk', () {
      final parser = SseParser();
      final events = parser.add(
        'event: content_block_start\ndata: {"index":0}\n\n',
      );
      expect(events.length, 1);
      expect(events.first.type, 'content_block_start');
      expect(jsonDecode(events.first.data), {'index': 0});
    });

    test('buffers a partial event across chunk boundaries', () {
      final parser = SseParser();
      var events = parser.add('event: content_block_delta\ndata: {"index"');
      expect(events, isEmpty); // incomplete — buffered
      events = parser.add(':0,"delta":{"type":"input_json_delta",'
          '"partial_json":"x"}}\n\n');
      expect(events.length, 1);
      expect(events.first.type, 'content_block_delta');
      final data = jsonDecode(events.first.data) as Map<String, dynamic>;
      expect(data['index'], 0);
    });

    test('parses multiple events in a single chunk and ignores pings', () {
      final parser = SseParser();
      final events = parser.add(
        'event: ping\ndata: {}\n\n'
        'event: message_delta\ndata: {"delta":{"stop_reason":"tool_use"}}\n\n',
      );
      expect(events.length, 2);
      expect(events[0].type, 'ping');
      expect(events[1].type, 'message_delta');
    });

    test('tolerates CRLF line endings', () {
      final parser = SseParser();
      final events =
          parser.add('event: message_stop\r\ndata: {}\r\n\r\n');
      expect(events.length, 1);
      expect(events.first.type, 'message_stop');
    });

    test('flush returns a trailing event not terminated by a blank line', () {
      final parser = SseParser();
      final events = parser.add('event: message_stop\ndata: {}');
      expect(events, isEmpty);
      final tail = parser.flush();
      expect(tail, isNotNull);
      expect(tail!.type, 'message_stop');
    });
  });

  group('SseParser + AnthropicStreamAccumulator end-to-end (no network)', () {
    test('canned stream yields the right tool input and message snapshots', () {
      final parser = SseParser();
      final acc = AnthropicStreamAccumulator(
        extractMessage: extractPartialJsonStringField,
      );
      final snapshots = <String>[];

      // A realistic canned SSE byte stream, fed in arbitrary chunk splits.
      const raw =
          'event: message_start\ndata: {"type":"message_start","message":{}}\n\n'
          'event: content_block_start\n'
          'data: {"type":"content_block_start","index":0,'
          '"content_block":{"type":"tool_use","id":"toolu_xyz",'
          '"name":"guardian_action","input":{}}}\n\n'
          'event: ping\ndata: {"type":"ping"}\n\n'
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"input_json_delta",'
          '"partial_json":"{\\"action\\":\\"grant\\",\\"minutes\\":5,"}}\n\n'
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"input_json_delta",'
          '"partial_json":"\\"message\\":\\"fine."}}\n\n'
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"input_json_delta",'
          '"partial_json":" five.\\"}"}}\n\n'
          'event: content_block_stop\n'
          'data: {"type":"content_block_stop","index":0}\n\n'
          'event: message_delta\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}\n\n'
          'event: message_stop\ndata: {"type":"message_stop"}\n\n';

      // Split the raw stream into small arbitrary chunks to exercise buffering.
      const chunkSize = 17;
      for (var i = 0; i < raw.length; i += chunkSize) {
        final end = (i + chunkSize) > raw.length ? raw.length : i + chunkSize;
        for (final event in parser.add(raw.substring(i, end))) {
          final data = jsonDecode(event.data) as Map<String, dynamic>;
          final s = acc.handleEvent(event.type, data);
          if (s != null) snapshots.add(s);
        }
      }

      expect(acc.toolName, 'guardian_action');
      expect(acc.toolUseId, 'toolu_xyz');
      expect(acc.stopReason, 'tool_use');
      expect(
        acc.toolInputJson,
        '{"action":"grant","minutes":5,"message":"fine. five."}',
      );

      final input = acc.decodeToolInput();
      expect(input['action'], 'grant');
      expect(input['minutes'], 5);
      expect(input['message'], 'fine. five.');

      // The message grows monotonically and ends at the final value.
      expect(snapshots.last, 'fine. five.');
      expect(snapshots.first, 'fine.');
    });
  });

  group('thinking-turn history validity (commit + next-turn ordering)', () {
    // After a thinking+tool turn, the committed assistant content MUST keep the
    // thinking block + signature before the tool_use, and the NEXT user turn
    // MUST prepend a tool_result (the tool_use_id is set). After a text-only
    // turn there is no tool_use_id, so the next user turn must NOT prepend one.
    test('thinking+tool turn: assistant content valid, next turn tool_result-first',
        () {
      final acc = AnthropicStreamAccumulator(
        extractMessage: extractPartialJsonStringField,
      );
      acc.handleEvent('content_block_start', {
        'index': 0,
        'content_block': {'type': 'thinking', 'thinking': ''},
      });
      acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': 'deny.'},
      });
      acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'signature_delta', 'signature': 'SIG=='},
      });
      acc.handleEvent('content_block_start', {
        'index': 1,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_hist',
          'name': 'guardian_action',
          'input': <String, dynamic>{},
        },
      });
      acc.handleEvent('content_block_delta', {
        'index': 1,
        'delta': {
          'type': 'input_json_delta',
          'partial_json': '{"action":"deny","message":"no."}',
        },
      });

      final input = acc.decodeToolInput();
      final assistantContent = acc.orderedContent(input);
      // Thinking(+signature) precedes the tool_use — the shape the API requires
      // for the follow-up tool_result turn to be accepted.
      expect(assistantContent[0]['type'], 'thinking');
      expect(assistantContent[0]['signature'], 'SIG==');
      expect(assistantContent[1]['type'], 'tool_use');
      final toolUseId = assistantContent[1]['id'] as String;
      expect(toolUseId, 'toolu_hist');

      // The next user turn, built with that pending tool_use_id, leads with a
      // tool_result that references it, then the user text.
      final nextTurn = buildUserTurnContent(
        userMessage: 'please?',
        pendingToolUseId: toolUseId,
      );
      expect(nextTurn[0]['type'], 'tool_result');
      expect(nextTurn[0]['tool_use_id'], 'toolu_hist');
      expect(nextTurn[1]['type'], 'text');
    });

    test('text-only turn: next user turn does NOT prepend a tool_result', () {
      // A keep-talking `auto` reply has no tool_use, so toolId is null and the
      // next user turn carries only the text block.
      final nextTurn = buildUserTurnContent(
        userMessage: 'please?',
        pendingToolUseId: null,
      );
      expect(nextTurn.length, 1);
      expect(nextTurn[0]['type'], 'text');
      expect(nextTurn[0]['text'], 'please?');
    });
  });
}
