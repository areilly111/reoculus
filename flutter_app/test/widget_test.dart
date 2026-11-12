// Smoke test: the app builds and shows its navigation.
// The rail has ten destinations, which need more than the default
// 800x600 test viewport's height, so the surface is a realistic
// desktop size first.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quest_companion/main.dart';

void main() {
  testWidgets('App builds and shows navigation', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const QuestCompanionApp());
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Devices'), findsWidgets);
    expect(find.text('Apps'), findsWidgets);
  });
}
