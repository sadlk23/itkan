import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/main.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/screens/intake_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Inventory extends InventoryStore {
  final rows = List.generate(
    18,
    (i) => InventoryBatch(
      id: 'row-$i',
      name: '재료 $i',
      quantity: 1,
      unit: '개',
      expiryStatus: ExpiryStatus.actual,
      expiryDate: DateTime(2040, 1, i + 1),
    ),
  );
  @override
  bool get isInitialized => true;
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  for (final size in [const Size(320, 568), const Size(640, 360)]) {
    testWidgets('at 200% the last summary row can be reached on $size', (
      t,
    ) async {
      SharedPreferences.setMockInitialValues({'kitchen_visited': true});
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final store = _Inventory();
      addTearDown(store.dispose);
      await t.pumpWidget(FridgeApp(store: store));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('냉장고 요약'));
      await t.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      final scroll = find
          .descendant(of: sheet, matching: find.byType(Scrollable))
          .first;
      final last = find.descendant(of: sheet, matching: find.text('재료 17'));
      await t.scrollUntilVisible(last, 130, scrollable: scroll, maxScrolls: 90);
      await t.pumpAndSettle();
      final state = t.state<ScrollableState>(scroll);
      state.position.jumpTo(state.position.maxScrollExtent);
      await t.pumpAndSettle();
      final viewport = t.getRect(scroll);
      final row = t.getRect(last);
      expect(viewport.contains(row.center), isTrue,
          reason: 'Final row $row is outside the viewport $viewport');
      await t.tap(last);
      await t.pumpAndSettle();
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('soy exclusion applies when browsing sample recipes', (t) async {
    SharedPreferences.setMockInitialValues({
      'kitchen_visited': true,
      'allergies': <String>['대두'],
    });
    final store = _Inventory();
    addTearDown(store.dispose);
    t.view.physicalSize = const Size(800, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(MaterialApp(home: HomeScreen(store: store)));
    await t.pumpAndSettle();
    await t.tap(
      find
          .descendant(
            of: find.byType(NavigationBar),
            matching: find.text('AI 요리'),
          )
          .last,
    );
    await t.pumpAndSettle();
    final browse = find.text('예시 레시피 둘러보기');
    await t.ensureVisible(browse);
    await t.tap(browse);
    await t.pumpAndSettle();
    final excluded = AiService.demoRecipes.where(
      (r) => AiService.hasDeclaredAllergen(r, ['대두']),
    );
    expect(excluded, isNotEmpty);
    for (final recipe in excluded) {
      expect(find.text(recipe.title), findsNothing);
    }
    expect(find.text('제외 성분 설정에 맞는 예시 레시피가 없어요.'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });
  test('local intake separates each quantity, uses the chosen storage, and rejects ambiguous lists', () {
    final rows = localIntakeCandidates('우유 2팩, 달걀 6개 추가', StorageType.freezer);
    expect(rows.map((r) => [r.name, r.quantity, r.unit, r.storageType]), [
      ['우유', 2, '팩', StorageType.freezer],
      ['달걀', 6, '개', StorageType.freezer],
    ]);
    expect(localIntakeCandidates('우유 2팩 달걀 6개', StorageType.fridge), isEmpty);
    expect(
      localIntakeCandidates('쌀 1,200g', StorageType.pantry).single.quantity,
      1200,
    );
  });
}
