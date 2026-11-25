import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';
import '../services/inventory_store.dart';
import '../widgets/common.dart';

class OrderLine {
  OrderLine({
    required this.id,
    required this.name,
    required this.unit,
    this.ordered,
    this.received,
    this.selected = true,
    this.cancelled = false,
  });
  final String id;
  String name, unit;
  double? ordered, received;
  bool selected, cancelled;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'unit': unit,
    'ordered': ordered,
    'received': received,
    'selected': selected,
    'cancelled': cancelled,
  };
  factory OrderLine.fromJson(Map<String, dynamic> j) => OrderLine(
    id: j['id'] as String,
    name: j['name'] as String,
    unit: j['unit'] as String,
    ordered: (j['ordered'] as num?)?.toDouble(),
    received: (j['received'] as num?)?.toDouble(),
    selected: j['selected'] == true,
    cancelled: j['cancelled'] == true,
  );
}

class OrderPreview {
  OrderPreview({
    required this.id,
    required this.source,
    required this.status,
    required this.lines,
  });
  final String id, source;
  String status;
  List<OrderLine> lines;
  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'status': status,
    'lines': lines.map((l) => l.toJson()).toList(),
  };
  factory OrderPreview.fromJson(Map<String, dynamic> j) => OrderPreview(
    id: j['id'] as String,
    source: j['source'] as String,
    status: j['status'] as String,
    lines: (j['lines'] as List)
        .map((l) => OrderLine.fromJson(Map<String, dynamic>.from(l as Map)))
        .toList(),
  );
}

const orderStatuses = {
  'ordered': '주문 확인',
  'shipping': '배송 중',
  'partial': '부분 배송',
  'delivered': '배송 완료',
  'cancelled': '주문 취소',
  'returned': '반품',
};

/// Retains only product fields and a digest for deduplication, never contacts,
/// delivery address, original order number or the raw pasted source.
OrderPreview parseOrderJson(String raw, {String source = '직접 붙여넣기'}) {
  if (raw.length > 30000) {
    throw const FormatException('주문 예시는 30,000자 이내로 넣어주세요.');
  }
  dynamic j;
  try {
    j = jsonDecode(raw);
  } on FormatException {
    // Do not echo an invalid raw payload (which may contain contact details).
    throw const FormatException('JSON 문법을 확인해주세요. 원문은 저장하지 않았습니다.');
  }
  if (j is! Map ||
      j['orderId'] is! String ||
      (j['orderId'] as String).trim().isEmpty ||
      j['items'] is! List) {
    throw const FormatException('orderId와 items 목록이 필요합니다.');
  }
  final status = j['status'] as String? ?? 'ordered';
  if (!orderStatuses.containsKey(status)) {
    throw const FormatException('지원하지 않는 배송 상태입니다.');
  }
  final items = j['items'] as List;
  if (items.isEmpty || items.length > 50) {
    throw const FormatException('1~50개 품목을 넣어주세요.');
  }
  final digest = sha256
      .convert(
        utf8.encode(
          '${j['source'] ?? 'unknown-merchant'}:${(j['orderId'] as String).trim()}',
        ),
      )
      .toString();
  final ids = <String>{};
  final lines = <OrderLine>[];
  for (var i = 0; i < items.length; i++) {
    final e = items[i];
    if (e is! Map) throw const FormatException('품목 형식을 확인해주세요.');
    // A missing line ID falls back to product identity, not list position:
    // reordered email/notification items must not create new admissions.
    final id = (e['itemId'] ?? '${e['name'] ?? ''}|${e['unit'] ?? '개'}')
        .toString();
    if (!ids.add(id)) throw const FormatException('같은 주문에 중복 itemId가 있어요.');
    double? number(dynamic v) =>
        v is num && v.isFinite && v > 0 ? v.toDouble() : null;
    final quantity = number(e['quantity']);
    // An explicit zero/invalid delivery count must never become the ordered
    // amount just because the enclosing order says "delivered".
    final delivered = e['deliveredQuantity'];
    final received = e.containsKey('deliveredQuantity')
        ? (delivered is num && delivered.isFinite && delivered >= 0
              ? delivered.toDouble()
              : null)
        : (status == 'delivered' ? quantity : null);
    final cancelled = e['cancelled'] == true || e['returned'] == true;
    lines.add(
      OrderLine(
        id: sha256.convert(utf8.encode(id)).toString().substring(0, 16),
        name: e['name'] is String ? (e['name'] as String).trim() : '',
        unit: e['unit'] is String ? e['unit'] as String : '개',
        ordered: quantity,
        received: received,
        cancelled: cancelled,
        selected: !cancelled,
      ),
    );
  }
  return OrderPreview(id: digest, source: source, status: status, lines: lines);
}

