import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/anthropic_stream.dart';
import 'package:sleep_time/core/guardian_tools.dart';

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

    test('ping and unknown events are no-ops', () {
      final acc = newAcc();
      expect(acc.handleEvent('ping', {}), isNull);
      expect(acc.handleEvent('something_new', {'foo': 'bar'}), isNull);
      expect(acc.toolName, isNull);
      expect(acc.toolInputJson, isEmpty);
    });

    test('text_delta blocks are ignored (message lives in tool input)', () {
      final acc = newAcc();
      acc.handleEvent('content_block_start', {
        'index': 0,
        'content_block': {'type': 'text'},
      });
      final s = acc.handleEvent('content_block_delta', {
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'hi'},
      });
      expect(s, isNull);
      expect(acc.toolName, isNull);
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
}
