import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';

/// Geometric outer-box estimates only. Inventory mass is never converted.
class BoxDimensions {
  const BoxDimensions({
    required this.widthCm,
    required this.heightCm,
    required this.depthCm,
  });
  final double widthCm, heightCm, depthCm;
  bool get valid =>
      [widthCm, heightCm, depthCm].every((n) => n.isFinite && n > 0) &&
      litres.isFinite;
  double get litres => widthCm * heightCm * depthCm / 1000;
  Map<String, dynamic> toJson() => {
    'widthCm': widthCm,
    'heightCm': heightCm,
    'depthCm': depthCm,
  };
  factory BoxDimensions.fromJson(Map<String, dynamic> j) => BoxDimensions(
    widthCm: (j['widthCm'] as num).toDouble(),
    heightCm: (j['heightCm'] as num).toDouble(),
    depthCm: (j['depthCm'] as num).toDouble(),
  );
}

class PackageMeasurement {
  const PackageMeasurement({
    required this.batchId,
    required this.box,
    required this.packages,
    required this.quantityAtMeasurement,
    required this.unitAtMeasurement,
    required this.source,
  });
  final String batchId;
  final BoxDimensions box;
  final int packages;
  final double quantityAtMeasurement;
  final String unitAtMeasurement;
  final String source;
  double get litres => box.litres * packages;
  bool get valid => box.valid && packages > 0 && litres.isFinite;
  bool matches(InventoryBatch b) =>
      b.id == batchId &&
      b.quantity == quantityAtMeasurement &&
      b.unit == unitAtMeasurement;
  Map<String, dynamic> toJson() => {
    'batchId': batchId,
    'box': box.toJson(),
    'packages': packages,
    'quantityAtMeasurement': quantityAtMeasurement,
    'unitAtMeasurement': unitAtMeasurement,
    'source': source,
  };
  factory PackageMeasurement.fromJson(Map<String, dynamic> j) =>
      PackageMeasurement(
        batchId: j['batchId'] as String,
        box: BoxDimensions.fromJson(Map<String, dynamic>.from(j['box'] as Map)),
        packages: j['packages'] as int,
        quantityAtMeasurement: (j['quantityAtMeasurement'] as num).toDouble(),
        unitAtMeasurement: j['unitAtMeasurement'] as String,
        source: j['source'] as String,
      );
}

class CapacityEstimate {
  const CapacityEstimate({
    required this.capacityLitres,
    required this.knownLitres,
    required this.totalCount,
    required this.measuredCount,
    required this.staleCount,
  });
  final double capacityLitres, knownLitres;
  final int totalCount, measuredCount, staleCount;
  int get unknownCount => totalCount - measuredCount;
  double get coverage => totalCount == 0 ? 0 : measuredCount / totalCount;
  double get ratio => knownLitres / capacityLitres;
  double get arithmeticRemaining => capacityLitres - knownLitres;
}

CapacityEstimate estimateCapacity({
  required List<InventoryBatch> batches,
  required StorageType storage,
  required BoxDimensions space,
  required Map<String, PackageMeasurement> measurements,
}) {
  if (!space.valid) throw ArgumentError('공간의 가로·높이·깊이를 양수로 입력해주세요.');
  final active = batches
      .where((b) => b.active && b.storageType == storage)
      .toList();
  var litres = 0.0, count = 0, stale = 0;
  for (final b in active) {
    final m = measurements[b.id];
    if (m == null || !m.valid) continue;
    if (!m.matches(b)) {
      stale++;
      continue;
    }
    litres += m.litres;
    count++;
  }
  return CapacityEstimate(
    capacityLitres: space.litres,
    knownLitres: litres,
    totalCount: active.length,
    measuredCount: count,
    staleCount: stale,
  );
}

class CapacityData {
  CapacityData({
    Map<StorageType, BoxDimensions>? spaces,
    Map<StorageType, String>? spaceSources,
    Map<String, PackageMeasurement>? measurements,
  }) : spaces = spaces ?? {},
       spaceSources = spaceSources ?? {},
       measurements = measurements ?? {};
  final Map<StorageType, BoxDimensions> spaces;
  final Map<StorageType, String> spaceSources;
  final Map<String, PackageMeasurement> measurements;
  Map<String, dynamic> toJson() => {
    'spaces': spaces.map((k, v) => MapEntry(k.name, v.toJson())),
    'spaceSources': spaceSources.map((k, v) => MapEntry(k.name, v)),
    'measurements': measurements.map((k, v) => MapEntry(k, v.toJson())),
  };
  factory CapacityData.fromJson(Map<String, dynamic> j) => CapacityData(
    spaces: (j['spaces'] as Map).map(
      (k, v) => MapEntry(
        StorageType.values.byName(k as String),
        BoxDimensions.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
    spaceSources: (j['spaceSources'] as Map).map(
      (k, v) => MapEntry(StorageType.values.byName(k as String), v as String),
    ),
    measurements: (j['measurements'] as Map).map(
      (k, v) => MapEntry(
        k as String,
        PackageMeasurement.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    ),
  );
}

class CapacityService {
  String _key(bool demo) => 'capacity_v1_${demo ? 'demo' : 'personal'}';
  Future<CapacityData> load({required bool demo}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(demo));
    if (raw == null) return CapacityData();
    return CapacityData.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  }

  Future<void> save(CapacityData data, {required bool demo}) async {
    if (data.spaces.values.any((s) => !s.valid) ||
        data.measurements.values.any((m) => !m.valid)) {
      throw ArgumentError('유효한 치수와 포장 개수가 필요합니다.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key(demo), jsonEncode(data.toJson()))) {
      throw StateError('용량 정보를 저장하지 못했습니다.');
    }
  }
}
