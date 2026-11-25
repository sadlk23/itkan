import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:my_fridge/main.dart';
import 'package:my_fridge/screens/batch_form.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/services/inventory_store.dart';

void main() {
  sqfliteFfiInit();
  testWidgets('opens refrigerator and navigates to ingredient detail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await tester.runAsync(() => store.initialize());
    await tester.pumpWidget(FridgeApp(store: store));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.bySemanticsLabel('냉장고 문 열기'));
    await tester.tap(find.bySemanticsLabel('냉장고 문 열기'));
    await tester.pumpAndSettle();
    expect(find.text('두부'), findsWidgets);
    await tester.tap(find.text('두부').first);
    await tester.pumpAndSettle();
    expect(find.text('사용한 만큼 기록하기'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => store.close());
    store.dispose();
  });
  testWidgets(
    'manual registration rejects invalid quantity and requires confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(theme: FridgeTheme.light, home: const BatchForm()),
      );
      await tester.enterText(find.byType(TextFormField).at(0), '양파');
      await tester.enterText(find.byType(TextFormField).at(1), '-2');
      await tester.scrollUntilVisible(
        find.text('입력 내용 확인'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('입력 내용 확인'));
      await tester.pumpAndSettle();
      expect(find.text('0보다 큰 수량을 입력하세요.'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(1), '2');
      await tester.ensureVisible(find.text('입력 내용 확인'));
      await tester.tap(find.text('입력 내용 확인'));
      await tester.pumpAndSettle();
      expect(find.text('이대로 저장할까요?'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(find.byType(BatchForm), findsOneWidget);
    },
  );
}
