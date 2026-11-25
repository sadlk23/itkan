import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/food_illustration.dart';

void main() {
  testWidgets('large source label stays inside its media area', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const Scaffold(
            body: FoodIllustration(
              name: '두부',
              shelfPresentation: true,
              size: 92,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final media = tester.getRect(find.byType(FoodIllustration));
    final label = tester.getRect(find.text('대표'));
    expect(media.contains(label.topLeft), isTrue);
    expect(label.bottom, lessThan(media.bottom));
    expect(label.right, lessThanOrEqualTo(media.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reused item drops old source when photo and food change', (
    tester,
  ) async {
    Future<void> show(String name, String? photoFile) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FoodIllustration(
              key: const ValueKey('same-inventory-position'),
              name: name,
              photoFile: photoFile,
              shelfPresentation: true,
              size: 92,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('두부', 'missing.png');
    expect(find.text('대표'), findsOneWidget);
    await show('엄마가 만든 이름 모를 반찬', 'another-missing.png');
    expect(find.text('사진'), findsNothing);
    expect(find.text('대표'), findsNothing);
    await show('우유', null);
    expect(find.text('대표'), findsOneWidget);
    expect(tester.getSize(find.byType(FoodIllustration)), const Size(92, 92));
    expect(tester.takeException(), isNull);
  });
}