double admittedOrderQuantity(
  OrderPreview order,
  OrderLine line,
  List<InventoryChange> history,
) {
  final key = 'order:${order.id}:${line.id}';
  double total = 0;
  for (final change in history.where(
    (h) => h.action == 'add' && h.source == 'order' && !h.undone,
  )) {
    for (final batch in change.after.where((b) => b.ingredientId == key)) {
      if (batch.unit != line.unit) {
        throw StateError('이전에 승인한 단위와 달라요. 단위를 ${batch.unit}로 확인해주세요.');
      }
      total += batch.quantity;
    }
  }
  return total;
}

List<InventoryBatch> buildOrderAdmission(
  OrderPreview order,
  List<InventoryChange> history, {
  DateTime? now,
}) {
  if (!['delivered', 'partial'].contains(order.status)) {
    throw StateError('실제로 배송받은 주문만 입고할 수 있어요.');
  }
  final result = <InventoryBatch>[];
  for (final line in order.lines.where((l) => l.selected && !l.cancelled)) {
    if (line.name.trim().isEmpty ||
        line.received == null ||
        !line.received!.isFinite ||
        line.received! < 0 ||
        line.unit.trim().isEmpty) {
      throw ArgumentError('선택한 품목의 이름·실제 받은 수량·단위를 먼저 확인해주세요.');
    }
    if (line.ordered != null && line.received! > line.ordered!) {
      throw ArgumentError('받은 수량이 주문 수량보다 많아요. 후보를 수정해주세요.');
    }
    final previous = admittedOrderQuantity(order, line, history);
    final delta = line.received! - previous;
    if (delta <= 0) continue;
    final key = 'order:${order.id}:${line.id}';
    final targetId = '$key:${line.received}';
    // A previously reversed approval keeps its request ID in durable storage.
    // Count every saved attempt for this target, including active later installments.
    final approvals = history
        .where((h) => h.action == 'add' && h.source == 'order')
        .expand((h) => h.after)
        .where(
          (b) => b.id == targetId || b.id.startsWith('$targetId:reapproval:'),
        )
        .length;
    result.add(
      InventoryBatch(
        id: approvals == 0 ? targetId : '$targetId:reapproval:$approvals',
        ingredientId: key,
        name: line.name,
        quantity: delta,
        unit: line.unit,
        storageType: StorageType.fridge,
        expiryStatus: ExpiryStatus.unknown,
        expirySource: 'order',
        createdAt: now,
      ),
    );
  }
  return result;
}

String orderApprovalId(List<InventoryBatch> batches) =>
    'order-approval:${sha256.convert(utf8.encode((batches.map((b) => b.id).toList()..sort()).join('|')))}';

const sampleOrder =
    '''{"source":"sample-shop","orderId":"DEMO-1106","status":"partial","items":[{"itemId":"milk","name":"우유","quantity":2,"deliveredQuantity":1,"unit":"팩"},{"itemId":"tofu","name":"두부","quantity":1,"unit":"개"},{"itemId":"cancel","name":"당근","quantity":2,"unit":"개","cancelled":true}]}''';

class OrderImportScreen extends StatefulWidget {
  const OrderImportScreen({super.key, required this.store});
  final InventoryStore store;
  @override
  State<OrderImportScreen> createState() => _OrderImportScreenState();
}

class _OrderImportScreenState extends State<OrderImportScreen> {
  late final bool screenDemo = widget.store.isDemo;
  List<OrderPreview> pending = [];
  bool busy = false, physicallyReceived = false;
  String? error;
  OrderPreview? selected;
  String get key => 'order_candidates_${screenDemo ? 'demo' : 'real'}';
  void checkMode() {
    if (screenDemo != widget.store.isDemo) {
      throw StateError('보관함 모드가 바뀌었어요. 주문 후보 화면을 다시 열어주세요.');
    }
  }

