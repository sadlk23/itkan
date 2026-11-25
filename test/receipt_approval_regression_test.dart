import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/receipt_privacy.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late InventoryStore store;
  setUp(() async {
    store = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await store.initialize();
    await store.setDemoMode(false);
  });
  tearDown(() async {
    await store.close();
    store.dispose();
  });
  test('a mode switch queued before intake rejects stale writes', () async {
    final batch = InventoryBatch(
      id: 'stale',
      name: '우유',
      quantity: 1,
      unit: '팩',
    );
    final switching = store.setDemoMode(true);
    await expectLater(
      store.addMany([batch], expectedDemo: false),
      throwsStateError,
    );
    await switching;
    expect(store.batches.any((b) => b.id == 'stale'), isFalse);
  });

  final first = receiptFingerprint('두부 1,200');
  final repeated = receiptFingerprint('두부   1,200\n');
  Future<void> receive(
    String id, {
    String? digest,
    String? confirmed,
    bool demo = false,
  }) => store.addReceipt(
    [InventoryBatch(id: id, name: '두부', quantity: 1, unit: '개')],
    digest: digest ?? first,
    requestId: 'intake_$id',
    confirmedPreviousChangeId: confirmed,
    expectedDemo: demo,
  );

  test('rescanning requires a fresh explicit confirmation of the last active receipt', () async {
    await receive('a');
    final oldId = store.history.single.id;
    await receive('a'); // retry the same save
    await expectLater(
      receive('b', digest: repeated),
      throwsA(
        isA<DuplicateReceipt>().having(
          (e) => e.previousChange.id,
          'previous',
          oldId,
        ),
      ),
    );
    await receive('b', confirmed: oldId);
    await expectLater(
      receive('c', confirmed: oldId),
      throwsA(isA<DuplicateReceipt>()),
    );
    expect(store.batches, hasLength(2));
    await store.undo(store.history.first.id);
    await expectLater(receive('c'), throwsA(isA<DuplicateReceipt>()));
    await receive('c', digest: receiptFingerprint('두부 1,300'));
    expect(store.batches, hasLength(2));
  });

  test('two scans cannot both commit, and undo unlocks a fresh scan', () async {
    final outcomes = await Future.wait(
      ['a', 'b'].map((id) async {
        try {
          await receive(id);
          return true;
        } on DuplicateReceipt {
          return false;
        }
      }),
    );
    expect(outcomes.where((saved) => saved), hasLength(1));
    await store.undo(store.history.single.id);
    await receive('again');
    expect(store.batches, hasLength(1));
  });

  test(
    'receipts are isolated by inventory mode and reset removes their state',
    () async {
      await receive('personal');
      await store.setDemoMode(true);
      await expectLater(receive('old-mode'), throwsStateError);
      await receive('sample', demo: true);
      await store.resetDemo();
      await receive('sample-again', demo: true);
      await store.setDemoMode(false);
      await expectLater(
        receive('personal-duplicate'),
        throwsA(isA<DuplicateReceipt>()),
      );
      await store.clearAll();
      await receive('new');
      expect(store.batches.single.id, 'new');
    },
  );

  test(
    'small converted servings remain editable and are deducted precisely',
    () async {
      expect(formatQuantity(0.0000001), '0.0000001');
      expect(remainingQuantity(0.3, 0.1), 0.2);
      await store.add(
        InventoryBatch(id: 'salt', name: '소금', quantity: 1, unit: 'kg'),
      );
      await store.consume('salt', convertQuantity(0.0001, 'g', 'kg'));
      expect(store.batches.single.quantity, 0.9999999);
    },
  );

  test(
    'v1 upgrade preserves stock and remembers receipt approvals after restart',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'itkan_migration_test_',
      );
      final path = '${dir.path}/inventory.sqlite';
      InventoryStore open() => InventoryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
      );
      var disk = open();
      try {
        await disk.initialize();
        await disk.setDemoMode(false);
        await disk.add(
          InventoryBatch(id: 'existing', name: '감자', quantity: 2, unit: '개'),
        );
        await disk.close();
        disk.dispose();
        final old = await databaseFactoryFfi.openDatabase(path);
        await old.execute('DROP TABLE receipt_approvals');
        await old.execute('PRAGMA user_version = 1');
        await old.close();
        disk = open();
        await disk.initialize();
        expect(disk.batches.single.id, 'existing');
        await disk.addReceipt(
          [InventoryBatch(id: 'rice', name: '쌀', quantity: 1, unit: 'kg')],
          digest: first,
          requestId: 'old-receipt',
          expectedDemo: false,
        );
        await disk.close();
        disk.dispose();
        disk = open();
        await disk.initialize();
        await expectLater(
          disk.addReceipt(
            [
              InventoryBatch(
                id: 'rice-again',
                name: '쌀',
                quantity: 1,
                unit: 'kg',
              ),
            ],
            digest: repeated,
            requestId: 'rescan',
            expectedDemo: false,
          ),
          throwsA(isA<DuplicateReceipt>()),
        );
        expect(disk.batches, hasLength(2));
      } finally {
        await disk.close();
        disk.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test('replaced and finished cooking sessions reject stale saves and completion retries', () async {
    await store.saveCookingSessionIfCurrent({
      'id': 'A',
      'status': 'awaitingUsage',
    }, expectedSessionId: null);
    await store.applyCookingUsage('A', {});
    await store.applyCookingUsage('A', {});
    await expectLater(
      store.saveCookingSessionIfCurrent({
        'id': 'A',
        'status': 'cooking',
      }, expectedSessionId: 'A'),
      throwsStateError,
    );
    await store.saveCookingSessionIfCurrent({
      'id': 'B',
      'status': 'cooking',
    }, expectedSessionId: 'A');
    await expectLater(store.applyCookingUsage('A', {}), throwsStateError);
    await expectLater(
      store.saveCookingSessionIfCurrent({
        'id': 'A',
        'status': 'cooking',
      }, expectedSessionId: 'A'),
      throwsStateError,
    );
    expect(store.cookingSession!['id'], 'B');
  });
}
