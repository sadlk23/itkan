import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/batch_form.dart';
import 'package:my_fridge/design/app_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('new form uses default storage while edits preserve original', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'default_storage': 'freezer'});
    await tester.pumpWidget(const MaterialApp(home: BatchForm()));
    await tester.pumpAndSettle();
    final field = find.byType(DropdownButtonFormField<StorageType>);
    await tester.scrollUntilVisible(
      field,
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      tester.state<FormFieldState<StorageType>>(field).value,
      StorageType.freezer,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: BatchForm(
          initial: InventoryBatch(
            id: 'existing',
            name: '두부',
            quantity: 1,
            unit: '개',
            storageType: StorageType.pantry,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.state<FormFieldState<StorageType>>(field).value,
      StorageType.pantry,
    );
  });

  Future<void> openForm(
    WidgetTester tester, {
    InventoryBatch? initial,
    required ValueChanged<InventoryBatch?> onResult,
  }) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: FridgeTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(
                  await Navigator.push<InventoryBatch>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          BatchForm(initial: initial, confirmSave: false),
                    ),
                  ),
                );
              },
              child: const Text('폼 열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('폼 열기'));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String key, String option) async {
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await tester.pumpAndSettle();
    if (['batch-category', 'batch-opened-status'].contains(key)) {
      final extra = find.byKey(const ValueKey('batch-extra-details'));
      if (!ExpansibleController.of(tester.element(find.text('사진과 추가 정보'))).isExpanded) {
        await tester.ensureVisible(extra);
        await tester.pumpAndSettle();
        await tester.tap(find.text('사진과 추가 정보'));
        await tester.pumpAndSettle();
      }
    }
    final field = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(
      field,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('batch-save'));
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'renaming reselects automatic art and photo reset persists null',
    (tester) async {
      InventoryBatch? result;
      await openForm(
        tester,
        initial: InventoryBatch(
          id: 'photo',
          name: '우유',
          quantity: 1,
          unit: '개',
          artKey: 'milk',
          photoFile: 'missing.png',
        ),
        onResult: (batch) => result = batch,
      );
      await tester.enterText(find.byType(TextFormField).first, '상추');
      await tester.ensureVisible(find.byKey(const ValueKey('batch-photo-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('batch-photo-reset')));
      await save(tester);
      expect(result!.photoFile, isNull);
      expect(result!.artKey, 'generic');
      expect(result!.name, '상추');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'state condiment can be registered as none without a numeric quantity',
    (tester) async {
      InventoryBatch? result;
      await openForm(tester, onResult: (batch) => result = batch);
      await tester.enterText(find.byType(TextFormField).first, '간장');
      await choose(tester, 'batch-category', '소스');
      await choose(tester, 'batch-quantity-mode', '상태형 · 충분 / 부족 / 없음');
      expect(find.byKey(const ValueKey('batch-quantity')), findsNothing);
      await choose(tester, 'batch-stock-level', '없음');
      await choose(tester, 'batch-opened-status', '개봉');
      await save(tester);
      expect(result, isNotNull);
      expect(result!.name, '간장');
      expect(result!.category, '소스');
      expect(result!.quantityMode, QuantityMode.status);
      expect(result!.stockLevel, StockLevel.none);
      expect(result!.quantity, 0);
      expect(result!.openedStatus, OpenedStatus.opened);
      expect(result!.active, false);
      expect(quantityText(result!), '없음');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing status keeps identity and date source while changing remaining level',
    (tester) async {
      InventoryBatch? result;
      final initial = InventoryBatch(
        id: 'sauce',
        name: '간장',
        quantity: 1,
        unit: '병',
        category: '소스',
        quantityMode: QuantityMode.status,
        stockLevel: StockLevel.enough,
        openedStatus: OpenedStatus.opened,
        expiryStatus: ExpiryStatus.actual,
        expiryDate: DateTime(2027, 1, 10),
        expirySource: 'ocr',
        revision: 3,
      );
      await openForm(
        tester,
        initial: initial,
        onResult: (batch) => result = batch,
      );
      await choose(tester, 'batch-stock-level', '부족');
      await save(tester);
      expect(result!.id, 'sauce');
      expect(result!.unit, '병');
      expect(result!.revision, 3);
      expect(result!.expirySource, 'ocr');
      expect(result!.expiryDate, DateTime(2027, 1, 10));
      expect(result!.openedStatus, OpenedStatus.opened);
      expect(result!.stockLevel, StockLevel.low);
      expect(quantityText(result!), '부족');
    },
  );

  testWidgets(
    'changing date to unknown clears date and records manual source',
    (tester) async {
      InventoryBatch? result;
      final initial = InventoryBatch(
        id: 'milk',
        name: '우유',
        quantity: 1,
        unit: '팩',
        expiryDate: DateTime(2027, 1, 10),
        expiryStatus: ExpiryStatus.actual,
        expirySource: 'ocr',
      );
      await openForm(
        tester,
        initial: initial,
        onResult: (batch) => result = batch,
      );
      await choose(tester, 'batch-expiry-status', '미상');
      await save(tester);
      expect(result!.expiryDate, isNull);
      expect(result!.expiryStatus, ExpiryStatus.unknown);
      expect(result!.expirySource, 'manual');
    },
  );
}
