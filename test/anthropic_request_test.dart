import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/config.dart';
import 'package:sleep_time/core/negotiation_engine.dart';

void main() {
  group('buildAnthropicToolRequest', () {
    // Adaptive thinking flips the request shape; set it explicitly per test and
    // restore the default so tests never leak state into each other.
    setUp(() {
      AppConfig.adaptiveThinking = true;
    });
    tearDown(() {
      AppConfig.adaptiveThinking = true;
    });

    test('emits the tool set, no parallel tool use', () {
      AppConfig.adaptiveThinking = false;
      final body = buildAnthropicToolRequest(
        systemPrompt: 'you are the guardian.',
        messages: const [],
      );

      final tools = body['tools'] as List<dynamic>;
      expect(tools.length, 6);

      final names = tools.map((t) => (t as Map)['name']).toList();
      // Stable, append-only order. end_session stays LAST so it carries the
      // cache_control breakpoint (verified in the next test).
      expect(names, [
        'guardian_action',
        'unlock_app',
        'adjust_schedule',
        'control_app',
        'save_memory',
        'end_session',
      ]);

      expect(body['disable_parallel_tool_use'], isTrue);
      expect(body['model'], AppConfig.anthropicModel);
      expect(body['model'], AppConfig.defaultAnthropicModel);
      expect(AppConfig.defaultAnthropicModel, 'claude-sonnet-4-6');
    });

    test('adaptive thinking ON: thinking + auto + low effort + headroom', () {
      AppConfig.adaptiveThinking = true;
      final body = buildAnthropicToolRequest(
        systemPrompt: 'you are the guardian.',
        messages: const [],
      );

      // Thinking is incompatible with forced tool use, so tool_choice MUST be
      // auto (any/tool would 400).
      expect(body['tool_choice'], {'type': 'auto'});
      expect(body['thinking'], {'type': 'adaptive'});
      expect((body['output_config'] as Map)['effort'], 'low');
      expect(body['disable_parallel_tool_use'], isTrue);
      // Thinking needs headroom.
      expect(body['max_tokens'] as int, greaterThanOrEqualTo(4096));
      // Sampling params 400 with thinking enabled — temperature must be omitted.
      expect(body.containsKey('temperature'), isFalse);
    });

    test('adaptive thinking OFF: legacy shape (any, no thinking)', () {
      AppConfig.adaptiveThinking = false;
      final body = buildAnthropicToolRequest(
        systemPrompt: 'you are the guardian.',
        messages: const [],
        maxTokens: 500,
      );

      expect(body['tool_choice'], {'type': 'any'});
      expect(body.containsKey('thinking'), isFalse);
      expect(body.containsKey('output_config'), isFalse);
      expect(body['disable_parallel_tool_use'], isTrue);
      expect(body['max_tokens'], 500);
      // Legacy path keeps sending temperature (no thinking, so it's allowed).
      expect(body['temperature'], isNotNull);
    });

    test('cache_control (1h TTL) on the LAST system block and the LAST tool',
        () {
      final body = buildAnthropicToolRequest(
        systemPrompt: 'you are the guardian.',
        messages: const [],
      );

      final system = body['system'] as List<dynamic>;
      // 1h TTL (GA) keeps system+tools cached across a whole bedtime session.
      expect((system.last as Map)['cache_control'],
          {'type': 'ephemeral', 'ttl': '1h'});

      final tools = body['tools'] as List<dynamic>;
      // Only the last tool carries cache_control, and it carries the 1h TTL too.
      expect((tools.last as Map)['cache_control'],
          {'type': 'ephemeral', 'ttl': '1h'});
      for (final t in tools.take(tools.length - 1)) {
        expect((t as Map).containsKey('cache_control'), isFalse);
      }
    });

    test('tool_choice is constant across calls in a session (thinking off)', () {
      AppConfig.adaptiveThinking = false;
      final first = buildAnthropicToolRequest(
        systemPrompt: 'prompt',
        messages: const [],
      );
      final second = buildAnthropicToolRequest(
        systemPrompt: 'prompt',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      );

      expect(first['tool_choice'], second['tool_choice']);
      expect(first['tool_choice'], {'type': 'any'});
    });

    test('tool_choice is constant across calls in a session (thinking on)', () {
      AppConfig.adaptiveThinking = true;
      final first = buildAnthropicToolRequest(
        systemPrompt: 'prompt',
        messages: const [],
      );
      final second = buildAnthropicToolRequest(
        systemPrompt: 'prompt',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      );

      expect(first['tool_choice'], second['tool_choice']);
      expect(first['tool_choice'], {'type': 'auto'});
    });

    test('does not mutate the shared const tool definitions', () {
      // Build twice; the second build must still see clean tools (no leaked
      // cache_control on non-last tools from a prior build).
      buildAnthropicToolRequest(systemPrompt: 'a', messages: const []);
      final body = buildAnthropicToolRequest(
        systemPrompt: 'b',
        messages: const [],
      );
      final tools = body['tools'] as List<dynamic>;
      expect((tools.first as Map).containsKey('cache_control'), isFalse);
    });
  });

  group('buildUserTurnContent — tool_result-first invariant', () {
    test('pending tool_use puts tool_result at index 0, then text', () {
      final content = buildUserTurnContent(
        userMessage: 'i need five minutes',
        pendingToolUseId: 'toolu_123',
      );

      expect(content.length, 2);
      expect(content[0]['type'], 'tool_result');
      expect(content[0]['tool_use_id'], 'toolu_123');
      expect(content[1]['type'], 'text');
      expect(content[1]['text'], 'i need five minutes');
    });

    test('no pending tool_use yields just the text block', () {
      final content = buildUserTurnContent(
        userMessage: 'hello',
        pendingToolUseId: null,
      );

      expect(content.length, 1);
      expect(content[0]['type'], 'text');
      expect(content[0]['text'], 'hello');
    });
  });
}
