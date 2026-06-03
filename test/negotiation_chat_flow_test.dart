import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/config.dart';
import 'package:sleep_time/core/negotiation_engine.dart';
import 'package:sleep_time/ui/negotiation_chat.dart';

/// Engine whose [negotiate] never completes until the test releases it, so we
/// can park the chat in its loading state (_isLoading == true) and prove the
/// safe word still fires while a model call is in flight (#1).
class _StuckEngine extends NegotiationEngine {
  final Completer<GuardianDecision> gate = Completer<GuardianDecision>();
  bool negotiateCalled = false;

  @override
  Future<GuardianDecision> negotiate(
    String userMessage, {
    void Function(String partialMessage)? onDelta,
  }) {
    negotiateCalled = true;
    return gate.future;
  }
}

/// Engine that drives a burst of streamed [onDelta] updates synchronously and
/// then returns a final decision. Lets us prove the streaming UI throttle
/// coalesces rapid tokens without dropping the last one (#1 throttle), and that
/// the input field's element identity / focus survives a streamed reply.
class _StreamingEngine extends NegotiationEngine {
  final List<String> deltas;
  final String finalMessage;

  _StreamingEngine({required this.deltas, required this.finalMessage});

  @override
  Future<GuardianDecision> negotiate(
    String userMessage, {
    void Function(String partialMessage)? onDelta,
  }) async {
    if (onDelta != null) {
      for (final d in deltas) {
        onDelta(d);
      }
    }
    return GuardianDecision(
      message: finalMessage,
      action: GuardianAction.none,
    );
  }
}

