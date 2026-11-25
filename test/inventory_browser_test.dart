import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/widgets/inventory_browser.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryStore extends InventoryStore {
  final _rows = demoInventory(DateTime.now());
  final _changes = <InventoryChange>[];
  @override
  List<InventoryBatch> get batches => List.unmodifiable(_rows);
  @override
  List<InventoryBatch> get activeBatches =>
      _rows.where((b) => b.active).toList();
  @override
  List<InventoryChange> get history => List.unmodifiable(_changes);
  @override
  Future<void> update(
    InventoryBatch batch, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) async {
    final index = _rows.indexWhere((b) => b.id == batch.id);
    final before = _rows[index];
    _rows[index] = batch.copyWith(revision: before.revision + 1);
    _changes.insert(
      0,
      InventoryChange(
        id: 'move-${_changes.length}',
        label: '이동',
        createdAt: DateTime.now(),
        before: [before],
        after: [_rows[index]],
        action: 'move',
        source: source,
        requestId: requestId,
      ),
    );
    notifyListeners();
  }
}

void main() {
  sqfliteFfiInit();

  Future<(InventoryStore, Object?)> prepare(WidgetTester tester) async {
    final store = _MemoryStore();
    addTearDown(store.dispose);
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return (store, null);
  }

  Widget app(
    InventoryStore store, {
    ValueChanged<String>? shopping,
    double scale = 1,
    StorageType initialStorage = StorageType.fridge,
  }) => MaterialApp(
    theme: FridgeTheme.light,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: InventoryBrowser(
          store: store,
          onOpen: (_) {},
          onAdd: () {},
          onAddToShopping: shopping,
          initialStorage: initialStorage,
        ),
      ),
    ),
  );

  Future<void> waitSaved(WidgetTester tester, InventoryStore store) async {
    await tester.pumpAndSettle();
    expect(store.history, isNotEmpty);
  }

  for (final storage in [StorageType.freezer, StorageType.pantry]) {
    testWidgets(
      'initial ${storage.name} shows its rows and tabs remain interactive',
      (tester) async {
        final (store, _) = await prepare(tester);
        await tester.pumpWidget(app(store, initialStorage: storage));
        await tester.pumpAndSettle();
        final expected = store.activeBatches.where(
          (b) => b.storageType == storage,
        );
        expect(expected, isNotEmpty);
        for (final batch in expected) {
          expect(find.byKey(ValueKey('item-${batch.id}')), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('item-tofu')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('storage-fridge')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('item-tofu')), findsOneWidget);
        for (final batch in expected) {
          expect(find.byKey(ValueKey('item-${batch.id}')), findsNothing);
        }
      },
    );
  }

  testWidgets(
    'selection toggles multiple batches and preserves IDs across views without opening details',
    (tester) async {
      final (store, _) = await prepare(tester);
      var selecting = false;
      final selected = <String>{};
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => InventoryBrowser(
                store: store,
                onOpen: (_) => opened++,
                onAdd: () {},
                selectedIds: selected,
                selecting: selecting,
                onSelectionModeChanged: () =>
                    update(() => selecting = !selecting),
                onToggleSelection: (batch) => update(() {
                  if (!selected.add(batch.id)) selected.remove(batch.id);
                }),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('item-tofu')));
      expect(opened, 1);
      await tester.tap(
        find.byKey(const ValueKey('inventory-selection-toggle')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('inventory-selection-toggle')))
            .height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byKey(const ValueKey('item-tofu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('item-milk')));
      await tester.pumpAndSettle();
      expect(selected, {'tofu', 'milk'});
      expect(opened, 1);
      await tester.tap(find.byKey(const ValueKey('item-tofu')));
      await tester.pumpAndSettle();
      expect(selected, {'milk'});
      await tester.tap(find.byKey(const ValueKey('storage-freezer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storage-fridge')));
      await tester.pumpAndSettle();
      expect(selected, {'milk'});
      await tester.tap(find.byKey(const ValueKey('inventory-view-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('item-milk')));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      await tester.tap(find.byKey(const ValueKey('inventory-organize-toggle')));
      await tester.pumpAndSettle();
      expect(selecting, isFalse);
      expect(find.byKey(const ValueKey('move-tofu')), findsOneWidget);
      expect(store.history, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first two products fit above cooking action and next row peeks on 360 by 640',
    (tester) async {
      final (store, _) = await prepare(tester);
      tester.view.physicalSize = const Size(360, 640);
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          home: Scaffold(
            appBar: AppBar(title: const Text('나의 냉장고')),
            body: Column(
              children: [
                Expanded(
                  child: InventoryBrowser(
                    store: store,
                    onOpen: (_) {},
                    onAdd: () {},
                    onSelectionModeChanged: () {},
                  ),
                ),
                SizedBox(
                  height: 64,
                  child: Center(
                    child: FilledButton(
                      key: const ValueKey('cook-action'),
                      onPressed: () {},
                      child: const Text('보유 재료로 요리 찾기'),
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: const SizedBox(height: 80),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final actionTop = tester
          .getTopLeft(find.byKey(const ValueKey('cook-action')))
          .dy;
      for (final id in ['tofu', 'milk']) {
        final tile = find.byKey(ValueKey('item-$id'));
        expect(tile, findsOneWidget);
        expect(
          tester.getBottomLeft(tile).dy,
          lessThan(actionTop),
          reason: '$id name, quantity and expiry must be visible',
        );
        expect(find.byKey(ValueKey('move-$id')), findsNothing);
      }
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('item-leek'))).dy,
        lessThan(actionTop),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty inventory invites registration and many items remain reachable',
    (tester) async {
      final (store, _) = await prepare(tester);
      final memory = store as _MemoryStore;
      final template = memory._rows.first;
      memory._rows.clear();
      tester.view.physicalSize = const Size(360, 640);
      await tester.pumpWidget(app(store));
      expect(find.text('첫 재료를 채워볼까요?'), findsOneWidget);
      expect(find.text('재료 직접 추가'), findsOneWidget);
      memory._rows.addAll(
        List.generate(
          30,
          (i) => template.copyWith(id: 'many-$i', name: '재료 $i'),
        ),
      );
      memory.notifyListeners();
      await tester.pumpAndSettle();
      final last = find.byKey(const ValueKey('item-many-29'));
      await tester.scrollUntilVisible(
        last,
        400,
        maxScrolls: 50,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('filters start collapsed and preserve active state when closed', (
    tester,
  ) async {
    final (store, _) = await prepare(tester);
    await tester.pumpWidget(app(store));
    expect(find.byKey(const ValueKey('inventory-sort')), findsNothing);
    expect(find.byKey(const ValueKey('shelf-panel-shelf-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('inventory-organize-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shelf-panel-shelf-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inventory-organize-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inventory-view-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inventory-filter-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('expiry-unknown')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('필터 · 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inventory-filter-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('expiry-unknown')), findsNothing);
    expect(find.byTooltip('필터 · 1'), findsOneWidget);
    expect(store.history, isEmpty);
  });

  testWidgets(
    'search spans all storage and zero result can become shopping item',
    (tester) async {
      final (store, _) = await prepare(tester);
      String? shopping;
      await tester.pumpWidget(
        app(store, shopping: (value) => shopping = value),
      );
      await tester.tap(find.byKey(const ValueKey('inventory-search-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('inventory-search')),
        '만두',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('item-dumpling')), findsOneWidget);
      expect(find.byKey(const ValueKey('item-tofu')), findsNothing);
      expect(find.textContaining('날짜 미상'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('inventory-search')),
        '고구마',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('장보기 목록에 추가'));
      expect(shopping, '고구마');
      expect(store.history, isEmpty);
    },
  );

  testWidgets(
    'touch move cancellation preserves state; confirmation sends exact destination',
    (tester) async {
      final (store, _) = await prepare(tester);
      await tester.pumpWidget(app(store));
      await tester.tap(find.byKey(const ValueKey('inventory-organize-toggle')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('move-tofu')));
      expect(
        tester.getSize(find.byKey(const ValueKey('move-tofu'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byKey(const ValueKey('move-tofu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(store.batches.firstWhere((b) => b.id == 'tofu').shelfId, 'middle');
      expect(store.history, isEmpty);
      await tester.tap(find.byKey(const ValueKey('move-tofu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('move-storage')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('팬트리').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('move-shelf')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('위 선반').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인하고 이동'));
      await waitSaved(tester, store);
      final moved = store.batches.firstWhere((b) => b.id == 'tofu');
      expect(moved.storageType, StorageType.pantry);
      expect(moved.shelfId, 'shelf-1');
      expect(moved.quantity, 300);
      expect(store.history.single.action, 'move');
    },
  );

  test(
    'store move survives reopen with its history and quantity intact',
    () async {
      final dir = await Directory.systemTemp.createTemp('inventory_move_');
      final store = InventoryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${dir.path}/test.db',
      );
      try {
        await store.initialize();
        final tofu = store.batches.firstWhere((b) => b.id == 'tofu');
        await store.update(
          tofu.copyWith(
            storageType: StorageType.pantry,
            shelfId: 'shelf-1',
            slotId: null,
          ),
          source: 'drag',
          requestId: 'test-drag',
        );
        await store.close();
        await store.initialize();
        final saved = store.batches.firstWhere((b) => b.id == 'tofu');
        expect(saved.storageType, StorageType.pantry);
        expect(saved.shelfId, 'shelf-1');
        expect(saved.quantity, 300);
        expect(store.history.single.action, 'move');
        expect(store.history.single.source, 'drag');
      } finally {
        await store.close();
        store.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'invalid drop leaves state unchanged; valid tray drop saves once without confirmation',
    (tester) async {
      final (store, _) = await prepare(tester);
      await tester.pumpWidget(app(store));
      await tester.tap(find.byKey(const ValueKey('inventory-organize-toggle')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('drag-tofu')));
      var gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('item-tofu'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(const Offset(3, 3));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.history, isEmpty);
      expect(
        store.batches.firstWhere((b) => b.id == 'tofu').storageType,
        StorageType.fridge,
      );
      gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('item-tofu'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final target = find.byKey(const ValueKey('tray-freezer-shelf-3'));
      expect(target, findsOneWidget);
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await waitSaved(tester, store);
      expect(find.byType(AlertDialog), findsNothing);
      expect(store.history.length, 1);
      final moved = store.batches.firstWhere((b) => b.id == 'tofu');
      expect(moved.storageType, StorageType.freezer);
      expect(moved.shelfId, 'shelf-3');
      expect(moved.quantity, 300);
    },
  );

  testWidgets('small screen with large text keeps filters and search usable', (
    tester,
  ) async {
    final (store, _) = await prepare(tester);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpWidget(app(store, scale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('inventory-search-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('inventory-search')),
      '두부',
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('item-tofu')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });
}
