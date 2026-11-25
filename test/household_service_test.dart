import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/household_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late InventoryStore store;
  late HouseholdService sharing;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('household_test_');
    store = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: '${dir.path}/test.db',
    );
    await store.initialize();
    sharing = HouseholdService(store);
  });
  tearDown(() async {
    await store.close();
    store.dispose();
    await dir.delete(recursive: true);
  });
  test('preview and declined approval leave inventory unchanged', () async {
    final count = store.batches.length;
    final preview = sharing.preview(sharing.exportSnapshot());
    expect(store.batches.length, count);
    await expectLater(
      sharing.importApproved(preview, approved: false),
      throwsStateError,
    );
    expect(store.history, isEmpty);
  });
  test(
    'approved import keeps shelf, slot and original stocking date',
    () async {
      await store.setDemoMode(false);
      final stockedAt = DateTime(2025, 3, 4, 17, 30);
      await store.add(
        InventoryBatch(
          id: 'original',
          name: '두부',
          quantity: 1,
          unit: '개',
          shelfId: 'shelf-3',
          slotId: 'back',
          createdAt: stockedAt,
          photoFile: 'original-photo.jpg',
        ),
      );
      final text = sharing.exportSnapshot();
      final snapshot = sharing.preview(text);
      await sharing.importApproved(snapshot, approved: true);
      final imported = store.batches.singleWhere(
        (batch) => batch.id != 'original',
      );
      expect(imported.createdAt, stockedAt);
      expect(imported.shelfId, 'shelf-3');
      expect(imported.slotId, 'back');
      expect(imported.photoFile, isNull);
      final legacy = jsonDecode(text) as Map<String, dynamic>;
      final batch = (legacy['batches'] as List).single as Map;
      batch.remove('createdAt');
      batch.remove('shelfId');
      batch.remove('slotId');
      final old = sharing.preview(jsonEncode(legacy));
      expect(old.batches.single.createdAt, old.generatedAt);
      expect(old.batches.single.shelfId, isNull);
    },
  );
  test(
    'approved snapshot imports atomically and does not duplicate on resend',
    () async {
      final json = sharing.exportSnapshot();
      final count = store.batches.length;
      final preview = sharing.preview(json);
      expect(await sharing.importApproved(preview, approved: true), true);
      expect(store.batches.length, count * 2);
      expect(store.history.length, 1);
      expect(
        await sharing.importApproved(sharing.preview(json), approved: true),
        false,
      );
      expect(store.batches.length, count * 2);
      await store.undo(store.history.first.id);
      expect(store.batches.length, count);
    },
  );
  test(
    'one malformed batch rejects whole preview and mode change blocks import',
    () async {
      final text = sharing.exportSnapshot();
      final raw = jsonDecode(text) as Map<String, dynamic>;
      (raw['batches'] as List).last['quantity'] = -1;
      expect(() => sharing.preview(jsonEncode(raw)), throwsFormatException);
      expect(store.history, isEmpty);
      final valid = sharing.preview(text);
      await store.setDemoMode(false);
      await expectLater(
        sharing.importApproved(valid, approved: true),
        throwsStateError,
      );
      expect(store.batches, isEmpty);
    },
  );
}
