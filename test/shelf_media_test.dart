import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/food_illustration.dart';

void main() {
  testWidgets('invalid photo falls back without retaining photo label', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FoodIllustration(
            name: '두부',
            photoFile: 'missing.png',
            shelfPresentation: true,
            size: 92,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('사진'), findsNothing);
    expect(find.text('대표'), findsOneWidget);
    expect(tester.getSize(find.byType(FoodIllustration)), const Size(92, 92));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unknown food uses same area without false representative label',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FoodIllustration(
              name: '처음 보는 재료',
              shelfPresentation: true,
              size: 92,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('대표'), findsNothing);
      expect(find.text('사진'), findsNothing);
      expect(tester.getSize(find.byType(FoodIllustration)), const Size(92, 92));
      expect(tester.takeException(), isNull);
    },
  );
}