  void storeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.store.addListener(storeChanged);
    load();
  }

  @override
  void dispose() {
    widget.store.removeListener(storeChanged);
    super.dispose();
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final rows = jsonDecode(p.getString(key) ?? '[]') as List;
      if (mounted) {
        setState(
          () => pending = rows
              .map(
                (e) =>
                    OrderPreview.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '대기 후보를 읽지 못했어요: $e');
    }
  }

  Future<void> persist() async {
    final p = await SharedPreferences.getInstance();
    checkMode();
    if (!await p.setString(
      key,
      jsonEncode(pending.map((o) => o.toJson()).toList()),
    )) {
      throw StateError('검토 후보를 저장하지 못했어요.');
    }
  }

  Future<void> import(String raw, String source) async {
    try {
      checkMode();
      final order = parseOrderJson(raw, source: source);
      setState(() {
        pending.removeWhere((p) => p.id == order.id);
        pending.add(order);
        selected = order;
        physicallyReceived = false;
        error = null;
      });
      await persist();
    } catch (e) {
      if (mounted) setState(() => error = '후보를 만들지 못했어요: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('주문 후보 실험')),
    body: screenDemo != widget.store.isDemo
        ? const Padding(
            padding: EdgeInsets.all(20),
            child: InfoBox(
              '보관함 모드가 바뀌었어요. 이 화면을 닫고 주문 후보를 다시 열어주세요. 이전 모드의 후보는 입고하지 않습니다.',
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const InfoBox(
                '샘플·직접 붙여넣기 시연입니다. 실제 이메일·Android 알림·쇼핑 계정에 연결하지 않습니다. 배송 완료만으로 재고를 자동 등록하지 않아요.',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: busy || !widget.store.isDemo
                        ? null
                        : () => import(sampleOrder, '샘플 이메일'),
                    child: const Text('샘플 주문 불러오기'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : paste,
                    child: const Text('주문 JSON 붙여넣기'),
                  ),
                ],
              ),
              if (!widget.store.isDemo)
                const InfoBox(
                  '준비된 샘플 주문은 샘플 모드에서만 불러옵니다. 내 재고에는 직접 확인한 주문 JSON을 넣어주세요.',
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (pending.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '검토 대기함 ${pending.length}건',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                ...pending.map(
                  (o) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    selected: identical(o, selected),
                    title: Text('${o.source} · ${orderStatuses[o.status]}'),
                    subtitle: Text(
                      '${o.lines.length}개 후보 · 식별 ${o.id.substring(0, 6)}',
                    ),
                    onTap: () => setState(() {
                      selected = o;
                      physicallyReceived = false;
                    }),
                    trailing: IconButton(
                      tooltip: '후보 삭제',
                      onPressed: busy
                          ? null
                          : () async {
                              setState(() {
                                pending.remove(o);
                                if (identical(selected, o)) selected = null;
                              });
                              await persist();
                            },
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ),
              ],
              if (selected != null) ...[
                const Divider(),
                DropdownButtonFormField<String>(
                  key: ValueKey('${selected!.id}-${selected!.status}'),
                  initialValue: selected!.status,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '확인한 배송 상태'),
                  items: orderStatuses.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: busy
                      ? null
                      : (v) async {
                          setState(() {
                            selected!.status = v!;
                            physicallyReceived = false;
                          });
                          await persist();
                        },
                ),
                const InfoBox(
                  '부분 배송은 지금까지 실제 받은 누적 수량을 입력하세요. 이전에 승인한 수량을 제외하고 새로 받은 양만 입고합니다. 취소·반품 항목은 제외합니다.',
                ),
                ...selected!.lines.map((line) {
                  double admitted = 0;
                  try {
                    admitted = admittedOrderQuantity(
                      selected!,
                      line,
                      widget.store.history,
                    );
                  } catch (_) {}
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Checkbox(
                                value: line.selected && !line.cancelled,
                                onChanged: busy || line.cancelled
                                    ? null
                                    : (v) async {
                                        setState(() => line.selected = v!);
                                        await persist();
                                      },
                              ),
                              Expanded(
                                child: Text(
                                  line.name.isEmpty ? '품목 확인 필요' : line.name,
                                ),
                              ),
                              TextButton(
                                onPressed: busy || line.cancelled
                                    ? null
                                    : () => edit(line),
                                child: const Text('수정'),
                              ),
                            ],
                          ),
                          Text(
                            line.cancelled
                                ? '취소·반품으로 제외'
                                : '주문 ${line.ordered == null ? '미상' : formatQuantity(line.ordered!)}${line.unit} · 받은 누적 ${line.received == null ? '확인 필요' : formatQuantity(line.received!)}${line.unit}',
                          ),
                          if (admitted > 0)
                            Text(
                              '이미 승인 ${formatQuantity(admitted)}${line.unit}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  );
                }),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('선택한 재료를 실제로 받았어요'),
                  subtitle: const Text('주문·배송 상태와 별도로 실제 입고를 확인합니다.'),
                  value: physicallyReceived,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => physicallyReceived = v!),
                ),
                FilledButton(
                  onPressed: busy || !physicallyReceived ? null : approve,
                  child: Text(busy ? '입고 중…' : '선택 항목 입고 확인'),
                ),
                const InfoBox(
                  '소비기한은 미상으로 입고합니다. 보관 위치는 기본 냉장이며 입고 후 상세에서 변경할 수 있어요. 원문·연락처·주소는 저장하지 않습니다.',
                ),
              ],
              if (pending.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('검토할 주문 후보가 없어요. 샘플이나 JSON을 불러와 흐름을 확인해보세요.'),
                ),
            ],
          ),
  );
  Future<void> paste() async {
    final c = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('주문 JSON 붙여넣기'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '필수: orderId, items. 각 항목: itemId, name, quantity, unit. 부분배송: deliveredQuantity.\n개인 연락처·주소는 넣지 마세요.',
              ),
              TextField(
                controller: c,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: '{"orderId":"1","status":"delivered","items":[{"name":"우유","quantity":1,"unit":"팩"}]}',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('후보 만들기'),
          ),
        ],
      ),
    );
    if (raw != null) await import(raw, '직접 붙여넣기');
    c.clear();
  }

  Future<void> edit(OrderLine line) async {
    final name = TextEditingController(text: line.name),
        qty = TextEditingController(text: line.ordered?.toString() ?? ''),
        received = TextEditingController(text: line.received?.toString() ?? '');
    var unit = line.unit;
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('주문 후보 수정'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '재료 이름'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '이름을 확인해주세요.' : null,
                ),
                TextFormField(
                  controller: qty,
                  decoration: const InputDecoration(labelText: '주문 수량 (미상 가능)'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                TextFormField(
                  controller: received,
                  decoration: const InputDecoration(labelText: '실제로 받은 누적 수량'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) {
                    final n = double.tryParse(v ?? '');
                    return n == null || !n.isFinite || n < 0
                        ? '실제로 받은 수량을 0 이상으로 입력해주세요.'
                        : null;
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: unit,
                  isExpanded: true,
                  items: {'개', '팩', 'g', 'kg', 'ml', 'L', unit}
                      .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                      .toList(),
                  onChanged: (v) => unit = v!,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, true);
            },
            child: const Text('수정 완료'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        line.name = name.text.trim();
        line.ordered = double.tryParse(qty.text);
        line.received = double.parse(received.text);
        line.unit = unit;
        physicallyReceived = false;
      });
      await persist();
    }
  }

  Future<void> approve() async {
    if (busy || selected == null) return;
    final order = selected!;
    setState(() => busy = true);
    try {
      checkMode();
      final batches = buildOrderAdmission(order, widget.store.history);
      if (batches.isEmpty) {
        inform(context, '새로 입고할 항목이 없어요. 이미 승인한 주문이거나 선택 항목이 없습니다.');
        return;
      }
      if (!await confirm(
        context,
        '실제 입고 확인',
        batches
            .map((b) => '${b.name} ${b.quantityLabel} · 냉장 · 날짜 미상')
            .join('\n'),
        action: '확인하고 입고',
      )) {
        return;
      }
      if (!mounted) return;
      checkMode();
      final latest = buildOrderAdmission(order, widget.store.history);
      if (jsonEncode(
            latest.map((b) => {'id': b.id, 'qty': b.quantity}).toList(),
          ) !=
          jsonEncode(
            batches.map((b) => {'id': b.id, 'qty': b.quantity}).toList(),
          )) {
        throw StateError('확인 중 주문 입고 내역이 바뀌었어요. 다시 확인해주세요.');
      }
      await widget.store.addMany(
        batches,
        source: 'order',
        expectedDemo: screenDemo,
        requestId: orderApprovalId(batches),
      );
      if (mounted) {
        setState(() => physicallyReceived = false);
        inform(context, '새로 받은 ${batches.length}개 항목을 입고했어요.');
      }
    } catch (e) {
      if (mounted) inform(context, '입고하지 못했어요: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
