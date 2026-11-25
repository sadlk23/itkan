import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/widgets/inventory_browser.dart';

class _StateStore extends InventoryStore {
  _StateStore(this.rows);
  final List<InventoryBatch> rows;
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _StateStore store, {
    VoidCallback? onAdd,
    ValueChanged<InventoryBatch>? onSelect,
  }) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: FridgeTheme.light,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: Scaffold(
              body: InventoryBrowser(
                store: store,
                onOpen: (_) {},
                onAdd: onAdd ?? () {},
                selecting: onSelect != null,
                onToggleSelection: onSelect,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty inventory permits adding at 320dp and 200 percent text', (
    tester,
  ) async {
    var adds = 0;
    await mount(tester, _StateStore([]), onAdd: () => adds++);
    final add = find.widgetWithText(FilledButton, '재료 직접 추가');
    await tester.scrollUntilVisible(
      add,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(add);
    expect(adds, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one long homemade name retains estimated date at large text', (
    tester,
  ) async {
    final item = InventoryBatch(
      id: 'single',
      name: '엄마가 만들어 주신 이름이 긴 특별한 반찬',
      quantity: 1,
      unit: '통',
      category: '반찬',
      expiryStatus: ExpiryStatus.estimated,
      expiryDate: DateTime.now().add(const Duration(days: 4)),
    );
    await mount(tester, _StateStore([item]));
    await tester.scrollUntilVisible(
      find.text(item.expiryLabel()),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(item.name), findsOneWidget);
    expect(find.text(item.quantityLabel), findsOneWidget);
    expect(find.text(item.expiryLabel()), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'twenty items remain reachable and selection does not rewrite placement',
    (tester) async {
      final now = DateTime.now();
      final rows = List.generate(
        20,
        (i) => InventoryBatch(
          id: 'large-$i',
          name: '직접 만든 음식 $i',
          quantity: 1,
          unit: '통',
          shelfId: 'shelf-${i % 3 + 1}',
          expiryStatus: i % 4 == 0
              ? ExpiryStatus.unknown
              : i % 4 == 1
              ? ExpiryStatus.estimated
              : ExpiryStatus.actual,
          expiryDate: i % 4 == 0 ? null : now.add(Duration(days: i - 3)),
        ),
      );
      final snapshots = rows.map((b) => b.toJson()).toList();
      final selected = <String>{};
      await mount(
        tester,
        _StateStore(rows),
        onSelect: (b) => selected.add(b.id),
      );
      final target = find.byKey(const ValueKey('item-large-17'));
      await tester.scrollUntilVisible(
        target,
        350,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
      // Lazy slivers may correct their estimated extent after the target is
      // mounted. Settle that layout, then bring its tap centre into view.
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(target), alignment: .5);
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(selected, {'large-17'});
      expect(rows.map((b) => b.toJson()).toList(), snapshots);
      expect(tester.takeException(), isNull);
    },
  );
}
