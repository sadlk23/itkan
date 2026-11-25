import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/design/food_illustration.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/widgets/inventory_browser.dart';

class _OrganizeStore extends InventoryStore {
  final rows = List.generate(
    100,
    (index) => InventoryBatch(
      id: index.toString().padLeft(3, '0'),
      name: '반찬 ${index.toString().padLeft(3, '0')}',
      quantity: 1,
      unit: '통',
      category: '반찬',
      shelfId: 'shelf-2',
      createdAt: DateTime(2026, 11, 9),
    ),
  );
  final changes = <InventoryChange>[];
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
  @override
  List<InventoryChange> get history => changes;
  @override
  Future<void> update(
    InventoryBatch batch, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) async {
    final index = rows.indexWhere((row) => row.id == batch.id);
    final previous = rows[index];
    rows[index] = batch.copyWith(revision: previous.revision + 1);
    changes.insert(
      0,
      InventoryChange(
        id: 'move-${changes.length}',
        label: '이동',
        createdAt: DateTime.now(),
        before: [previous],
        after: [rows[index]],
        action: 'move',
        source: source,
      ),
    );
    notifyListeners();
  }
}

Future<_OrganizeStore> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = _OrganizeStore();
  addTearDown(store.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: FridgeTheme.light,
      home: Scaffold(
        body: InventoryBrowser(store: store, onOpen: (_) {}, onAdd: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('inventory-organize-toggle')));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets(
    '100 item organize mode remains lazy and exposes empty destinations',
    (tester) async {
      final store = await _mount(tester);
      expect(find.byType(FoodIllustration).evaluate().length, lessThan(20));
      expect(find.byKey(const ValueKey('drop-fridge-shelf-1')), findsOneWidget);
      final last = find.byKey(const ValueKey('move-099'));
      await tester.scrollUntilVisible(
        last,
        500,
        maxScrolls: 100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(last), alignment: .5);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(find.byType(FoodIllustration).evaluate().length, lessThan(20));
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('반찬 099 위치 변경'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(store.history, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large organize drag keeps fixed destinations and saves exactly once',
    (tester) async {
      final store = await _mount(tester);
      final first = find.byKey(const ValueKey('item-000'));
      await tester.ensureVisible(first);
      final gesture = await tester.startGesture(tester.getCenter(first));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('tray-freezer-shelf-3')),
        findsOneWidget,
      );
      expect(find.byType(FoodIllustration).evaluate().length, lessThan(20));
      final destination = find.byKey(const ValueKey('tray-freezer-shelf-3'));
      await gesture.moveTo(tester.getCenter(destination));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.history, hasLength(1));
      final moved = store.rows.firstWhere((row) => row.id == '000');
      expect(moved.storageType, StorageType.freezer);
      expect(moved.shelfId, 'shelf-3');
      expect(moved.quantity, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
