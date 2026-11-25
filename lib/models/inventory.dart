import 'dart:convert';

enum StorageType { fridge, freezer, pantry }

enum ExpiryStatus { actual, estimated, unknown }

enum OpenedStatus { unopened, opened, unknown }

enum QuantityMode { measured, status }

enum StockLevel { enough, low, none }

extension StorageTypeLabel on StorageType {
  String get label => switch (this) {
    StorageType.fridge => '냉장',
    StorageType.freezer => '냉동',
    StorageType.pantry => '실온',
  };
}

extension ExpiryStatusLabel on ExpiryStatus {
  String get label => switch (this) {
    ExpiryStatus.actual => '실제 날짜',
    ExpiryStatus.estimated => '추정 날짜',
    ExpiryStatus.unknown => '미상',
  };
}

extension OpenedStatusLabel on OpenedStatus {
  String get label => switch (this) {
    OpenedStatus.unopened => '미개봉',
    OpenedStatus.opened => '개봉',
    OpenedStatus.unknown => '미상',
  };
}

extension StockLevelLabel on StockLevel {
  String get label => switch (this) {
    StockLevel.enough => '충분',
    StockLevel.low => '부족',
    StockLevel.none => '없음',
  };
}

const _unchanged = Object();

/// One purchase/expiry batch. Equal ingredient names never imply one batch.
class InventoryBatch {
  InventoryBatch({
    required this.id,
    required this.name,
    required this.quantity,
    required this.unit,
    this.storageType = StorageType.fridge,
    this.expiryDate,
    this.expiryStatus = ExpiryStatus.unknown,
    this.expirySource = 'manual',
    this.openedStatus = OpenedStatus.unknown,
    this.quantityMode = QuantityMode.measured,
    this.stockLevel = StockLevel.enough,
    this.ingredientId,
    this.category = '기타',
    this.shelfId,
    this.slotId,
    this.artKey = 'generic',
    this.photoFile,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.revision = 0,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  final String id;
  final String name;
  final double quantity;
  final String unit;
  final StorageType storageType;
  final DateTime? expiryDate;
  final ExpiryStatus expiryStatus;
  final String expirySource;
  final OpenedStatus openedStatus;
  final QuantityMode quantityMode;
  final StockLevel stockLevel;
  final String? ingredientId;
  final String category;
  final String? shelfId;
  final String? slotId;
  final String artKey;
  final String? photoFile;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;

  bool get active => quantityMode == QuantityMode.status
      ? stockLevel != StockLevel.none
      : quantity > 0;

  bool availableForUseOn(DateTime now) =>
      active && (daysRemaining(now) ?? 0) >= 0;
  bool get isAvailableForUse => availableForUseOn(DateTime.now());

  String get quantityLabel => quantityMode == QuantityMode.status
      ? stockLevel.label
      : '${formatQuantity(quantity)} $unit';

  int? daysRemaining([DateTime? now]) {
    if (expiryStatus == ExpiryStatus.unknown || expiryDate == null) return null;
    final today = now ?? DateTime.now();
    // UTC calendar dates avoid daylight-saving changes in elapsed hours.
    return DateTime.utc(
      expiryDate!.year,
      expiryDate!.month,
      expiryDate!.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  }

  String expiryLabel([DateTime? now]) {
    final days = daysRemaining(now);
    if (days == null) return '날짜 미상';
    final text = days < 0
        ? '${-days}일 지남'
        : days == 0
        ? '오늘까지'
        : 'D-$days';
    return expiryStatus == ExpiryStatus.estimated ? '추정 $text' : text;
  }

  String get dateLabel => expiryLabel();

  InventoryBatch copyWith({
    String? id,
    String? name,
    double? quantity,
    String? unit,
    StorageType? storageType,
    Object? expiryDate = _unchanged,
    ExpiryStatus? expiryStatus,
    String? expirySource,
    OpenedStatus? openedStatus,
    QuantityMode? quantityMode,
    StockLevel? stockLevel,
    Object? ingredientId = _unchanged,
    String? category,
    Object? shelfId = _unchanged,
    Object? slotId = _unchanged,
    String? artKey,
    Object? photoFile = _unchanged,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? revision,
  }) => InventoryBatch(
    id: id ?? this.id,
    name: name ?? this.name,
    quantity: quantity ?? this.quantity,
    unit: unit ?? this.unit,
    storageType: storageType ?? this.storageType,
    expiryDate: identical(expiryDate, _unchanged)
        ? this.expiryDate
        : expiryDate as DateTime?,
    expiryStatus: expiryStatus ?? this.expiryStatus,
    expirySource: expirySource ?? this.expirySource,
    openedStatus: openedStatus ?? this.openedStatus,
    quantityMode: quantityMode ?? this.quantityMode,
    stockLevel: stockLevel ?? this.stockLevel,
    ingredientId: identical(ingredientId, _unchanged)
        ? this.ingredientId
        : ingredientId as String?,
    category: category ?? this.category,
    shelfId: identical(shelfId, _unchanged) ? this.shelfId : shelfId as String?,
    slotId: identical(slotId, _unchanged) ? this.slotId : slotId as String?,
    artKey: artKey ?? this.artKey,
    photoFile: identical(photoFile, _unchanged)
        ? this.photoFile
        : photoFile as String?,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    revision: revision ?? this.revision,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'quantity': quantity,
    'unit': unit,
    'storageType': storageType.name,
    'expiryDate': expiryDate?.toIso8601String(),
    'expiryStatus': expiryStatus.name,
    'expirySource': expirySource,
    'openedStatus': openedStatus.name,
    'quantityMode': quantityMode.name,
    'stockLevel': stockLevel.name,
    'ingredientId': ingredientId,
    'category': category,
    'shelfId': shelfId,
    'slotId': slotId,
    'artKey': artKey,
    'photoFile': photoFile,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'revision': revision,
  };

  factory InventoryBatch.fromJson(Map<String, dynamic> json) => InventoryBatch(
    id: json['id'] as String,
    name: json['name'] as String,
    quantity: (json['quantity'] as num).toDouble(),
    unit: json['unit'] as String,
    storageType: StorageType.values.byName(json['storageType'] as String),
    expiryDate: json['expiryDate'] == null
        ? null
        : DateTime.parse(json['expiryDate'] as String),
    expiryStatus: ExpiryStatus.values.byName(
      json['expiryStatus'] as String? ?? 'unknown',
    ),
    expirySource: json['expirySource'] as String? ?? 'manual',
    openedStatus: OpenedStatus.values.byName(
      json['openedStatus'] as String? ?? 'unknown',
    ),
    quantityMode: QuantityMode.values.byName(
      json['quantityMode'] as String? ?? 'measured',
    ),
    stockLevel: StockLevel.values.byName(
      json['stockLevel'] as String? ?? 'enough',
    ),
    ingredientId: json['ingredientId'] as String?,
    category: json['category'] as String? ?? '기타',
    shelfId: json['shelfId'] as String?,
    slotId: json['slotId'] as String?,
    artKey: json['artKey'] as String? ?? 'generic',
    photoFile: json['photoFile'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    revision: json['revision'] as int? ?? 0,
  );

  bool hasSameSnapshot(InventoryBatch other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

class InventoryChange {
  const InventoryChange({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.before,
    required this.after,
    this.action = 'update',
    this.source = 'manual',
    this.requestId,
    this.undone = false,
  });
  final String id;
  final String label;
  final DateTime createdAt;
  final List<InventoryBatch> before;
  final List<InventoryBatch> after;
  final String action;
  final String source;
  final String? requestId;
  final bool undone;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'createdAt': createdAt.toIso8601String(),
    'before': before.map((b) => b.toJson()).toList(),
    'after': after.map((b) => b.toJson()).toList(),
    'action': action,
    'source': source,
    'requestId': requestId,
    'undone': undone,
  };

  InventoryChange withUndone() => InventoryChange(
    id: id,
    label: label,
    createdAt: createdAt,
    before: before,
    after: after,
    action: action,
    source: source,
    requestId: requestId,
    undone: true,
  );

  factory InventoryChange.fromJson(Map<String, dynamic> json) =>
      InventoryChange(
        id: json['id'] as String,
        label: json['label'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        before: (json['before'] as List)
            .map(
              (e) =>
                  InventoryBatch.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(),
        after: (json['after'] as List)
            .map(
              (e) =>
                  InventoryBatch.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(),
        action: json['action'] as String,
        source: json['source'] as String,
        requestId: json['requestId'] as String?,
        undone: json['undone'] as bool? ?? false,
      );
}

/// Keep the round-trippable quantity when a field's unit changes (e.g. g to kg).
String formatQuantity(double value) {
  if (value == 0) return '0';
  final number = value.toString();
  final e = number.indexOf('e');
  if (e < 0) {
    return number.endsWith('.0')
        ? number.substring(0, number.length - 2)
        : number;
  }
  final negative = number.startsWith('-');
  final mantissa = number.substring(negative ? 1 : 0, e);
  final dot = mantissa.indexOf('.');
  final digits = mantissa.replaceAll('.', '');
  final point =
      (dot < 0 ? digits.length : dot) + int.parse(number.substring(e + 1));
  final String decimal;
  if (point <= 0) {
    decimal = '0.${'0' * -point}$digits';
  } else if (point >= digits.length) {
    decimal = digits.padRight(point, '0');
  } else {
    decimal = '${digits.substring(0, point)}.${digits.substring(point)}';
  }
  return negative ? '-$decimal' : decimal;
}

/// Subtract the entered decimal quantities without introducing binary rounding
/// residue in inventory (e.g. 0.3 - 0.1) or rounding small servings to zero.
double remainingQuantity(double available, double used) {
  final a = formatQuantity(available).split('.');
  final b = formatQuantity(used).split('.');
  final af = a.length == 2 ? a[1] : '';
  final bf = b.length == 2 ? b[1] : '';
  final scale = af.length > bf.length ? af.length : bf.length;
  final difference =
      BigInt.parse(a.first + af.padRight(scale, '0')) -
      BigInt.parse(b.first + bf.padRight(scale, '0'));
  return double.parse('${difference}e-$scale');
}

/// No package, count, mass or volume cross-conversion without product evidence.
double convertQuantity(double quantity, String from, String to) {
  if (!quantity.isFinite || quantity < 0) {
    throw ArgumentError('유효한 수량을 입력해주세요.');
  }
  if (from == to) return quantity;
  const mass = {'g': 1.0, 'kg': 1000.0};
  const volume = {'ml': 1.0, 'L': 1000.0};
  for (final factors in [mass, volume]) {
    if (factors.containsKey(from) && factors.containsKey(to)) {
      return quantity * factors[from]! / factors[to]!;
    }
  }
  throw ArgumentError('$from → $to 환산 정보가 없어요. 사용할 수량과 단위를 직접 확인해주세요.');
}

/// Earliest dated batches first; unknown dates last, then oldest receipt.
int compareBatchExpiry(InventoryBatch a, InventoryBatch b) {
  final ad = a.expiryStatus == ExpiryStatus.unknown ? null : a.expiryDate;
  final bd = b.expiryStatus == ExpiryStatus.unknown ? null : b.expiryDate;
  if (ad == null && bd != null) return 1;
  if (ad != null && bd == null) return -1;
  final byDate = ad != null && bd != null ? ad.compareTo(bd) : 0;
  if (byDate != 0) return byDate;
  final byReceipt = a.createdAt.compareTo(b.createdAt);
  return byReceipt != 0 ? byReceipt : a.id.compareTo(b.id);
}
