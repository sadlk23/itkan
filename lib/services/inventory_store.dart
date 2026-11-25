import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/inventory.dart';
import '../models/assistant_command.dart';

class DuplicateReceipt implements Exception {
  const DuplicateReceipt(this.previousChange);
  final InventoryChange previousChange;
}

/// All input paths use this store, after the UI has presented a confirmation.
/// Each mutation atomically writes inventory, history and the deduplication key.
class InventoryStore extends ChangeNotifier {
  InventoryStore({
    DatabaseFactory? databaseFactory,
    this.databasePath,
    DateTime Function()? clock,
  }) : _factory = databaseFactory,
       _clock = clock ?? DateTime.now;

  final DatabaseFactory? _factory;
  final String? databasePath;
  final DateTime Function() _clock;
  Database? _db;
  Future<void>? _initializing;
  Future<void> _queue = Future.value();
  List<InventoryBatch> _batches = [];
  List<InventoryChange> _history = [];
  Map<String, dynamic>? _cookingSession;
  bool _isDemo = true;
  bool _disposed = false;
  int _counter = 0;
  final int _instanceId = DateTime.now().microsecondsSinceEpoch;

  List<InventoryBatch> get batches => List.unmodifiable(_batches);
  List<InventoryChange> get history => List.unmodifiable(_history);
  List<InventoryBatch> get activeBatches =>
      _batches.where((b) => b.active).toList(growable: false);
  bool get isDemo => _isDemo;
  DateTime get now => _clock();
  bool get isInitialized => _db != null;
  bool get canUndo =>
      _history.isNotEmpty &&
      !_history.first.undone &&
      _history.first.action != 'undo';
  Map<String, dynamic>? get cookingSession => _cookingSession == null
      ? null
      : Map<String, dynamic>.from(
          jsonDecode(jsonEncode(_cookingSession)) as Map,
        );
  String get _mode => _isDemo ? 'demo' : 'personal';
  Database get _database => _db ?? (throw StateError('저장소 초기화가 필요합니다.'));
  String _newId(String prefix) => '$prefix-$_instanceId-${_counter++}';

