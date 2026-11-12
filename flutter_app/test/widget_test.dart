// Smoke test: the app builds and shows its navigation.
import 'package:flutter_test/flutter_test.dart';

import 'package:quest_companion/main.dart';

void main() {
  testWidgets('App builds and shows navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const QuestCompanionApp());
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Devices'), findsWidgets);
    expect(find.text('Apps'), findsWidgets);
  });
}
