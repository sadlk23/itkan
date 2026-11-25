import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/models/shopping.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/shopping_store.dart';
import 'package:my_fridge/screens/shopping_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late InventoryStore inventory;
  late ShoppingStore shopping;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    inventory = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await inventory.initialize();
    await inventory.setDemoMode(false);
    shopping = ShoppingStore(inventory: inventory);
    await shopping.initialize();
  });
  tearDown(() async {
    shopping.dispose();
    await inventory.close();
    inventory.dispose();
  });
  Recipe recipe(String name, double quantity) => Recipe(
    id: 'plan',
    title: '저녁',
    source: 'demo',
    servings: 1,
    minutes: 10,
    ingredients: [RecipeIngredient(name: name, quantity: quantity, unit: 'g')],
    steps: ['조리'],
    generatedAt: DateTime(2026),
  );

  test('purchase amount is rechecked when external stock raises shortage and survives reload', () async {
    await inventory.add(
      InventoryBatch(id: 'tofu', name: '두부', quantity: 300, unit: 'g'),
    );
    await shopping.addRecipeToPlan(recipe('두부', 500));
    await shopping.setPurchased(shopping.items.single.id, true);
    expect(shopping.items.single.purchased, isTrue);
    await inventory.consume('tofu', 200);
    expect(shopping.items.single.quantity, 400);
    expect(shopping.items.single.purchased, isFalse);
    await shopping.reload();
    expect(shopping.items.single.purchased, isFalse);
    await shopping.setPurchased(shopping.items.single.id, true);
    expect(shopping.items.single.purchased, isTrue);
    expect(inventory.batches.single.quantity, 100);
  });

  test(
    'intake retains purchased amount when later stock reduces shortage',
    () async {
      await inventory.add(
        InventoryBatch(id: 'tofu', name: '두부', quantity: 300, unit: 'g'),
      );
      await shopping.addRecipeToPlan(recipe('두부', 500));
      await shopping.setPurchased(shopping.items.single.id, true);
      await inventory.add(
        InventoryBatch(id: 'other', name: '두부', quantity: 100, unit: 'g'),
      );
      expect(shopping.items.single.quantity, 100);
      expect(shopping.items.single.purchased, isTrue);
      final originals = shopping.purchasedForIntake;
      expect(originals.single.quantity, 200);
      await inventory.add(
        InventoryBatch(id: 'purchased', name: '두부', quantity: 200, unit: 'g'),
      );
      await shopping.markPurchasedIntakeLinked(
        originals,
        inventory.history.first.id,
      );
      expect(shopping.purchasedForIntake, isEmpty);
    },
  );

  test(
    'status stock remains unknown rather than a definite full shortage',
    () async {
      await inventory.add(
        InventoryBatch(
          id: 'salt',
          name: '소금',
          quantity: 1,
          unit: 'g',
          quantityMode: QuantityMode.status,
          stockLevel: StockLevel.enough,
        ),
      );
      await shopping.addRecipeToPlan(recipe('소금', 5));
      expect(shopping.items.single.quantity, isNull);
      expect(shopping.items.single.planQuantity, 0);
      expect(shopping.unquantifiedIngredients, contains('소금'));
    },
  );

  test(
    'purchase intake links confirmed manual rows and does not duplicate stock',
    () async {
      await shopping.addManual('두부', quantity: 200, unit: 'g');
      await shopping.setPurchased(shopping.items.single.id, true);
      final originals = shopping.items;
      await inventory.add(
        InventoryBatch(id: 'purchase', name: '두부', quantity: 200, unit: 'g'),
      );
      await shopping.markPurchasedIntakeLinked(
        originals,
        inventory.history.first.id,
      );
      expect(shopping.items.single.intakeLinked, isTrue);
      await shopping.markPurchasedIntakeLinked(
        originals,
        inventory.history.first.id,
      );
      expect(inventory.batches.single.quantity, 200);
    },
  );

  test('plan intake can link when new stock removes shortage row', () async {
    await shopping.addRecipeToPlan(recipe('두부', 200));
    await shopping.setPurchased(shopping.items.single.id, true);
    final originals = shopping.items;
    await inventory.add(
      InventoryBatch(id: 'purchase', name: '두부', quantity: 200, unit: 'g'),
    );
    expect(shopping.purchasedForIntake.single.quantity, 200);
    await shopping.markPurchasedIntakeLinked(
      originals,
      inventory.history.first.id,
    );
    expect(shopping.items, isEmpty);
    expect(inventory.history.length, 1);
  });

  test(
    'partial or renamed intake does not mark full purchase as linked',
    () async {
      await shopping.addManual('두부', quantity: 200, unit: 'g');
      await shopping.setPurchased(shopping.items.single.id, true);
      final originals = shopping.items;
      await inventory.add(
        InventoryBatch(id: 'partial', name: '두부', quantity: 100, unit: 'g'),
      );
      await shopping.markPurchasedIntakeLinked(
        originals,
        inventory.history.first.id,
      );
      expect(shopping.items.single.intakeLinked, isFalse);
      expect(inventory.batches.single.quantity, 100);
      expect(shopping.purchasedForIntake.single.quantity, 100);
      final firstChange = inventory.history.first.id;
      await shopping.markPurchasedIntakeLinked(originals, firstChange);
      expect(shopping.purchasedForIntake.single.quantity, 100);
      final remaining = shopping.purchasedForIntake;
      await inventory.add(
        InventoryBatch(id: 'remainder', name: '두부', quantity: 100, unit: 'g'),
      );
      final secondChange = inventory.history.first.id;
      await shopping.markPurchasedIntakeLinked(remaining, secondChange);
      expect(shopping.items.single.intakeLinked, isTrue);
      expect(shopping.purchasedForIntake, isEmpty);
      await inventory.undo(secondChange);
      await shopping.reload();
      expect(shopping.items.single.intakeLinked, isFalse);
      expect(shopping.purchasedForIntake.single.quantity, 100);
    },
  );

  testWidgets(
    'purchase intake forwards selected names and quantities without committing on cancel',
    (tester) async {
      await shopping.addManual('두부', quantity: 200, unit: 'g');
      await shopping.setPurchased(shopping.items.single.id, true);
      List<ShoppingItem>? received;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShoppingScreen(
              store: inventory,
              onIntake: () => fail('generic intake must not run'),
              onPurchasedIntake: (items) async {
                received = items;
                return null;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(CheckboxListTile, '두부 · 200g'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('구매한 재료 입고하기'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('구매한 재료 입고하기'));
      await tester.pumpAndSettle();
      expect(received!.single.name, '두부');
      expect(received!.single.quantity, 200);
      expect(inventory.batches, isEmpty);
      expect(shopping.items.single.intakeLinked, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
