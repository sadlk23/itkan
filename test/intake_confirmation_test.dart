import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/intake_screen.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  testWidgets('candidate approval cannot cross demo and personal modes', (
    tester,
  ) async {
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('intake_test_'),
    ))!;
    final store = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: '${temp.path}/test.db',
    );
    await tester.runAsync(store.initialize);
    await tester.pumpWidget(
      MaterialApp(
        home: CandidateScreen(
          store: store,
          rawText: '두부',
          source: 'ocr',
          drafts: [
            InventoryBatch(id: 'candidate', name: '두부', quantity: 1, unit: '개'),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('선택한 1개 항목 입고'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => store.setDemoMode(false));
    await tester.tap(find.text('확인하고 입고'));
    await tester.pumpAndSettle();
    expect(store.batches, isEmpty);
    expect(find.text('보관함 모드가 바뀌었어요. 현재 모드에서 후보를 다시 확인해주세요.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(store.close);
    store.dispose();
    await tester.runAsync(() => temp.delete(recursive: true));
  });
}
