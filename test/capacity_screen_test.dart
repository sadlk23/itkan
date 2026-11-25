import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/screens/capacity_screen.dart';
import 'package:my_fridge/services/capacity_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/models/inventory.dart';

class _CapacityInventory extends InventoryStore {
  final rows = demoInventory(DateTime.now());
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  testWidgets('capacity dimension form saves with no inventory mutation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = _CapacityInventory();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: FridgeTheme.light,
        home: CapacityScreen(store: store),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('공간 치수 입력'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    for (var i = 0; i < 3; i++) {
      await tester.enterText(fields.at(i), '10');
    }
    await tester.tap(find.text('확인하고 저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      (await CapacityService().load(demo: true))
          .spaces[StorageType.fridge]!
          .litres,
      1,
    );
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
    expect(find.textContaining('산술 비율'), findsWidgets);
  });
}
