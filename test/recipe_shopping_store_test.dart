import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/shopping_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late InventoryStore stock;
  late ShoppingStore shopping;
  Recipe menu(String id, List<RecipeIngredient> ingredients) => Recipe(
    id: id,
    title: id,
    servings: 1,
    minutes: 10,
    ingredients: ingredients,
    steps: ['재료를 섞어요.'],
    source: 'demo',
    generatedAt: DateTime(2026, 11, 23),
  );
  Recipe tofu(String id, double kg) =>
      menu(id, [RecipeIngredient(name: '두부', quantity: kg, unit: 'kg')]);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    stock = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
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

  test(
    'preview and commit reuse aggregate shortages and omit manual quantities',
    () async {
      await stock.add(
        InventoryBatch(id: 'stock', name: '두부', quantity: 300, unit: 'g'),
      );
      await shopping.addManual('두부', quantity: 50, unit: 'g');
      await shopping.addRecipeToPlan(tofu('찌개', .2));
      final next = tofu('볶음', .25);
      final preview = shopping.previewRecipeShopping(next);
      expect(preview.amounts.single, (name: '두부', quantity: 150.0, unit: 'g'));
      expect(shopping.plans.single.recipes, hasLength(1));
      expect(shopping.items.single.quantity, 50);

      await stock.consume('stock', 100);
      final saved = await shopping.addRecipeToPlan(next, onlyIfMissing: true);
      expect(saved.amounts.single, (name: '두부', quantity: 250.0, unit: 'g'));
      expect(shopping.items.single.quantity, 300);
      await shopping.undoLast();
      expect(shopping.items.single.quantity, 50);
      expect(stock.batches.single.quantity, 200);
    },
  );

  test(
    'fully stocked or optional ingredients leave the previous undo intact',
    () async {
      await stock.add(
        InventoryBatch(id: 'tofu', name: '두부', quantity: 100, unit: 'g'),
      );
      await shopping.addManual('감자');
      final dinner = menu('저녁', const [
        RecipeIngredient(name: '두부', quantity: .1, unit: 'kg'),
        RecipeIngredient(name: '깨', quantity: null, unit: '', optional: true),
      ]);
      expect(shopping.previewRecipeShopping(dinner).hasMissing, isFalse);
      expect(
        (await shopping.addRecipeToPlan(
          dinner,
          onlyIfMissing: true,
        )).hasMissing,
        isFalse,
      );
      expect(shopping.plans, isEmpty);
      await shopping.undoLast();
      expect(shopping.items, isEmpty);
    },
  );

  test(
    'a confirmation checks the displayed amount inside the shared write queue',
    () async {
      await stock.add(
        InventoryBatch(id: 'stock', name: '두부', quantity: 100, unit: 'g'),
      );
      final dinner = tofu('전', .15);
      final expected = shopping.previewRecipeShopping(dinner);
      expect(expected.amounts.single.quantity, 50);
      final other = ShoppingStore(inventory: stock);
      addTearDown(other.dispose);
      await other.initialize();
      final first = other.addRecipeToPlan(tofu('국', .2));
      final pending = shopping.addRecipeToPlan(
        dinner,
        onlyIfMissing: true,
        expected: expected,
      );
      await first;
      final updated = await pending;
      expect(updated.matches(expected), isFalse);
      expect(updated.amounts.single.quantity, 150);
      expect(shopping.plans.single.recipes.map((r) => r.id), ['국']);
      final saved = await shopping.addRecipeToPlan(
        dinner,
        onlyIfMissing: true,
        expected: updated,
      );
      expect(saved.matches(updated), isTrue);
      expect(shopping.plans.single.recipes.map((r) => r.id), ['국', '전']);
    },
  );

  test('status stock and unquantified ingredients are reported without a guessed amount', () async {
    await stock.add(
      InventoryBatch(
        id: 'salt',
        name: '소금',
        quantity: 1,
        unit: 'g',
        quantityMode: QuantityMode.status,
        stockLevel: StockLevel.enough,
      ),
    );
    final dinner = menu('국', const [
      RecipeIngredient(name: '소금', quantity: 3, unit: 'g'),
      RecipeIngredient(name: '물', quantity: null, unit: 'ml'),
      RecipeIngredient(name: '후추', quantity: 2, unit: 'g', optional: true),
    ]);
    final preview = shopping.previewRecipeShopping(dinner);
    final saved = await shopping.addRecipeToPlan(dinner, onlyIfMissing: true);
    expect(preview.unknown, unorderedEquals(['소금', '물']));
    expect(saved.unknown, preview.unknown);
    expect(saved.amounts, isEmpty);
    await shopping.reload();
    expect(shopping.items.single.name, '소금');
    expect(shopping.items.single.quantity, isNull);
    expect(shopping.unquantifiedIngredients, unorderedEquals(['소금', '물']));
  });

  test('concurrent repeats and hidden rows survive retry and reload', () async {
    final other = ShoppingStore(inventory: stock);
    addTearDown(other.dispose);
    await other.initialize();
    final dinner = tofu('국', .1);
    final results = await Future.wait([
      shopping.addRecipeToPlan(dinner, onlyIfMissing: true),
      other.addRecipeToPlan(dinner, onlyIfMissing: true),
    ]);
    expect(results.where((r) => r.alreadyPlanned), hasLength(1));
    expect(results.where((r) => r.hasMissing), hasLength(1));
    await shopping.reload();
    expect(shopping.plans.single.recipes, hasLength(1));
    await shopping.removeItem(shopping.items.single.id);
    final repeat = await shopping.addRecipeToPlan(dinner, onlyIfMissing: true);
    expect(repeat.alreadyPlanned, isTrue);
    expect(shopping.items, isEmpty);
    await shopping.undoLast();
    expect(shopping.items.single.quantity, 100);
  });

  test('adding a different menu preserves unrelated hidden items and supports recipe revisions', () async {
    await shopping.addRecipeToPlan(tofu('국', .1));
    await shopping.removeItem(shopping.items.single.id);
    await shopping.addRecipeToPlan(
      menu('전', const [RecipeIngredient(name: '양파', quantity: 1, unit: '개')]),
      onlyIfMissing: true,
    );
    expect(shopping.items.map((item) => item.name), ['양파']);
    await shopping.addRecipeToPlan(tofu('국', .25));
    expect(
      shopping.items.firstWhere((item) => item.name == '두부').quantity,
      250,
    );
    expect(shopping.plans.single.recipes, hasLength(2));
  });
}
