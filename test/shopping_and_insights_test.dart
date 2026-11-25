import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/shopping_store.dart';
import 'package:my_fridge/screens/insights_screen.dart';
import 'package:my_fridge/screens/shopping_screen.dart';
import 'package:my_fridge/screens/order_import_screen.dart';
import 'package:my_fridge/design/app_theme.dart';

void main() {
  sqfliteFfiInit();
  late InventoryStore inventory;
  late ShoppingStore shopping;
  final now = DateTime(2026, 11, 6, 10);
  Recipe recipe(String id, double amount, {String unit = 'g'}) => Recipe(
    id: id,
    title: '메뉴 $id',
    source: 'demo',
    servings: 1,
    minutes: 10,
    ingredients: [RecipeIngredient(name: '두부', quantity: amount, unit: unit)],
    steps: ['조리'],
    generatedAt: now,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    inventory = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
      clock: () => now,
    );
    await inventory.initialize();
    shopping = ShoppingStore(inventory: inventory);
    await shopping.initialize();
  });
  tearDown(() async {
    shopping.dispose();
    await inventory.close();
    inventory.dispose();
  });

  test(
    'selected menus sum need before allocating inventory once; resend replaces',
    () async {
      await shopping.addManual('두부', quantity: 50, unit: 'g');
      await shopping.addRecipeToPlan(recipe('one', 200));
      await shopping.addRecipeToPlan(recipe('two', .25, unit: 'kg'));
      expect(shopping.items.single.quantity, 200);
      expect(shopping.items.single.planQuantity, 150);
      expect(shopping.items.single.manualQuantity, 50);
      await shopping.addRecipeToPlan(recipe('two', .25, unit: 'kg'));
      expect(shopping.items.single.quantity, 200);
      await shopping.removePlan('next-meals');
      expect(shopping.items.single.quantity, 50);
      expect(shopping.items.single.planQuantity, 0);
    },
  );
  test(
    'incompatible units remain distinct and purchase does not add inventory',
    () async {
      await shopping.addManual('두부', quantity: 1, unit: '팩');
      await shopping.addRecipeToPlan(recipe('one', 500));
      expect(shopping.items.length, 2);
      final row = shopping.items.first;
      await shopping.setPurchased(row.id, true);
      expect(shopping.items.first.purchased, true);
      expect(inventory.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
      expect(inventory.history, isEmpty);
    },
  );
  test(
    'legacy checked list migrates and personal clear does not touch demo',
    () async {
      final p = await SharedPreferences.getInstance();
      await p.remove(shopping.storageKey);
      await p.setString(
        'shopping_demo',
        jsonEncode([
          {'name': '쌀', 'checked': true},
        ]),
      );
      await shopping.reload();
      expect(shopping.items.single.name, '쌀');
      expect(shopping.items.single.purchased, true);
      expect(shopping.items.single.quantity, isNull);
      await inventory.setDemoMode(false);
      await shopping.reload();
      expect(shopping.items, isEmpty);
      await shopping.addManual('양파', quantity: 2, unit: '개');
      await shopping.clear();
      expect(shopping.items, isEmpty);
      await inventory.setDemoMode(true);
      await shopping.reload();
      expect(shopping.items.single.name, '쌀');
    },
  );
  test(
    'shopping undo rejects subsequent changes from another instance',
    () async {
      await shopping.addManual('양파', quantity: 2, unit: '개');
      final other = ShoppingStore(inventory: inventory);
      await other.initialize();
      await other.addManual('당근', quantity: 1, unit: '개');
      await expectLater(shopping.undoLast(), throwsStateError);
      await shopping.reload();
      expect(shopping.items.length, 2);
      await shopping.addManual('대파', quantity: 1, unit: '개');
      await shopping.undoLast();
      expect(shopping.items.length, 2);
      other.dispose();
    },
  );
  test(
    'consumption groups compatible units and excludes reverted waste',
    () async {
      await inventory.consume('tofu', 50);
      await inventory.consume('tofu', 20, discard: true);
      await inventory.consume('tofu', 30, discard: true);
      var totals = calculateConsumption(inventory.history, now: now);
      expect(totals.single.consumed, 50);
      expect(totals.single.wasted, 50);
      expect(totals.single.wasteEvents, 2);
      await inventory.undo(inventory.history.first.id);
      totals = calculateConsumption(inventory.history, now: now);
      expect(totals.single.wasted, 20);
      expect(totals.single.wasteEvents, 1);
    },
  );
  test('revision guard rejects stale approved consumption', () async {
    final snapshot = inventory.batches.firstWhere((b) => b.id == 'tofu');
    await inventory.consume('tofu', 10);
    await expectLater(
      inventory.consume('tofu', 50, expectedRevision: snapshot.revision),
      throwsStateError,
    );
    expect(inventory.batches.firstWhere((b) => b.id == 'tofu').quantity, 290);
  });
  test('order parsing excludes sensitive raw fields; uncertain line blocks approval', () {
    final order = parseOrderJson(
      '{"orderId":"SECRET-123","address":"secret home","phone":"secret phone","status":"delivered","items":[{"name":"우유","unit":"팩"}]}',
    );
    final saved = jsonEncode(order.toJson());
    expect(saved.contains('SECRET-123'), false);
    expect(saved.contains('secret home'), false);
    expect(saved.contains('secret phone'), false);
    expect(() => buildOrderAdmission(order, []), throwsArgumentError);
  });
  test('partial delivery admits only new cumulative amount and ignores cancelled items', () async {
    final order = parseOrderJson(sampleOrder);
    order.lines[1].selected = false;
    var batches = buildOrderAdmission(order, inventory.history, now: now);
    expect(batches.length, 1);
    expect(batches.single.quantity, 1);
    await inventory.addMany(
      batches,
      source: 'order',
      requestId: orderApprovalId(batches),
    );
    expect(buildOrderAdmission(order, inventory.history), isEmpty);
    order.lines.first.received = 2;
    batches = buildOrderAdmission(order, inventory.history, now: now);
    expect(batches.single.quantity, 1);
    await inventory.addMany(
      batches,
      source: 'order',
      requestId: orderApprovalId(batches),
    );
    expect(
      admittedOrderQuantity(order, order.lines.first, inventory.history),
      2,
    );
    expect(buildOrderAdmission(order, inventory.history), isEmpty);
    order.status = 'cancelled';
    expect(
      () => buildOrderAdmission(order, inventory.history),
      throwsStateError,
    );
  });
  test(
    'intake link records a real admission and invalidates after undo',
    () async {
      await shopping.addManual('양파', quantity: 2, unit: '개');
      final id = shopping.items.single.id;
      await expectLater(
        shopping.markIntakeLinked(id, 'missing-change'),
        throwsStateError,
      );
      await inventory.add(
        InventoryBatch(id: 'onion', name: '양파', quantity: 2, unit: '개'),
      );
      final changeId = inventory.history.first.id;
      await shopping.markIntakeLinked(id, changeId);
      expect(shopping.items.single.intakeLinked, true);
      expect(shopping.items.single.intakeChangeId, changeId);
      await shopping.reload();
      expect(shopping.items.single.intakeChangeId, changeId);
      await inventory.undo(changeId);
      expect(shopping.items.single.intakeLinked, false);
    },
  );

  test('explicit zero delivery never admits the ordered amount', () {
    final order = parseOrderJson(
      '{"orderId":"zero","status":"delivered","items":[{"name":"우유","quantity":2,"deliveredQuantity":0,"unit":"팩"}]}',
    );
    expect(order.lines.single.received, 0);
    expect(buildOrderAdmission(order, []), isEmpty);
    final invalid = parseOrderJson(
      '{"orderId":"invalid","status":"delivered","items":[{"name":"우유","quantity":2,"deliveredQuantity":-1,"unit":"팩"}]}',
    );
    expect(invalid.lines.single.received, isNull);
    expect(() => buildOrderAdmission(invalid, []), throwsArgumentError);
  });

  test('order identity survives source channel and item order changes', () {
    const first =
        '{"orderId":"A123","status":"delivered","items":[{"name":"우유","quantity":1,"unit":"팩"},{"name":"두부","quantity":1,"unit":"개"}]}';
    const second =
        '{"orderId":"A123","status":"delivered","items":[{"name":"두부","quantity":1,"unit":"개"},{"name":"우유","quantity":1,"unit":"팩"}]}';
    final a = parseOrderJson(first, source: '샘플 이메일'),
        b = parseOrderJson(second, source: '샘플 알림');
    expect(a.id, b.id);
    expect(a.lines.first.id, b.lines.last.id);
    expect(
      () => parseOrderJson('{"phone":"private-value"'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.toString(),
          'no raw private payload',
          isNot(contains('private-value')),
        ),
      ),
    );
  });

  testWidgets('shopping and order screens fit a 390 pixel viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: FridgeTheme.light,
        home: Scaffold(
          body: ShoppingScreen(store: inventory, onIntake: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        theme: FridgeTheme.light,
        home: OrderImportScreen(store: inventory),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('샘플 주문 불러오기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('검토 대기함'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => inventory.setDemoMode(false));
    await tester.pumpAndSettle();
    expect(find.textContaining('이전 모드의 후보는 입고하지 않습니다'), findsOneWidget);
    expect(find.text('선택 항목 입고 확인'), findsNothing);
    expect(inventory.history, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
