import 'package:flutter_test/flutter_test.dart';
import 'package:location_alarm_prototype/main.dart';

void main() {
  testWidgets('LocationAlarmApp builds', (WidgetTester tester) async {
    await tester.pumpWidget(const LocationAlarmApp());

    expect(find.text('LevAlert'), findsOneWidget);
  });
}
