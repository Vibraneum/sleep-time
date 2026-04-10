import 'package:flutter_test/flutter_test.dart';

import 'package:sleep_time/main.dart';

void main() {
  testWidgets('App renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const SleepTimeApp());
    expect(find.text('Sleep Time'), findsOneWidget);
  });
}