  /// References from both modes and undo snapshots; callers may only delete
  /// candidate files absent from this set after their scoped wipe succeeds.
  Future<Set<String>> referencedPhotoFiles() async {
    final result = <String>{};
    await _serial(() async {
      await _database.transaction((txn) async {
        void collect(dynamic batch) {
          if (batch is Map &&
              batch['photoFile'] is String &&
              (batch['photoFile'] as String).isNotEmpty) {
            result.add(batch['photoFile'] as String);
          }
        }

        for (final row in await txn.query('inventory', columns: ['payload'])) {
          collect(jsonDecode(row['payload'] as String));
        }
        for (final row in await txn.query('changes', columns: ['payload'])) {
          final change = jsonDecode(row['payload'] as String) as Map;
          for (final key in ['before', 'after']) {
            for (final batch in change[key] as List) {
              collect(batch);
            }
          }
        }
      });
    });
    return result;
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      final factory = _factory ?? databaseFactory;
      final path =
          databasePath ??
          p.join(await factory.getDatabasesPath(), 'my_fridge_v1.db');
      _db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onUpgrade: (db, from, to) async {
            if (from < 2) await _createReceiptTable(db);
          },
          onCreate: (db, version) async {
            await _createReceiptTable(db);
            await db.execute(
              'CREATE TABLE inventory(mode TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(mode,id))',
            );
            await db.execute(
              'CREATE TABLE changes(seq INTEGER PRIMARY KEY AUTOINCREMENT, mode TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(mode,id))',
            );
            await db.execute(
              'CREATE TABLE requests(mode TEXT NOT NULL, request_id TEXT NOT NULL, PRIMARY KEY(mode,request_id))',
            );
            await db.execute(
              'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE sessions(mode TEXT PRIMARY KEY, payload TEXT NOT NULL)',
            );
          },
        ),
      );
      final modeRows = await _database.query(
        'settings',
        where: 'key = ?',
        whereArgs: ['mode'],
      );
      _isDemo = modeRows.isEmpty || modeRows.first['value'] == 'demo';
      final seeded = await _database.query(
        'settings',
        where: 'key = ?',
        whereArgs: ['demo_seeded'],
      );
      if (seeded.isEmpty) {
        await _database.transaction((txn) async {
          for (final batch in demoInventory(_clock())) {
            await txn.insert('inventory', {
              'mode': 'demo',
              'id': batch.id,
              'payload': jsonEncode(batch.toJson()),
            });
          }
          await txn.insert('settings', {'key': 'demo_seeded', 'value': 'true'});
        });
      }
      await _reload();
    } catch (_) {
      await _db?.close();
      _db = null;
      _initializing = null;
      rethrow;
    }
  }

  static Future<void> _createReceiptTable(Database db) => db.execute(
    'CREATE TABLE receipt_approvals(mode TEXT NOT NULL, digest TEXT NOT NULL, '
    'change_id TEXT NOT NULL, PRIMARY KEY(mode,digest,change_id))',
  );

  Future<void> _reload() async {
    final rows = await _database.query(
      'inventory',
      where: 'mode = ?',
      whereArgs: [_mode],
    );
    final changes = await _database.query(
      'changes',
      where: 'mode = ?',
      whereArgs: [_mode],
      orderBy: 'seq DESC',
    );
    final sessions = await _database.query(
      'sessions',
      where: 'mode = ?',
      whereArgs: [_mode],
    );
    _batches = rows
        .map(
          (r) => InventoryBatch.fromJson(
            jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
    _batches.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _history = changes
        .map(
          (r) => InventoryChange.fromJson(
            jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
    _cookingSession = sessions.isEmpty
        ? null
        : jsonDecode(sessions.first['payload'] as String)
              as Map<String, dynamic>;
    if (!_disposed) notifyListeners();
  }

  Future<void> _serial(Future<void> Function() action) {
    final result = _queue.then((_) => action());
    // A failed command must not poison subsequent commands.
    _queue = result.then((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  InventoryBatch _find(String id) => _batches.firstWhere(
    (b) => b.id == id,
    orElse: () => throw StateError('재료가 변경되었어요. 목록을 새로 확인해주세요.'),
  );

  void _validate(InventoryBatch batch, {bool adding = false}) {
    if (batch.id.trim().isEmpty ||
        batch.name.trim().isEmpty ||
        batch.unit.trim().isEmpty) {
      throw ArgumentError('재료 이름과 단위가 필요합니다.');
    }
    if (!batch.quantity.isFinite ||
        batch.quantity < 0 ||
        (adding &&
            batch.quantityMode == QuantityMode.measured &&
            batch.quantity <= 0)) {
      throw ArgumentError(adding ? '입고 수량은 0보다 커야 합니다.' : '수량은 음수가 될 수 없습니다.');
    }
    if (batch.expiryStatus != ExpiryStatus.unknown &&
        batch.expiryDate == null) {
      throw ArgumentError('날짜를 입력하거나 미상으로 선택해주세요.');
    }
    if (batch.expiryStatus == ExpiryStatus.unknown &&
        batch.expiryDate != null) {
      throw ArgumentError('미상 날짜에는 확정 날짜를 저장할 수 없습니다.');
    }
  }

  Future<bool> _alreadyApplied(String? requestId) async {
    if (requestId == null) return false;
    return (await _database.query(
      'requests',
      where: 'mode = ? AND request_id = ?',
      whereArgs: [_mode, requestId],
    )).isNotEmpty;
  }

  Future<void> _write({
    required List<InventoryBatch> before,
    required List<InventoryBatch> after,
    required String label,
    required String action,
    required String source,
    String? requestId,
    Map<String, dynamic>? completedSession,
    InventoryChange? reversing,
    String? receiptDigest,
    String? confirmedReceiptChangeId,
  }) async {
    if (await _alreadyApplied(requestId)) return;
    for (final batch in after) {
      _validate(batch);
    }
    final change = InventoryChange(
      id: _newId('change'),
      label: label,
      createdAt: _clock(),
      before: List.unmodifiable(before),
      after: List.unmodifiable(after),
      action: action,
      source: source,
      requestId: requestId,
    );
    await _database.transaction((txn) async {
      if (action == 'cooking' && completedSession != null) {
        final current = await _readCookingSession(txn);
        if (current == null || current['id'] != completedSession['id']) {
          throw StateError('진행 중인 요리가 바뀌었어요.');
        }
        if (current['status'] == 'completed' &&
            current['usageApplied'] == true) {
          return;
        }
        if (current['status'] != 'awaitingUsage') {
          throw StateError('사용량을 다시 확인해주세요.');
        }
        for (final batch in before) {
          final rows = await txn.query(
            'inventory',
            columns: ['payload'],
            where: 'mode = ? AND id = ?',
            whereArgs: [_mode, batch.id],
          );
          if (rows.isEmpty ||
              (jsonDecode(rows.first['payload'] as String)
                      as Map)['revision'] !=
                  batch.revision) {
            throw StateError('사용량 확인 후 재고가 바뀌었어요. 최신 재고로 다시 확인해주세요.');
          }
        }
      }
      if (receiptDigest != null) {
        // Check inside the same transaction that commits every selected item.
        final matches = await txn.rawQuery(
          'SELECT c.payload FROM receipt_approvals a JOIN changes c '
          'ON c.mode = a.mode AND c.id = a.change_id '
          'WHERE a.mode = ? AND a.digest = ? ORDER BY c.seq DESC',
          [_mode, receiptDigest],
        );
        for (final row in matches) {
          final previous = InventoryChange.fromJson(
            jsonDecode(row['payload'] as String) as Map<String, dynamic>,
          );
          if (previous.undone) continue;
          if (previous.id != confirmedReceiptChangeId) {
            throw DuplicateReceipt(previous);
          }
          break;
        }
        await txn.insert('receipt_approvals', {
          'mode': _mode,
          'digest': receiptDigest,
          'change_id': change.id,
        });
      }
      for (final batch in before) {
        await txn.delete(
          'inventory',
          where: 'mode = ? AND id = ?',
          whereArgs: [_mode, batch.id],
        );
      }
      for (final batch in after) {
        await txn.insert('inventory', {
          'mode': _mode,
          'id': batch.id,
          'payload': jsonEncode(batch.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (reversing != null) {
        await txn.update(
          'changes',
          {'payload': jsonEncode(reversing.withUndone().toJson())},
          where: 'mode = ? AND id = ?',
          whereArgs: [_mode, reversing.id],
        );
      }
      await txn.insert('changes', {
        'mode': _mode,
        'id': change.id,
        'payload': jsonEncode(change.toJson()),
      });
      if (requestId != null) {
        await txn.insert('requests', {'mode': _mode, 'request_id': requestId});
      }
      if (completedSession != null) {
        await txn.insert('sessions', {
          'mode': _mode,
          'payload': jsonEncode(completedSession),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    await _reload();
  }

  void _checkMode(bool? expectedDemo) {
    if (expectedDemo != null && expectedDemo != _isDemo) {
      throw StateError('보관함 모드가 바뀌었어요.');
    }
  }

  Future<void> add(
    InventoryBatch batch, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) => _serial(() async {
    _checkMode(expectedDemo);
    if (await _alreadyApplied(requestId)) return;
    _validate(batch, adding: true);
    if (_batches.any((b) => b.id == batch.id)) {
      throw StateError('이미 등록된 재고 묶음입니다.');
    }
    final added = batch.copyWith(
      name: batch.name.trim(),
      updatedAt: _clock(),
      revision: 1,
    );
    await _write(
      before: [],
      after: [added],
      label: '${added.name} ${added.quantityLabel} 입고',
      action: 'add',
      source: source,
      requestId: requestId,
    );
  });

  /// OCR candidates are approved together: either every selected batch is
  /// stored, or none are. Reusing the approval requestId never duplicates stock.
  Future<void> addMany(
    List<InventoryBatch> batches, {
    String source = 'ocr',
    String? requestId,
    bool? expectedDemo,
  }) => _serial(() async {
    _checkMode(expectedDemo);
    if (await _alreadyApplied(requestId)) return;
    await _addMany(batches, source: source, requestId: requestId);
  });

  Future<void> addReceipt(
    List<InventoryBatch> batches, {
    required String digest,
    required String requestId,
    required bool expectedDemo,
    String? confirmedPreviousChangeId,
  }) => _serial(() async {
    _checkMode(expectedDemo);
    if (await _alreadyApplied(requestId)) return;
    await _addMany(
      batches,
      source: 'ocr',
      requestId: requestId,
      receiptDigest: digest,
      confirmedReceiptChangeId: confirmedPreviousChangeId,
    );
  });

  Future<void> _addMany(
    List<InventoryBatch> batches, {
    required String source,
    String? requestId,
    String? receiptDigest,
    String? confirmedReceiptChangeId,
  }) async {
    if (batches.isEmpty) throw ArgumentError('입고할 항목을 선택해주세요.');
    final ids = <String>{};
    for (final batch in batches) {
      _validate(batch, adding: true);
      if (!ids.add(batch.id) || _batches.any((b) => b.id == batch.id)) {
        throw StateError('중복된 재고 묶음 ID가 있습니다.');
      }
    }
    final added = batches
        .map(
          (batch) => batch.copyWith(
            name: batch.name.trim(),
            updatedAt: _clock(),
            revision: 1,
          ),
        )
        .toList();
    await _write(
      before: [],
      after: added,
      label: '${added.length}개 재료 입고',
      action: 'add',
      source: source,
      requestId: requestId,
      receiptDigest: receiptDigest,
      confirmedReceiptChangeId: confirmedReceiptChangeId,
    );
  }

  Future<void> update(
    InventoryBatch batch, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) => _serial(() async {
    _checkMode(expectedDemo);
    if (await _alreadyApplied(requestId)) return;
    final previous = _find(batch.id);
    if (batch.revision != previous.revision) {
      throw StateError('재고가 변경되었어요. 최신 정보를 확인한 뒤 다시 수정해주세요.');
    }
    _validate(batch);
    final moved =
        previous.storageType != batch.storageType ||
        previous.shelfId != batch.shelfId ||
        previous.slotId != batch.slotId;
    await _write(
      before: [previous],
      after: [
        batch.copyWith(
          name: batch.name.trim(),
          createdAt: previous.createdAt,
          updatedAt: _clock(),
          revision: previous.revision + 1,
        ),
      ],
      label: '${batch.name} ${moved ? '보관 위치 이동' : '정보 수정'}',
      action: moved ? 'move' : 'update',
      source: source,
      requestId: requestId,
    );
  });

  Future<void> delete(
    String id, {
    String source = 'manual',
    String? requestId,
    int? expectedRevision,
  }) => _serial(() async {
    if (await _alreadyApplied(requestId)) return;
    final previous = _find(id);
    if (expectedRevision != null && previous.revision != expectedRevision) {
      throw StateError('확인한 뒤 재고가 바뀌었어요. 최신 정보를 확인한 뒤 삭제해주세요.');
    }
    await _write(
      before: [previous],
      after: [],
      label: '${previous.name} 삭제',
      action: 'delete',
      source: source,
      requestId: requestId,
    );
  });

  Future<void> consume(
    String id,
    double amount, {
    bool discard = false,
    String source = 'manual',
    String? requestId,
    int? expectedRevision,
  }) => _serial(() async {
    if (await _alreadyApplied(requestId)) return;
    final previous = _find(id);
    if (expectedRevision != null && previous.revision != expectedRevision) {
      throw StateError('확인한 뒤 재고가 바뀌었어요. 최신 수량으로 다시 확인해주세요.');
    }
    final after = _deduct(previous, amount);
    await _write(
      before: [previous],
      after: [after],
      label:
          '${previous.name} ${formatQuantity(amount)} ${previous.unit} ${discard ? '폐기' : '사용'}',
      action: discard ? 'discard' : 'consume',
      source: source,
      requestId: requestId,
    );
  });

  InventoryBatch _deduct(InventoryBatch batch, double amount) {
    if (batch.quantityMode != QuantityMode.measured) {
      throw ArgumentError('상태형 재료는 충분·부족·없음으로 수정해주세요.');
    }
    if (!amount.isFinite || amount <= 0 || amount > batch.quantity) {
      throw ArgumentError('사용량은 0보다 크고 현재 재고 이하여야 합니다.');
    }
    return batch.copyWith(
      quantity: remainingQuantity(batch.quantity, amount),
      updatedAt: _clock(),
      revision: batch.revision + 1,
    );
  }

  Future<void> applyUsage(
    Map<String, double> usage, {
    String source = 'cooking',
    String? requestId,
  }) => _serial(() async {
    if (await _alreadyApplied(requestId)) return;
    await _applyUsage(usage, source: source, requestId: requestId);
  });

  Future<void> _applyUsage(
    Map<String, double> usage, {
    required String source,
    String? requestId,
    Map<String, dynamic>? completedSession,
  }) async {
    final before = <InventoryBatch>[];
    final after = <InventoryBatch>[];
    for (final entry in usage.entries) {
      if (!entry.value.isFinite || entry.value < 0) {
        throw ArgumentError('유효한 사용량을 입력해주세요.');
      }
      if (entry.value == 0) continue;
      final batch = _find(entry.key);
      before.add(batch);
      after.add(_deduct(batch, entry.value));
    }
    // A user may explicitly exclude all ingredients (e.g. condiments only).
    // Completing that session must still record its completion exactly once.
    if (before.isEmpty && completedSession == null) {
      throw ArgumentError('반영할 사용량이 없습니다.');
    }
    await _write(
      before: before,
      after: after,
      label: '요리 완료 · ${before.length}개 재료 사용',
      action: 'cooking',
      source: source,
      requestId: requestId,
      completedSession: completedSession,
    );
  }

  Future<void> saveCookingSession(Map<String, dynamic>? session) =>
      _serial(() => _persistCookingSession(session));

  Future<void> saveCookingSessionIfCurrent(
    Map<String, dynamic> next, {
    required String? expectedSessionId,
  }) => _serial(
    () => _persistCookingSession(
      next,
      checkCurrent: true,
      expectedSessionId: expectedSessionId,
    ),
  );

  Future<Map<String, dynamic>?> _readCookingSession(DatabaseExecutor db) async {
    final rows = await db.query(
      'sessions',
      columns: ['payload'],
      where: 'mode = ?',
      whereArgs: [_mode],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  Future<void> _persistCookingSession(
    Map<String, dynamic>? session, {
    bool checkCurrent = false,
    String? expectedSessionId,
  }) async {
    if (session != null &&
        (session['id'] is! String || (session['id'] as String).isEmpty)) {
      throw ArgumentError('조리 세션 ID가 필요합니다.');
    }
    await _database.transaction((txn) async {
      final current = await _readCookingSession(txn);
      if (checkCurrent && current?['id'] != expectedSessionId) {
        throw StateError('다른 조리가 시작됐어요. 현재 조리를 다시 열어주세요.');
      }
      if (session != null &&
          current != null &&
          current['id'] == session['id'] &&
          (current['usageApplied'] == true ||
              ['ended', 'completed'].contains(current['status']))) {
        throw StateError('이미 종료된 조리입니다. 새 요리를 시작해주세요.');
      }
      if (session == null) {
        await txn.delete('sessions', where: 'mode = ?', whereArgs: [_mode]);
      } else {
        await txn.insert('sessions', {
          'mode': _mode,
          'payload': jsonEncode(session),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    await _reload();
  }

  Future<void> applyCookingUsage(
    String sessionId,
    Map<String, double> usage, {
    Map<String, int>? expectedRevisions,
  }) => _serial(() async {
    final requestId = 'cooking:$sessionId';
    final session = await _readCookingSession(_database);
    if (session == null || session['id'] != sessionId) {
      throw StateError('진행 중인 요리를 찾을 수 없습니다.');
    }
    if (await _alreadyApplied(requestId)) return;
    if (session['status'] != 'awaitingUsage') {
      throw StateError('조리 완료 후 사용량을 확인해주세요.');
    }
    if (expectedRevisions != null) {
      for (final id in usage.keys) {
        if (!expectedRevisions.containsKey(id) ||
            _find(id).revision != expectedRevisions[id]) {
          throw StateError('사용량 확인 후 재고가 바뀌었어요. 최신 재고로 다시 확인해주세요.');
        }
      }
    }
    await _applyUsage(
      usage,
      source: 'cooking',
      requestId: requestId,
      completedSession: {
        ...session,
        'status': 'completed',
        'usageApplied': true,
        'completedAt': _clock().toIso8601String(),
      },
    );
  });

  Future<void> undo(String changeId, {String? requestId}) => _serial(() async {
    if (await _alreadyApplied(requestId)) return;
    if (!canUndo || _history.first.id != changeId) {
      throw StateError('후속 변경이 없는 가장 최근 작업만 되돌릴 수 있습니다.');
    }
    final change = _history.first;
    final afterById = {for (final b in change.after) b.id: b};
    final beforeById = {for (final b in change.before) b.id: b};
    for (final id in {...beforeById.keys, ...afterById.keys}) {
      final current = _batches.where((b) => b.id == id).firstOrNull;
      final expected = afterById[id];
      if ((current == null) != (expected == null) ||
          (current != null && !current.hasSameSnapshot(expected!))) {
        throw StateError('현재 재고가 저장 당시와 달라 되돌릴 수 없습니다.');
      }
    }
    final restored = change.before
        .map(
          (b) => b.copyWith(
            updatedAt: _clock(),
            revision: (afterById[b.id]?.revision ?? b.revision) + 1,
          ),
        )
        .toList();
    // Retain the successful cooking marker, preventing an old completion event
    // from deducting again after the user explicitly restored inventory.
    final session =
        change.action == 'cooking' &&
            _cookingSession != null &&
            change.requestId == 'cooking:${_cookingSession!['id']}'
        ? {..._cookingSession!, 'inventoryReverted': true}
        : null;
    await _write(
      before: change.after,
      after: restored,
      label: '${change.label} 되돌리기',
      action: 'undo',
      source: 'manual',
      requestId: requestId,
      reversing: change,
      completedSession: session,
    );
  });

  Future<void> setDemoMode(bool demo) => _serial(() async {
    await _database.insert('settings', {
      'key': 'mode',
      'value': demo ? 'demo' : 'personal',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _isDemo = demo;
    AssistantMemory.instance.syncMode(demo);
    await _reload();
  });

  Future<void> resetDemo({String? requestId}) => _serial(() async {
    if (requestId != null &&
        (await _database.query(
          'requests',
          where: 'mode = ? AND request_id = ?',
          whereArgs: ['demo', requestId],
        )).isNotEmpty) {
      return;
    }
    await _database.transaction((txn) async {
      for (final table in [
        'inventory',
        'changes',
        'requests',
        'sessions',
        'receipt_approvals',
      ]) {
        await txn.delete(table, where: 'mode = ?', whereArgs: ['demo']);
      }
      for (final batch in demoInventory(_clock())) {
        await txn.insert('inventory', {
          'mode': 'demo',
          'id': batch.id,
          'payload': jsonEncode(batch.toJson()),
        });
      }
      if (requestId != null) {
        await txn.insert('requests', {'mode': 'demo', 'request_id': requestId});
      }
      await txn.insert('settings', {
        'key': 'mode',
        'value': 'demo',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _isDemo = true;
    AssistantMemory.instance.clear();
    AssistantMemory.instance.syncMode(true);
    await _reload();
  });

  /// Irreversible deletion of this mode's stock, audit history, requests and
  /// cooking session. The other mode is untouched. UI must confirm twice.
  Future<void> clearAll({String? requestId}) => _serial(() async {
    if (await _alreadyApplied(requestId)) return;
    await _database.transaction((txn) async {
      for (final table in [
        'inventory',
        'changes',
        'requests',
        'sessions',
        'receipt_approvals',
      ]) {
        await txn.delete(table, where: 'mode = ?', whereArgs: [_mode]);
      }
      // Only an opaque operation token remains when supplied, preventing a
      // repeated delete event from erasing newly entered data after this wipe.
      if (requestId != null) {
        await txn.insert('requests', {'mode': _mode, 'request_id': requestId});
      }
    });
    AssistantMemory.instance.clear();
    await _reload();
  });

  Future<void> close() async {
    await _queue;
    await _db?.close();
    _db = null;
    _initializing = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

List<InventoryBatch> demoInventory(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  InventoryBatch item(
    String id,
    String name,
    double qty,
    String unit,
    StorageType type,
    int? days,
    String category, {
    ExpiryStatus status = ExpiryStatus.actual,
  }) => InventoryBatch(
    id: id,
    ingredientId: id,
    name: name,
    quantity: qty,
    unit: unit,
    storageType: type,
    shelfId: type == StorageType.fridge ? 'middle' : null,
    expiryDate: days == null ? null : today.add(Duration(days: days)),
    expiryStatus: days == null ? ExpiryStatus.unknown : status,
    expirySource: 'sample',
    category: category,
    artKey: id,
    createdAt: today.subtract(const Duration(days: 1)),
    updatedAt: today,
    revision: 1,
  );
  return [
    item('tofu', '두부', 300, 'g', StorageType.fridge, 2, '가공식품'),
    item('kimchi', '김치', 500, 'g', StorageType.fridge, null, '반찬'),
    item(
      'leek',
      '대파',
      100,
      'g',
      StorageType.fridge,
      4,
      '채소',
      status: ExpiryStatus.estimated,
    ),
    item('egg', '달걀', 6, '개', StorageType.fridge, 8, '달걀'),
    item('milk', '우유', 500, 'ml', StorageType.fridge, 3, '유제품'),
    item('carrot', '당근', 2, '개', StorageType.fridge, null, '채소'),
    item('dumpling', '만두', 400, 'g', StorageType.freezer, null, '냉동식품'),
    item('oil', '참기름', 100, 'ml', StorageType.pantry, null, '조미료'),
  ];
}