/// End-to-end widget coverage of the negotiation loop: a user types into the
/// real chat UI, the engine returns a decision, and the screen dispatches the
/// matching action callback. Uses the debug `solara` grant bypass and the safe
/// word so no API key / network is required, and stays in safe mode throughout.
///
/// These run inside [WidgetTester.runAsync] (real clock) because the chat's
/// `startSession()` does real async I/O (rootBundle asset load) that the fake
/// test clock does not drive, and the terminal-action dispatch is deferred
/// behind a real `Future.delayed`. Real waits keep both deterministic.
void main() {
  setUp(() {
    AppConfig.safeWord = 'dontdie';
  });

  Future<void> settleGreeting(WidgetTester tester) async {
    // With no API key configured (tests run keyless in safe mode), the opening
    // turn is NOT a hardcoded greeting anymore — startSession() renders the
    // "guardian offline" system banner and clears _isLoading. Pump until it
    // appears so the input is live before we type.
    final banner = find.textContaining('guardian offline');
    for (var i = 0; i < 50 && banner.evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
    expect(banner, findsOneWidget,
        reason: 'offline banner should render (startSession settled, keyless)');
  }

  testWidgets('typing the debug bypass grants time and fires onGranted',
      (tester) async {
    await tester.runAsync(() async {
      int? grantedMinutes;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NegotiationChat(
              engine: NegotiationEngine(),
              grantsUsedTonight: 0,
              onGranted: (m) => grantedMinutes = m,
            ),
          ),
        ),
      );
      await settleGreeting(tester);

      await tester.enterText(find.byType(TextField), 'solara');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('one minute'), findsOneWidget);

      // Terminal grant dispatch is deferred ~2s (real clock under runAsync).
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      await tester.pump();
      expect(grantedMinutes, 1,
          reason: 'debug solara bypass grants exactly 1 minute');
    });
  });

  testWidgets(
      '#4 a grant does NOT freeze the input — chat stays live (unlimited)',
      (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NegotiationChat(
              engine: NegotiationEngine(),
              grantsUsedTonight: 0,
              onGranted: (_) {},
            ),
          ),
        ),
      );
      await settleGreeting(tester);

      // solara debug bypass returns a GRANT decision.
      await tester.enterText(find.byType(TextField), 'solara');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.textContaining('one minute'), findsOneWidget);

      // Let the deferred onGranted dispatch (~2s) run.
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      await tester.pump();

      // The input must remain ENABLED after a grant — the conversation is
      // continuous; only the safe word / end_session freeze it.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isTrue,
          reason: 'grant must not set _negotiationOver / disable the input');
    });
  });

  testWidgets('typing the safe word ends the session and fires onClose',
      (tester) async {
    await tester.runAsync(() async {
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NegotiationChat(
              engine: NegotiationEngine(),
              grantsUsedTonight: 0,
              onGranted: (_) {},
              onClose: () => closed = true,
            ),
          ),
        ),
      );
      await settleGreeting(tester);

      await tester.enterText(find.byType(TextField), 'dontdie');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('safe word'), findsOneWidget);

      // onClose is deferred ~1s (real clock under runAsync).
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(closed, isTrue);
    });
  });

  testWidgets(
      '#1 safe word fires even while the guardian is thinking (loading)',
      (tester) async {
    await tester.runAsync(() async {
      var closed = false;
      final engine = _StuckEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NegotiationChat(
              engine: engine,
              grantsUsedTonight: 0,
              onGranted: (_) {},
              onClose: () => closed = true,
            ),
          ),
        ),
      );
      await settleGreeting(tester);

      // Kick off a normal message: negotiate() hangs on the gate, parking the
      // chat in its loading state (_isLoading == true).
      await tester.enterText(find.byType(TextField), 'please five minutes');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(engine.negotiateCalled, isTrue,
          reason: 'first message should start an in-flight model call');
      expect(closed, isFalse);

      // Now type the safe word WHILE the call is still pending. Under the old
      // `if (... || _isLoading) return;` guard this would be silently dropped.
      await tester.enterText(find.byType(TextField), 'dontdie');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(find.textContaining('safe word'), findsOneWidget,
          reason: 'safe word must be accepted even mid-call');

      // onClose is deferred ~1s.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(closed, isTrue,
          reason: 'safe word must release regardless of loading state');

      // Release the gate so the pending future does not dangle.
      engine.gate.complete(GuardianDecision(
        message: 'late',
        action: GuardianAction.none,
      ));
    });
  });

  testWidgets(
      'streaming throttle coalesces a delta burst without dropping the last token',
      (tester) async {
    await tester.runAsync(() async {
      final engine = _StreamingEngine(
        deltas: const ['a', 'ab', 'abc', 'abcd', 'abcde'],
        finalMessage: 'abcdef',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NegotiationChat(
              engine: engine,
              grantsUsedTonight: 0,
              onGranted: (_) {},
            ),
          ),
        ),
      );
      await settleGreeting(tester);

      await tester.enterText(find.byType(TextField), 'please five minutes');
      await tester.testTextInput.receiveAction(TextInputAction.send);

      // Let the final setState (post-stream) and the ~70ms throttle settle.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();

      // The final message must always land in full — coalescing must not drop
      // the last token.
      expect(find.textContaining('abcdef'), findsOneWidget,
          reason: 'final streamed text must always be applied in full');
    });
  });

  testWidgets(
      '#3/#4 input element identity is stable across a streamed reply',
      (tester) async {
    await tester.runAsync(() async {
      final engine = _StreamingEngine(
        deltas: List<String>.generate(40, (i) => 'tok' * (i + 1)),
        finalMessage: 'done streaming',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NegotiationChat(
              engine: engine,
              grantsUsedTonight: 0,
              onGranted: (_) {},
            ),
          ),
        ),
      );
      await settleGreeting(tester);

      final inputFinder = find.byKey(const ValueKey('guardian_input'));
      expect(inputFinder, findsOneWidget,
          reason: 'input must carry the stable ValueKey');

      // Capture the live Element backing the input before the stream.
      final elementBefore = tester.element(inputFinder);

      // Focus the field, then drive a streamed guardian reply.
      FocusScope.of(elementBefore).requestFocus(
        tester.widget<TextField>(inputFinder).focusNode,
      );
      await tester.pump();

      await tester.enterText(inputFinder, 'keep my focus please');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();

      // The element backing the keyed input must be the SAME instance after the
      // stream (no element recycling), so the text-input connection is never
      // torn down and focus/characters are never lost.
      final elementAfter = tester.element(inputFinder);
      expect(identical(elementBefore, elementAfter), isTrue,
          reason: 'stable key must preserve the same input element across '
              'streaming rebuilds');
    });
  });
}
