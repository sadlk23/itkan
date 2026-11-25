import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/design/food_illustration.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/widgets/inventory_browser.dart';

class _LargeInventory extends InventoryStore {
  _LargeInventory(int count)
    : rows = List.generate(
        count,
        (index) => InventoryBatch(
          id: index.toString().padLeft(3, '0'),
          name: '가족이 함께 먹으려고 직접 만든 이름이 긴 반찬 $index',
          quantity: 1,
          unit: '통',
          category: '반찬',
          shelfId: 'shelf-2',
          createdAt: DateTime(2026, 11, 9),
        ),
      );
  final List<InventoryBatch> rows;
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  for (final scenario in [(100, 1.0, 390.0), (20, 2.0, 320.0)]) {
    final (count, scale, width) = scenario;
    testWidgets(
      '$count rows at ${width}dp and text scale $scale build lazily and remain reachable',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = _LargeInventory(count);
        addTearDown(store.dispose);
        String? openedId;
        await tester.pumpWidget(
          MaterialApp(
            theme: FridgeTheme.light,
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: InventoryBrowser(
                    store: store,
                    onOpen: (batch) => openedId = batch.id,
                    onAdd: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // Assert bounded mounted media rather than a device-specific frame time.
        expect(find.byType(FoodIllustration).evaluate().length, lessThan(20));
        final lastId = (count - 1).toString().padLeft(3, '0');
        final last = find.byKey(ValueKey('item-$lastId'));
        expect(last, findsNothing);
        await tester.scrollUntilVisible(
          last,
          500,
          maxScrolls: 100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(last);
        expect(openedId, lastId);
        expect(find.byType(FoodIllustration).evaluate().length, lessThan(20));
      },
    );
  }

  testWidgets('list mode also mounts only viewport inventory', (tester) async {
    final store = _LargeInventory(100);
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InventoryBrowser(store: store, onOpen: (_) {}, onAdd: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inventory-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(FoodIllustration).evaluate().length, lessThan(20));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('item-099')),
      500,
      maxScrolls: 100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('item-099')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
