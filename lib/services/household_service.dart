import 'dart:convert';

import '../models/inventory.dart';
import 'inventory_store.dart';

class HouseholdSnapshot {
  HouseholdSnapshot({
    required this.id,
    required this.generatedAt,
    required List<InventoryBatch> batches,
    required this.targetDemo,
  }) : batches = List.unmodifiable(batches);
  final String id;
  final DateTime generatedAt;
  final List<InventoryBatch> batches;
  final bool targetDemo;
  String get requestId => 'household-import:$id';
}

/// Prepared local sharing demo. No account, network sync or remote editing.
class HouseholdService {
  HouseholdService(this.store);
  final InventoryStore store;
  String exportSnapshot() {
    final now = DateTime.now();
    final result = const JsonEncoder.withIndent('  ').convert({
      'format': 'itkan-household',
      'version': 1,
      'snapshotId': 'snapshot-${now.microsecondsSinceEpoch}',
      'generatedAt': now.toIso8601String(),
      'sourceMode': store.isDemo ? 'demo' : 'personal',
      // Local photos are not attachments in the text-only sharing format.
      'batches': store.activeBatches
          .map((b) => b.copyWith(photoFile: null).toJson())
          .toList(),
    });
    // Export and import are the same contract. Never offer a snapshot that
    // another copy of this app cannot preview (count, size, units or fields).
    preview(result);
    return result;
  }

  HouseholdSnapshot preview(String text) {
    if (utf8.encode(text).length > 300000) {
      throw const FormatException('스냅샷이 너무 커요. 300KB 이내 자료만 지원합니다.');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map ||
        decoded['format'] != 'itkan-household' ||
        decoded['version'] != 1) {
      throw const FormatException('잇칸 공유 스냅샷 형식이 아니에요.');
    }
    final id = decoded['snapshotId'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('스냅샷 식별자가 올바르지 않아요.');
    }
    final date = decoded['generatedAt'];
    final generated = date is String ? DateTime.tryParse(date) : null;
    if (generated == null) throw const FormatException('스냅샷 생성 날짜를 확인할 수 없어요.');
    final list = decoded['batches'];
    if (list is! List || list.isEmpty || list.length > 200) {
      throw const FormatException('가져올 묶음은 1~200개여야 합니다.');
    }
    final originalIds = <String>{};
    final batches = <InventoryBatch>[];
    for (var i = 0; i < list.length; i++) {
      final data = list[i];
      if (data is! Map) throw const FormatException('재료 형식을 확인할 수 없어요.');
      final name = data['name'],
          quantity = data['quantity'],
          unit = data['unit'],
          batchId = data['id'];
      if (batchId is! String || batchId.isEmpty || !originalIds.add(batchId)) {
        throw const FormatException('중복되거나 없는 묶음 식별자입니다.');
      }
      if (name is! String ||
          name.trim().isEmpty ||
          name.length > 40 ||
          quantity is! num ||
          !quantity.isFinite ||
          quantity < 0 ||
          quantity > 1000000 ||
          unit is! String ||
          !{'개', '팩', '봉', '병', '캔', 'g', 'kg', 'ml', 'L'}.contains(unit)) {
        throw const FormatException('재료 이름·수량·단위를 확인해주세요.');
      }
      final storage = StorageType.values
          .where((v) => v.name == data['storageType'])
          .firstOrNull;
      final status = ExpiryStatus.values
          .where((v) => v.name == data['expiryStatus'])
          .firstOrNull;
      final opened = OpenedStatus.values
          .where((v) => v.name == (data['openedStatus'] ?? 'unknown'))
          .firstOrNull;
      final mode = QuantityMode.values
          .where((v) => v.name == (data['quantityMode'] ?? 'measured'))
          .firstOrNull;
      final level = StockLevel.values
          .where((v) => v.name == (data['stockLevel'] ?? 'enough'))
          .firstOrNull;
      if (storage == null ||
          status == null ||
          opened == null ||
          mode == null ||
          level == null) {
        throw const FormatException('보관 위치 또는 상태가 올바르지 않아요.');
      }
      final expiryRaw = data['expiryDate'];
      final expiry = expiryRaw is String ? DateTime.tryParse(expiryRaw) : null;
      if (status != ExpiryStatus.unknown && expiry == null) {
        throw const FormatException('실제·추정 날짜에는 유효한 날짜가 필요해요.');
      }
      if (mode == QuantityMode.measured && quantity <= 0) {
        throw const FormatException('수량형 재료는 0보다 큰 수량만 가져올 수 있어요.');
      }
      if (mode == QuantityMode.status && level == StockLevel.none) {
        throw const FormatException('소진된 상태형 재료는 가져오지 않습니다.');
      }
      final shelf = data['shelfId'];
      final slot = data['slotId'];
      if ((shelf != null && shelf is! String) ||
          (slot != null && slot is! String)) {
        throw const FormatException('재료의 선반 위치를 확인해주세요.');
      }
      final originalDate = data['createdAt'];
      final stockedAt = originalDate is String
          ? DateTime.tryParse(originalDate)
          : null;
      if (originalDate != null && stockedAt == null) {
        throw const FormatException('재료의 입고 날짜를 확인해주세요.');
      }
      batches.add(
        InventoryBatch(
          id: 'shared-$id-$i',
          name: name.trim(),
          quantity: mode == QuantityMode.status ? 1 : quantity.toDouble(),
          unit: unit,
          storageType: storage,
          shelfId: shelf as String?,
          slotId: slot as String?,
          expiryStatus: status,
          expiryDate: status == ExpiryStatus.unknown ? null : expiry,
          expirySource: 'shared_snapshot',
          openedStatus: opened,
          quantityMode: mode,
          stockLevel: level,
          category: data['category'] is String && data['category'].length <= 30
              ? data['category']
              : '기타',
          createdAt: stockedAt ?? generated,
        ),
      );
    }
    return HouseholdSnapshot(
      id: id,
      generatedAt: generated,
      batches: batches,
      targetDemo: store.isDemo,
    );
  }

  bool alreadyImported(HouseholdSnapshot snapshot) =>
      store.history.any((h) => h.requestId == snapshot.requestId);
  Future<bool> importApproved(
    HouseholdSnapshot snapshot, {
    required bool approved,
  }) async {
    if (!approved) throw StateError('입고 내용을 확인한 뒤 가져올 수 있어요.');
    if (snapshot.targetDemo != store.isDemo) {
      throw StateError('보관함 모드가 바뀌었어요. 다시 미리보기를 확인해주세요.');
    }
    if (alreadyImported(snapshot)) return false;
    await store.addMany(
      snapshot.batches,
      source: 'household_snapshot',
      requestId: snapshot.requestId,
    );
    return true;
  }
}
