import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/design/food_illustration.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/widgets/inventory_browser.dart';

class _AccessibilityStore extends InventoryStore {
  final rows = demoInventory(DateTime.now());
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  testWidgets('shelf media announces rendered source without duplicate text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      Future<void> show(String name, String? file) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FoodIllustration(
                name: name,
                photoFile: file,
                shelfPresentation: true,
                size: 92,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show('두부', 'missing.png');
      expect(find.bySemanticsLabel('대표 이미지'), findsOneWidget);
      expect(find.bySemanticsLabel('사용자 사진'), findsNothing);
      expect(find.bySemanticsLabel('대표'), findsNothing);
      await show('이름 모를 반찬', null);
      expect(find.bySemanticsLabel('분류 아이콘'), findsOneWidget);
      expect(find.bySemanticsLabel('대표 이미지'), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('320dp large text home has labelled accessible touch controls', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'kitchen_visited': true});
      final store = _AccessibilityStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: HomeScreen(store: store),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    } finally {
      semantics.dispose();
    }
  });

  test('core foreground/background pairs meet normal text contrast', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
    }

    for (final foreground in [
      FridgeTheme.ink,
      FridgeTheme.muted,
      FridgeTheme.terracotta,
    ]) {
      expect(
        contrast(foreground, const Color(0xFFFAF8F3)),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(
      contrast(Colors.white, const Color(0xFF303A32)),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(const Color(0xFF756E65), const Color(0xFFFAF8F3)),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets(
    'large text move dialog exposes all nine destinations without dragging',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _AccessibilityStore();
      addTearDown(store.dispose);
      final before = store.rows.map((row) => row.toJson()).toList();
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: InventoryBrowser(
                  store: store,
                  onOpen: (_) {},
                  onAdd: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inventory-organize-toggle')));
      await tester.pumpAndSettle();
      final move = find.byKey(const ValueKey('move-tofu'));
      await tester.scrollUntilVisible(
        move,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(move), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(move);
      await tester.pumpAndSettle();
      for (final storage in ['냉장', '냉동', '팬트리']) {
        final storageField = find.byKey(const ValueKey('move-storage'));
        await tester.ensureVisible(storageField);
        await tester.pumpAndSettle();
        await tester.tap(storageField);
        await tester.pumpAndSettle();
        await tester.tap(find.text(storage).last);
        await tester.pumpAndSettle();
        for (final shelf in ['위 선반', '가운데 선반', '아래 선반']) {
          final shelfField = find.byKey(const ValueKey('move-shelf'));
          await tester.ensureVisible(shelfField);
          await tester.pumpAndSettle();
          await tester.tap(shelfField);
          await tester.pumpAndSettle();
          await tester.tap(find.text(shelf).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(store.rows.map((row) => row.toJson()).toList(), before);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
