import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/models/shopping.dart';
import 'package:my_fridge/screens/order_import_screen.dart';
import 'package:my_fridge/screens/shopping_screen.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/shopping_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final now = DateTime(2026, 11, 23);
  late InventoryStore stock;
  late ShoppingStore shopping;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    stock = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
      clock: () => now,
    );
    await stock.initialize();
    await stock.setDemoMode(false);
    shopping = ShoppingStore(inventory: stock);
    await shopping.initialize();
  });
  tearDown(() async {
    shopping.dispose();
    await stock.close();
    stock.dispose();
  });

  Future<List<ShoppingItem>> buyTofu(double quantity) async {
    await shopping.addManual('두부', quantity: quantity, unit: 'g');
    await shopping.setPurchased(shopping.items.single.id, true);
    return shopping.purchasedForIntake;
  }

  Future<String> receive(
    ShoppingItem item,
    double amount, {
    String? name,
  }) async {
    final batch = InventoryBatch(
      id: item.purchaseBatchId!,
      ingredientId: item.purchaseReference,
      name: name ?? item.name,
      quantity: amount,
      unit: item.unit.isEmpty ? '개' : item.unit,
    );
    await stock.addMany(
      [batch],
      source: 'shopping',
      requestId: 'intake_${batch.id}',
    );
    return stock.history
        .firstWhere((h) => h.requestId == 'intake_${batch.id}')
        .id;
  }

  Recipe plan(String name, double amount) => Recipe(
    id: 'dinner',
    title: '저녁',
    source: 'demo',
    servings: 1,
    minutes: 10,
    ingredients: [RecipeIngredient(name: name, quantity: amount, unit: 'g')],
    steps: ['조리'],
    generatedAt: now,
  );

  test('closed purchases start fresh and retries and shopping undo cannot duplicate inventory', () async {
    final first = await buyTofu(200);
    final change = await receive(first.single, 200);
    expect(shopping.canUndo, isFalse);
    await expectLater(shopping.undoLast(), throwsStateError);
    // SQLite completed; the app can restart before the preferences update.
    await shopping.reload();
    expect(shopping.purchasedForIntake, isEmpty);
    expect(shopping.items.single.intakeLinked, isTrue);
    await shopping.markPurchasedIntakeLinked(first, change);
    await shopping.markPurchasedIntakeLinked(first, change);
    await shopping.setPurchased(first.single.id, true);
    await expectLater(
      shopping.setPurchased(first.single.id, false),
      throwsStateError,
    );
    expect(shopping.purchasedForIntake, isEmpty);
    final again = await buyTofu(100);
    expect(again.single.quantity, 100);
    expect(
      again.single.purchaseReference,
      isNot(first.single.purchaseReference),
    );
    final newChange = await receive(again.single, 100);
    await shopping.markPurchasedIntakeLinked(again, newChange);
    expect(stock.batches.fold(0.0, (s, b) => s + b.quantity), 300);
  });

  test(
    'an independent shopping edit can still be undone after a receipt',
    () async {
      final tofu = (await buyTofu(200)).single;
      await shopping.addManual('대파', quantity: 1, unit: '개');
      await receive(tofu, 200);
      expect(shopping.canUndo, isTrue);
      await shopping.undoLast();
      expect(shopping.items.single.name, '두부');
      expect(shopping.items.single.intakeLinked, isTrue);
      expect(stock.batches.single.quantity, 200);
    },
  );

  test('a checked row in an older v2 list can explicitly link its original untagged intake', () async {
    final id = shoppingKeyFor('두부', 'g');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      shopping.storageKey,
      jsonEncode({
        'version': 2,
        'manual': [
          {'name': '두부', 'quantity': 200, 'unit': 'g'},
        ],
        'plans': [],
        'purchased': [id],
      }),
    );
    await shopping.reload();
    expect(shopping.purchasedForIntake.single.quantity, 200);
    await stock.addMany([
      InventoryBatch(
        id: 'purchase-123-0',
        name: '두부',
        quantity: 150,
        unit: 'g',
      ),
    ], source: 'shopping');
    final previous = stock.history.first.id;
    expect(shopping.purchasedForIntake.single.quantity, 200);
    expect(shopping.linkableIntakes(shopping.items.single).single.id, previous);
    await shopping.markIntakeLinked(id, previous);
    expect(shopping.purchasedForIntake.single.quantity, 50);
  });

  test('a partially received manual purchase carries only its outstanding quantity into a new request', () async {
    final original = await buyTofu(200);
    final change = await receive(original.single, 120);
    await shopping.markPurchasedIntakeLinked(original, change);
    await shopping.addManual('두부', quantity: 50, unit: 'g');
    expect(shopping.items.single.quantity, 130);
    expect(shopping.items.single.purchased, isFalse);
  });

  test('a manual receipt links against the purchased amount and undo restores only that installment', () async {
    await shopping.addRecipeToPlan(plan('두부', 200));
    final id = shopping.items.single.id;
    await shopping.setPurchased(id, true);
    await stock.add(
      InventoryBatch(id: 'first', name: '두부', quantity: .1, unit: 'kg'),
    );
    final first = stock.history.first.id;
    expect(shopping.items.single.quantity, 100);
    await shopping.markIntakeLinked(id, first);
    await shopping.markIntakeLinked(id, first);
    expect(shopping.purchasedForIntake.single.quantity, 100);
    expect(shopping.canUndo, isFalse);
    expect(shopping.linkableIntakes(shopping.items.single), isEmpty);
    await stock.add(
      InventoryBatch(id: 'second', name: '두부', quantity: 100, unit: 'g'),
    );
    final second = stock.history.first.id;
    await shopping.markIntakeLinked(id, second);
    expect(shopping.items, isEmpty);
    await stock.undo(second);
    expect(shopping.purchasedForIntake.single.quantity, 100);
    expect(shopping.items.single.intakeChangeId, first);
  });

  test('only selected purchase identities receive credit, including duplicate ingredient names', () async {
    await shopping.addManual('두부');
    await shopping.addManual('두부', quantity: 2, unit: '팩');
    for (final item in shopping.items) {
      await shopping.setPurchased(item.id, true);
    }
    final originals = shopping.purchasedForIntake;
    final measured = originals.singleWhere((i) => i.unit == '팩');
    final change = await receive(measured, 2);
    await shopping.markPurchasedIntakeLinked(originals, change);
    final unknown = shopping.purchasedForIntake.single;
    expect(unknown.unit, '');
    expect(
      shopping.items.singleWhere((i) => i.unit == '팩').intakeLinked,
      isTrue,
    );
    await stock.addMany([
      InventoryBatch(id: 'manually-added', name: '두부', quantity: 1, unit: '개'),
    ], source: 'shopping');
    await shopping.markPurchasedIntakeLinked([unknown], stock.history.first.id);
    expect(shopping.purchasedForIntake.single.id, unknown.id);
    expect(shopping.linkableIntakes(unknown), isEmpty);
  });

  test('a partial purchase can be explicitly approved again after undo without reusing its prior request', () async {
    final first = (await buyTofu(200)).single;
    final snapshot = shopping.purchasedForIntake.single;
    expect(first.purchaseBatchId, snapshot.purchaseBatchId);
    final event = await receive(first, 100);
    final rest = shopping.purchasedForIntake.single;
    expect(rest.quantity, 100);
    expect(rest.purchaseBatchId, isNot(first.purchaseBatchId));
    await receive(snapshot, 100);
    expect(stock.history.where((h) => h.action == 'add'), hasLength(1));
    await stock.undo(event);
    final fresh = shopping.purchasedForIntake.single;
    expect(fresh.quantity, 200);
    expect(fresh.purchaseBatchId, isNot(first.purchaseBatchId));
    await receive(fresh, 200);
    expect(shopping.purchasedForIntake, isEmpty);
    expect(stock.batches.single.quantity, 200);
  });

  test('legacy full links remain complete and their recorded amount is not included in a new purchase', () async {
    final id = shoppingKeyFor('두부', 'g');
    await stock.add(
      InventoryBatch(id: 'legacy', name: '두부', quantity: 200, unit: 'g'),
    );
    final old = stock.history.first.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      shopping.storageKey,
      jsonEncode({
        'version': 2,
        'plans': [],
        'manual': [
          {'name': '두부', 'quantity': 200, 'unit': 'g'},
        ],
        'purchased': [id],
        'purchaseAmounts': {id: 200},
        'intakeLinks': {id: old},
      }),
    );
    await shopping.reload();
    expect(shopping.items.single.intakeLinked, isTrue);
    final next = (await buyTofu(50)).single;
    expect(next.quantity, 50);
    expect(shopping.linkableIntakes(next), isEmpty);
    await expectLater(shopping.markIntakeLinked(id, old), throwsStateError);
  });

  test('order totals and explicit reapprovals follow active receipts when a partial delivery is undone', () async {
    final order = parseOrderJson(sampleOrder);
    final line = order.lines.first;
    for (final other in order.lines.skip(1)) {
      other.selected = false;
    }
    Future<String> approve() async {
      final batches = buildOrderAdmission(order, stock.history, now: now);
      expect(batches, hasLength(1));
      final key = orderApprovalId(batches);
      expect(
        orderApprovalId(buildOrderAdmission(order, stock.history, now: now)),
        key,
      );
      await stock.addMany(batches, source: 'order', requestId: key);
      await stock.addMany(batches, source: 'order', requestId: key);
      return stock.history.firstWhere((h) => h.requestId == key).id;
    }

    final first = await approve();
    await stock.undo(first);
    expect(admittedOrderQuantity(order, line, stock.history), 0);
    final reapproved = await approve();
    expect(reapproved, isNot(first));
    expect(admittedOrderQuantity(order, line, stock.history), 1);
    line.received = 2;
    final second = await approve();
    expect(admittedOrderQuantity(order, line, stock.history), 2);
    await stock.undo(second);
    expect(admittedOrderQuantity(order, line, stock.history), 1);
    final replaced = await approve();
    expect(replaced, isNot(second));
    expect(stock.batches.fold(0.0, (s, b) => s + b.quantity), 2);
    expect(buildOrderAdmission(order, stock.history), isEmpty);
  });

  testWidgets(
    'expired measured and status stock are excluded and visible for inspection; shopping actions stay usable',
    (tester) async {
      await tester.runAsync(() async {
        for (final mode in QuantityMode.values) {
          await stock.add(
            InventoryBatch(
              id: mode.name,
              name: '두부',
              quantity: 300,
              unit: 'g',
              quantityMode: mode,
              expiryDate: now.subtract(const Duration(days: 1)),
              expiryStatus: ExpiryStatus.actual,
            ),
          );
        }
        await stock.add(
          InventoryBatch(
            id: 'today',
            name: '두부',
            quantity: 25,
            unit: 'g',
            expiryDate: now,
            expiryStatus: ExpiryStatus.actual,
          ),
        );
        await shopping.addRecipeToPlan(plan('두부', 200));
      });
      expect(shopping.items.single.quantity, 175);
      expect(shopping.unquantifiedIngredients, isEmpty);
      expect(shopping.expiredPlanBatches, hasLength(2));
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShoppingScreen(store: stock, onIntake: () => opened = true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('표시 기한이 지난 재고 확인'));
      await tester.tap(find.text('표시 기한이 지난 재고 확인'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1일 지남'), findsNWidgets(2));
      final checkbox = find.widgetWithText(CheckboxListTile, '두부 · 175g');
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      final action = find.widgetWithText(OutlinedButton, '구매한 재료 입고하기');
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
