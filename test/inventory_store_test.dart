import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/ingredient_photo_service.dart';
import 'package:my_fridge/screens/intake_screen.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class RecordingPhotoCleanup extends IngredientPhotoService {
  final deleted = <String>{};
  @override
  Future<void> deleteDraft(String basename) async {
    deleted.add(basename);
  }
}

void main() {
  sqfliteFfiInit();
  late Directory temp;
  late String databasePath;
  late InventoryStore store;
  final today = DateTime(2026, 11, 6, 10);

  InventoryStore createStore() => InventoryStore(
    databaseFactory: databaseFactoryFfi,
    databasePath: databasePath,
    clock: () => today,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fridge_inventory_');
    databasePath = path.join(temp.path, 'test.db');
    store = createStore();
    await store.initialize();
  });

  tearDown(() async {
    await store.close();
    store.dispose();
    await temp.delete(recursive: true);
  });

  test('intake cleanup removes only own uncommitted copies and protects global references', () async {
    await store.update(
      store.batches.first.copyWith(photoFile: 'demo-saved.jpg'),
    );
    await store.setDemoMode(false);
    await store.add(
      InventoryBatch(
        id: 'photo-retained',
        name: '재료',
        quantity: 1,
        unit: '개',
        photoFile: 'undo-only.jpg',
      ),
    );
    await store.delete('photo-retained');
    final cleanup = RecordingPhotoCleanup();
    await cleanupIntakePhotos(store, {
      'new-uncommitted.jpg',
      'demo-saved.jpg',
      'undo-only.jpg',
    }, photos: cleanup);
    expect(cleanup.deleted, {'new-uncommitted.jpg'});
    expect(cleanup.deleted, isNot(contains('preexisting-unrelated.jpg')));
  });

  test('photo references preserve both modes and undo-only files', () async {
    await store.update(
      store.batches.first.copyWith(photoFile: 'demo-photo.jpg'),
    );
    await store.setDemoMode(false);
    await store.add(
      InventoryBatch(
        id: 'photo',
        name: '사진재료',
        quantity: 1,
        unit: '개',
        photoFile: 'personal-photo.jpg',
      ),
    );
    await store.delete('photo');
    expect(
      await store.referencedPhotoFiles(),
      containsAll(['demo-photo.jpg', 'personal-photo.jpg']),
    );
    await store.clearAll();
    expect(await store.referencedPhotoFiles(), {'demo-photo.jpg'});
  });

  test('cooking stale revision rejects all deductions and leaves approval retryable', () async {
    final before = {for (final b in store.batches) b.id: b.revision};
    await store.saveCookingSession({
      'id': 'stale-meal',
      'status': 'awaitingUsage',
      'usageApplied': false,
    });
    await store.consume('tofu', 1);
    final historyCount = store.history.length;
    final kimchi = store.batches.firstWhere((b) => b.id == 'kimchi').quantity;
    await expectLater(
      store.applyCookingUsage('stale-meal', {
        'tofu': 10,
        'kimchi': 10,
      }, expectedRevisions: before),
      throwsStateError,
    );
    expect(store.batches.firstWhere((b) => b.id == 'kimchi').quantity, kimchi);
    expect(store.history.length, historyCount);
    expect(store.cookingSession?['usageApplied'], false);
    await expectLater(
      store.applyCookingUsage('stale-meal', {
        'tofu': 10,
      }, expectedRevisions: {}),
      throwsStateError,
    );
    await store.applyCookingUsage(
      'stale-meal',
      {'tofu': 10},
      expectedRevisions: {for (final b in store.batches) b.id: b.revision},
    );
    expect(store.cookingSession?['usageApplied'], true);
  });

  test('stale delete approval cannot delete an edited batch', () async {
    final before = store.batches.first;
    await store.update(before.copyWith(name: '확인 후 수정된 재료'));
    await expectLater(
      store.delete(before.id, expectedRevision: before.revision),
      throwsStateError,
    );
    expect(store.batches.any((batch) => batch.id == before.id), isTrue);
    final current = store.batches.firstWhere((batch) => batch.id == before.id);
    await store.delete(current.id, expectedRevision: current.revision);
    expect(store.batches.any((batch) => batch.id == before.id), isFalse);
    await store.undo(store.history.first.id);
    expect(
      store.batches.firstWhere((batch) => batch.id == before.id).name,
      '확인 후 수정된 재료',
    );
  });

  test(
    'separate batches and personal data survive reopen and demo reset',
    () async {
      await store.setDemoMode(false);
      expect(store.batches, isEmpty);
      await store.add(
        InventoryBatch(id: 'new1', name: '두부', quantity: 1, unit: '개'),
        requestId: 'one',
      );
      await store.add(
        InventoryBatch(id: 'new2', name: '두부', quantity: 2, unit: '개'),
        requestId: 'two',
      );
      expect(store.batches.length, 2);
      await store.close();
      store.dispose();
      store = createStore();
      await store.initialize();
      expect(store.isDemo, false);
      expect(store.batches.map((b) => b.quantity), [1.0, 2.0]);
      expect(store.history.length, 2);
      await store.resetDemo();
      expect(store.isDemo, true);
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
      await store.setDemoMode(false);
      expect(store.batches.length, 2);
    },
  );

  test(
    'photo reference survives restart and removing it can be undone',
    () async {
      final original = store.batches.firstWhere((b) => b.id == 'tofu');
      await store.update(original.copyWith(photoFile: 'ingredient_test.jpg'));
      await store.close();
      store.dispose();
      store = createStore();
      await store.initialize();
      final saved = store.batches.firstWhere((b) => b.id == 'tofu');
      expect(saved.photoFile, 'ingredient_test.jpg');
      expect(saved.name, original.name);
      expect(saved.quantity, original.quantity);
      await store.update(saved.copyWith(photoFile: null));
      expect(store.batches.firstWhere((b) => b.id == 'tofu').photoFile, isNull);
      await store.undo(store.history.first.id);
      expect(
        store.batches.firstWhere((b) => b.id == 'tofu').photoFile,
        'ingredient_test.jpg',
      );
    },
  );

  test(
    'repeated and concurrent receipt approval creates one batch and history',
    () async {
      final batch = InventoryBatch(
        id: 'receipt-tofu',
        name: '두부',
        quantity: 1,
        unit: '팩',
      );
      await Future.wait([
        store.add(batch, source: 'ocr', requestId: 'receipt-1'),
        store.add(batch, source: 'ocr', requestId: 'receipt-1'),
      ]);
      expect(store.batches.where((b) => b.id == batch.id).length, 1);
      expect(store.history.length, 1);
      await store.close();
      store.dispose();
      store = createStore();
      await store.initialize();
      await store.add(batch, source: 'ocr', requestId: 'receipt-1');
      expect(store.history.length, 1);
    },
  );

  test(
    'invalid multi-batch deduction changes neither inventory nor history',
    () async {
      await expectLater(
        store.applyUsage({'tofu': 100, 'kimchi': 900}),
        throwsArgumentError,
      );
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
      expect(store.history, isEmpty);
      await store.consume('tofu', 50);
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 250);
    },
  );

  test('cooking completion, history and marker persist exactly once', () async {
    await store.saveCookingSession({
      'id': 'meal1',
      'status': 'awaitingUsage',
      'usageApplied': false,
    });
    await Future.wait([
      store.applyCookingUsage('meal1', {
        'tofu': 150,
        'kimchi': 200,
        'leek': 20,
      }),
      store.applyCookingUsage('meal1', {
        'tofu': 150,
        'kimchi': 200,
        'leek': 20,
      }),
    ]);
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 150);
    expect(store.history.length, 1);
    expect(store.cookingSession?['usageApplied'], true);
    expect(store.cookingSession?['status'], 'completed');
    await store.close();
    store.dispose();
    store = createStore();
    await store.initialize();
    await store.applyCookingUsage('meal1', {'tofu': 150});
    expect(store.history.length, 1);
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 150);
    final changeId = store.history.first.id;
    await store.undo(changeId);
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
    expect(store.cookingSession?['inventoryReverted'], true);
    await store.applyCookingUsage('meal1', {'tofu': 150});
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
  });

  test(
    'failed cooking leaves session retryable; premature completion blocked',
    () async {
      await store.saveCookingSession({
        'id': 'meal1',
        'status': 'cooking',
        'usageApplied': false,
      });
      await expectLater(
        store.applyCookingUsage('meal1', {'tofu': 100}),
        throwsStateError,
      );
      await store.saveCookingSession({
        'id': 'meal1',
        'status': 'awaitingUsage',
        'usageApplied': false,
      });
      await expectLater(
        store.applyCookingUsage('meal1', {'tofu': 900}),
        throwsArgumentError,
      );
      expect(store.cookingSession?['usageApplied'], false);
      expect(store.history, isEmpty);
      await store.applyCookingUsage('meal1', {'tofu': 100});
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 200);
    },
  );

  test(
    'only latest operation can be undone; stale edits do not overwrite',
    () async {
      final original = store.batches.firstWhere((b) => b.id == 'tofu');
      await store.consume('tofu', 50);
      final firstChange = store.history.first.id;
      await store.update(
        store.batches
            .firstWhere((b) => b.id == 'tofu')
            .copyWith(storageType: StorageType.freezer),
      );
      await expectLater(store.undo(firstChange), throwsStateError);
      await expectLater(
        store.update(original.copyWith(name: '오래된 수정')),
        throwsStateError,
      );
      await store.undo(store.history.first.id);
      final restored = store.batches.firstWhere((b) => b.id == 'tofu');
      expect(restored.storageType, StorageType.fridge);
      expect(restored.quantity, 250);
      expect(store.canUndo, false);
      expect(store.history.first.action, 'undo');
      expect(store.history[1].undone, true);
    },
  );

  test(
    'consumption and waste differ; zero stock retained only in complete list',
    () async {
      await store.consume('tofu', 300, discard: true, requestId: 'waste1');
      expect(store.history.first.action, 'discard');
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 0);
      expect(store.activeBatches.any((b) => b.id == 'tofu'), false);
      await store.consume('kimchi', 10);
      expect(store.history.first.action, 'consume');
    },
  );

  test('receipt approval is atomic, idempotent and reversible', () async {
    final count = store.batches.length;
    final valid = InventoryBatch(
      id: 'ocr1',
      name: '양파',
      quantity: 2,
      unit: '개',
    );
    final invalid = InventoryBatch(
      id: 'ocr2',
      name: '우유',
      quantity: -1,
      unit: '팩',
    );
    await expectLater(
      store.addMany([valid, invalid], requestId: 'ocr-approval'),
      throwsArgumentError,
    );
    expect(store.batches.length, count);
    expect(store.history, isEmpty);
    await store.addMany([
      valid,
      invalid.copyWith(quantity: 1),
    ], requestId: 'ocr-approval');
    expect(store.batches.length, count + 2);
    await store.addMany([
      valid,
      invalid.copyWith(quantity: 1),
    ], requestId: 'ocr-approval');
    expect(store.batches.length, count + 2);
    expect(store.history.length, 1);
    await store.undo(store.history.first.id);
    expect(store.batches.length, count);
  });

  test(
    'personal wipe is irreversible, scoped and survives reopening',
    () async {
      await store.consume('tofu', 50, requestId: 'demo-event');
      await store.saveCookingSession({
        'id': 'demo-session',
        'status': 'cooking',
      });
      await store.setDemoMode(false);
      await store.add(
        InventoryBatch(id: 'personal1', name: '우유', quantity: 1, unit: '팩'),
        requestId: 'personal-event',
      );
      await store.saveCookingSession({
        'id': 'personal-session',
        'status': 'cooking',
      });
      await store.clearAll(requestId: 'wipe-personal');
      expect(store.batches, isEmpty);
      expect(store.history, isEmpty);
      expect(store.canUndo, false);
      expect(store.cookingSession, isNull);
      await store.close();
      store.dispose();
      store = createStore();
      await store.initialize();
      expect(store.isDemo, false);
      expect(store.batches, isEmpty);
      expect(store.history, isEmpty);
      expect(store.cookingSession, isNull);
      // The old request keys were removed with the mode, so a newly approved
      // event is possible. A repeated wipe cannot remove that new inventory.
      await store.add(
        InventoryBatch(id: 'personal2', name: '우유', quantity: 2, unit: '팩'),
        requestId: 'personal-event',
      );
      await store.clearAll(requestId: 'wipe-personal');
      expect(store.batches.single.id, 'personal2');
      await store.setDemoMode(true);
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 250);
      expect(store.history.length, 1);
      expect(store.cookingSession?['id'], 'demo-session');
      await store.consume('tofu', 50, requestId: 'demo-event');
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 250);
    },
  );

  test('unknown/estimated expiry and unit boundaries preserve meaning', () {
    final unknown = InventoryBatch(id: 'x', name: '소스', quantity: 1, unit: '병');
    expect(unknown.daysRemaining(today), isNull);
    expect(unknown.expiryLabel(today), '날짜 미상');
    final estimated = unknown.copyWith(
      expiryStatus: ExpiryStatus.estimated,
      expiryDate: DateTime(2026, 11, 8),
    );
    expect(estimated.expiryLabel(today), '추정 D-2');
    expect(convertQuantity(1.5, 'kg', 'g'), 1500);
    expect(convertQuantity(500, 'ml', 'L'), .5);
    expect(() => convertQuantity(1, '팩', 'g'), throwsArgumentError);
    expect(() => convertQuantity(1, 'ml', 'g'), throwsArgumentError);
    expect(() => convertQuantity(double.nan, 'g', 'g'), throwsArgumentError);
  });

  test('expiry allocation order uses dates then receipt, unknown last', () {
    final old = InventoryBatch(
      id: 'old',
      name: '두부',
      quantity: 10,
      unit: 'g',
      createdAt: DateTime(2026, 10, 1),
    );
    final dated = old.copyWith(
      id: 'dated',
      expiryStatus: ExpiryStatus.actual,
      expiryDate: DateTime(2026, 11, 10),
    );
    final near = dated.copyWith(
      id: 'near',
      expiryDate: DateTime(2026, 11, 8),
      createdAt: DateTime(2026, 11, 5),
    );
    final olderSame = near.copyWith(
      id: 'olderSame',
      createdAt: DateTime(2026, 11, 3),
    );
    final sorted = [old, dated, near, olderSame]..sort(compareBatchExpiry);
    expect(sorted.map((b) => b.id), ['olderSame', 'near', 'dated', 'old']);
  });
}
