import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/config.dart';
import 'package:sleep_time/core/negotiation_engine.dart';

void main() {
  group('buildAnthropicToolRequest', () {
    test('emits the tool set, tool_choice=any, no parallel tool use', () {
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

      expect(body['tool_choice'], {'type': 'any'});
      expect(body['disable_parallel_tool_use'], isTrue);
      expect(body['model'], AppConfig.anthropicModel);
      expect(body['model'], AppConfig.defaultAnthropicModel);
      expect(AppConfig.defaultAnthropicModel, 'claude-sonnet-4-6');
    });

    test('cache_control on the LAST system block and the LAST tool', () {
      final body = buildAnthropicToolRequest(
        systemPrompt: 'you are the guardian.',
        messages: const [],
      );

      final system = body['system'] as List<dynamic>;
      expect((system.last as Map)['cache_control'], {'type': 'ephemeral'});

      final tools = body['tools'] as List<dynamic>;
      // Only the last tool carries cache_control.
      expect((tools.last as Map)['cache_control'], {'type': 'ephemeral'});
      for (final t in tools.take(tools.length - 1)) {
        expect((t as Map).containsKey('cache_control'), isFalse);
      }
    });

    test('tool_choice is constant across calls in a session', () {
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
