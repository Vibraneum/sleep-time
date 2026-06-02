import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/core/config.dart';
import 'package:sleep_time/core/negotiation_engine.dart';
import 'package:sleep_time/ui/negotiation_chat.dart';

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
    // Pump frames until startSession() has loaded the asset and rendered the
    // hardcoded (grantsUsedTonight==0) greeting, clearing the _isLoading guard.
    final greeting = find.textContaining("what's so important");
    for (var i = 0; i < 50 && greeting.evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
    expect(greeting, findsOneWidget,
        reason: 'greeting should render (startSession settled, not loading)');
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
}
