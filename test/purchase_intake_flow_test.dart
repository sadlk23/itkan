import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/screens/intake_screen.dart';
import 'package:my_fridge/screens/batch_form.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/shopping_store.dart';

// UI integration fixture; real SQLite transactions are covered by store tests.
class _Inventory extends InventoryStore {
  final rows = <InventoryBatch>[];
  final changes = <InventoryChange>[];
  @override
  bool get isDemo => false;
  @override
  List<InventoryBatch> get batches => List.unmodifiable(rows);
  @override
  List<InventoryBatch> get activeBatches =>
      rows.where((b) => b.active).toList();
  @override
  List<InventoryChange> get history => List.unmodifiable(changes);
  @override
  Future<Set<String>> referencedPhotoFiles() async => {};
  @override
  Future<void> close() async {}
  @override
  Future<void> addMany(
    List<InventoryBatch> batches, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) async {
    rows.addAll(batches);
    changes.insert(
      0,
      InventoryChange(
        id: 'saved-${changes.length}',
        label: '입고',
        createdAt: DateTime(2026),
        before: [],
        after: List.of(batches),
        action: 'add',
        source: source,
        requestId: requestId,
      ),
    );
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InventoryStore store;
  late ShoppingStore shopping;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'kitchen_visited': true});
    store = _Inventory();
    shopping = ShoppingStore(inventory: store);
    await shopping.initialize();
  });
  tearDown(() async {
    shopping.dispose();
    await store.close();
    store.dispose();
  });
  Future<void> enter(WidgetTester tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('장보기'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('구매한 재료 입고하기'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('구매한 재료 입고하기'));
    await tester.pumpAndSettle();
    expect(find.byType(CandidateScreen), findsOneWidget);
  }

  Future<void> approve(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.text('선택한 1개 항목 입고'));
    await tester.pumpAndSettle();
    expect(store.batches, isEmpty);
    await tester.tap(find.text('확인하고 입고'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'home purchase candidates preserve known quantities and link only approved subset',
    (tester) async {
      await shopping.addManual('두부', quantity: 200, unit: 'g');
      await shopping.addManual('우유', quantity: 500, unit: 'ml');
      for (final item in shopping.items) {
        await shopping.setPurchased(item.id, true);
      }
      await enter(tester);
      final screen = tester.widget<CandidateScreen>(
        find.byType(CandidateScreen),
      );
      expect(
        screen.candidates!
            .firstWhere((c) => c.batch.name == '두부')
            .batch
            .quantity,
        200,
      );
      expect(
        screen.candidates!
            .firstWhere((c) => c.batch.name == '우유')
            .batch
            .quantity,
        500,
      );
      await tester.tap(find.widgetWithText(CheckboxListTile, '두부'));
      await approve(tester);
      expect(find.byType(CandidateScreen), findsNothing);
      expect(store.batches.single.name, '두부');
      expect(store.batches.single.quantity, 200);
      await shopping.reload();
      expect(
        shopping.items.firstWhere((i) => i.name == '두부').intakeLinked,
        isTrue,
      );
      expect(
        shopping.items.firstWhere((i) => i.name == '우유').intakeLinked,
        isFalse,
      );
      await close(tester);
    },
  );

  testWidgets(
    'approving one of two same-name candidates leaves the other purchase open',
    (tester) async {
      await shopping.addManual('두부');
      await shopping.addManual('두부', quantity: 2, unit: '팩');
      for (final item in shopping.items) {
        await shopping.setPurchased(item.id, true);
      }
      await enter(tester);
      final selectable = find.byWidgetPredicate(
        (w) =>
            w is CheckboxListTile &&
            w.title is Text &&
            (w.title! as Text).data == '두부' &&
            w.onChanged != null,
      );
      expect(selectable, findsOneWidget);
      await tester.tap(selectable);
      await approve(tester);
      expect(store.batches.single.quantity, 2);
      expect(store.batches.single.unit, '팩');
      await shopping.reload();
      final pending = shopping.purchasedForIntake.single;
      expect(pending.name, '두부');
      expect(pending.quantity, isNull);
      expect(
        shopping.items.singleWhere((i) => i.unit == '팩').intakeLinked,
        isTrue,
      );
      await close(tester);
    },
  );

  testWidgets('unknown purchase cannot be selected until quantity is edited', (
    tester,
  ) async {
    await shopping.addManual('양파');
    await shopping.setPurchased(shopping.items.single.id, true);
    await enter(tester);
    expect(
      tester
          .widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, '양파'))
          .onChanged,
      isNull,
    );
    await tester.tap(find.text('항목 수정'));
    await tester.pumpAndSettle();
    expect(find.byType(BatchForm), findsOneWidget);
    final quantity = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '수량',
    );
    await tester.enterText(quantity, '2');
    await tester.scrollUntilVisible(
      find.text('후보 수정 완료'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(BatchForm),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('후보 수정 완료'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, '양파'));
    await approve(tester);
    expect(store.batches.single.quantity, 2);
    await shopping.reload();
    expect(shopping.items.single.intakeLinked, isTrue);
    await close(tester);
  });

  testWidgets(
    'leaving purchase candidate warns and cancellation creates no inventory or links',
    (tester) async {
      await shopping.addManual('두부', quantity: 200, unit: 'g');
      await shopping.setPurchased(shopping.items.single.id, true);
      await enter(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('입고 확인을 나갈까요?'), findsOneWidget);
      await tester.tap(find.text('나가기'));
      await tester.pumpAndSettle();
      expect(find.byType(CandidateScreen), findsNothing);
      expect(store.batches, isEmpty);
      await shopping.reload();
      expect(shopping.items.single.intakeLinked, isFalse);
      await close(tester);
    },
  );
}
