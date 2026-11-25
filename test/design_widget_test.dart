import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/design/food_illustration.dart';
import 'package:my_fridge/design/fridge_scene.dart';
import 'package:my_fridge/design/recipe_ingredient_banner.dart';
import 'package:my_fridge/models/inventory.dart';

void main() {
  for (final target in [StorageType.freezer, StorageType.fridge]) {
    testWidgets('independent door tap enters ${target.name} after animation', (
      tester,
    ) async {
      final opened = <StorageType>[];
      var fallback = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                child: FridgeDoor(
                  onOpen: () => fallback++,
                  onOpenStorage: opened.add,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(
          ValueKey(
            '${target == StorageType.freezer ? 'freezer' : 'fridge'}-door-target',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(opened, isEmpty);
      await tester.pumpAndSettle();
      expect(opened, [target]);
      expect(fallback, 0);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('pantry opens once with reduced motion and large text', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            disableAnimations: true,
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                child: PantryDoor(onOpen: () => opens++),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(InkWell));
    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'recipe board uses actual distinct ingredients in narrow layout',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 160,
                child: RecipeIngredientBanner(
                  names: ['토마토', '만두', '토마토', '양파', '우유'],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final illustrations = tester
          .widgetList<FoodIllustration>(find.byType(FoodIllustration))
          .toList();
      expect(illustrations.map((i) => i.name), ['토마토', '만두', '양파']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('door brand plate stays within door at large text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: SizedBox(width: 164, child: FridgeDoor(onOpen: () {})),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final plate = tester.getRect(
      find.byKey(const ValueKey('door-brand-plate')),
    );
    final wordmark = tester.getRect(find.text('EATKAN'));
    expect(plate.contains(wordmark.center), isTrue);
    expect(find.byIcon(Icons.local_florist_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('door opens once after animation despite repeated taps', (
    tester,
  ) async {
    var opens = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: FridgeTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              child: FridgeDoor(onOpen: () => opens++),
            ),
          ),
        ),
      ),
    );
    try {
      expect(
        tester.getSemantics(find.bySemanticsLabel('냉장고 문 열기')),
        matchesSemantics(label: '냉장고 문 열기', isButton: true, hasTapAction: true),
      );
    } finally {
      // Release before the framework's end-of-test invariant check.
      semantics.dispose();
    }
    await tester.tap(find.byType(InkWell));
    await tester.pump(const Duration(milliseconds: 100));
    expect(opens, 0);
    await tester.tap(find.byType(InkWell), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion skips door animation', (tester) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                child: FridgeDoor(onOpen: () => opens++),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(opens, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow shelf grows for large text and preserves every ingredient',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FridgeScene(
                    storageLabel: '냉장',
                    children: List.generate(
                      7,
                      (i) => Column(
                        children: [
                          const FoodIllustration(name: '두부'),
                          Text('재료 $i'),
                          const Text('300g · 날짜 미상'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('재료 6'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
