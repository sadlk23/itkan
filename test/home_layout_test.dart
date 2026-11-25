import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/services/inventory_store.dart';

class _HomeInventory extends InventoryStore {
  final rows = demoInventory(DateTime.now());
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  for (final scale in [1.0, 1.5]) {
    testWidgets('four home tabs fit 390px at text scale $scale', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _HomeInventory();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: HomeScreen(store: store),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.bySemanticsLabel('냉장고 문 열기'));
      await tester.tap(find.bySemanticsLabel('냉장고 문 열기'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final label in ['AI 요리', '장보기', '설정', '냉장고']) {
        await tester.tap(
          find
              .descendant(
                of: find.byType(NavigationBar),
                matching: find.text(label),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '$label tab, text scale $scale',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
