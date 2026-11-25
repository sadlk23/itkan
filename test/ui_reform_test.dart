import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/screens/batch_form.dart';
import 'package:my_fridge/services/inventory_store.dart';

class _ReviewInventory extends InventoryStore {
  final rows = demoInventory(DateTime.now());
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  testWidgets(
    'returning user enters inventory directly and can revisit doors',
    (tester) async {
      SharedPreferences.setMockInitialValues({'kitchen_visited': true});
      final store = _ReviewInventory();
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          home: HomeScreen(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('item-tofu')), findsOneWidget);
      expect(find.bySemanticsLabel('냉장고 문 열기'), findsNothing);
      await tester.tap(find.text('설정').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('나의 작은 주방 둘러보기'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('냉장고 문 열기'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );

  testWidgets(
    '320px inventory supports 200 percent text in selection and list modes',
    (tester) async {
      SharedPreferences.setMockInitialValues({'kitchen_visited': true});
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _ReviewInventory();
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: HomeScreen(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('inventory-selection-toggle')),
      );
      await tester.tap(
        find.byKey(const ValueKey('inventory-selection-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('item-tofu')));
      await tester.tap(find.byKey(const ValueKey('item-tofu')));
      await tester.pumpAndSettle();
      expect(find.text('선택한 1개 재료로 요리 찾기'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('inventory-view-toggle')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('inventory-view-toggle')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('inventory-view-toggle')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('선반 보기'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );

  testWidgets('registration reveals optional metadata on demand', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(theme: FridgeTheme.light, home: const BatchForm()),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('batch-photo-pick')).hitTestable(),
      findsNothing,
    );
    await tester.ensureVisible(find.text('사진과 추가 정보'));
    await tester.tap(find.text('사진과 추가 정보'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('batch-category')));
    expect(
      find.byKey(const ValueKey('batch-category')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
