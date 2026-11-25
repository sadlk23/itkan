import 'package:flutter/material.dart';

import '../design/app_theme.dart';
import '../design/food_illustration.dart';
import '../models/inventory.dart';
import '../services/capacity_service.dart';
import '../services/inventory_store.dart';

class CapacityScreen extends StatefulWidget {
  const CapacityScreen({super.key, required this.store});
  final InventoryStore store;
  @override
  State<CapacityScreen> createState() => _CapacityScreenState();
}

class _CapacityScreenState extends State<CapacityScreen> {
  final _service = CapacityService();
  late final bool _demo = widget.store.isDemo;
  CapacityData? _data;
  StorageType _storage = StorageType.fridge;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _service.load(demo: _demo);
      if (mounted) setState(() => _data = d);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '저장된 용량 정보를 읽지 못했어요. 기존 정보는 지우지 않았습니다.');
      }
    }
  }

  String _place(StorageType s) => s == StorageType.pantry ? '팬트리' : s.label;
  String _number(double n) => n.toStringAsFixed(2);
  Future<void> _save(CapacityData next) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _service.save(next, demo: _demo);
      if (mounted) {
        setState(() {
          _data = next;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '저장하지 못했어요. 다시 입력해 저장해주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  CapacityData _copy() => CapacityData.fromJson(_data!.toJson());

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('참고용 용량 안내')),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: widget.store,
        builder: (context, _) {
          if (widget.store.isDemo != _demo) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('보관함 모드가 바뀌었어요. 뒤로 돌아가 다시 열어주세요.'),
              ),
            );
          }
          if (_data == null) {
            return Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          FilledButton(
                            onPressed: _load,
                            child: const Text('다시 시도'),
                          ),
                        ],
                      ),
                    ),
            );
          }
          final batches = widget.store.activeBatches
              .where((b) => b.storageType == _storage)
              .toList();
          final space = _data!.spaces[_storage];
          final estimate = space == null
              ? null
              : estimateCapacity(
                  batches: widget.store.batches,
                  storage: _storage,
                  space: space,
                  measurements: _data!.measurements,
                );
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_busy) const LinearProgressIndicator(),
              const Text(
                '포장 크기로 살펴보는\n대략적인 공간',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '직접 입력한 포장의 바깥 치수로 계산해요. 실제 냉장고의 빈 공간을 측정하는 기능은 아닙니다.',
                style: TextStyle(color: FridgeTheme.muted),
              ),
              const SizedBox(height: 15),
              Wrap(
                spacing: 8,
                children: StorageType.values
                    .map(
                      (s) => ChoiceChip(
                        label: Text(_place(s)),
                        selected: _storage == s,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _storage = s),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${_place(_storage)} 수납 공간',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (space == null)
                        const Text('먼저 사용할 공간의 안쪽 치수를 입력해주세요.')
                      else ...[
                        Text(
                          '${_number(space.litres)} L',
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: FridgeTheme.sage,
                          ),
                        ),
                        Text(
                          '${space.widthCm} × ${space.heightCm} × ${space.depthCm} cm',
                        ),
                        Text(
                          _data!.spaceSources[_storage] == 'preparedDemo'
                              ? '준비한 예시 공간 · 실제 제품 용량 아님'
                              : '사용자가 입력한 직육면체 치수',
                          style: const TextStyle(
                            fontSize: 12,
                            color: FridgeTheme.muted,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _busy ? null : () => _editDimensions(),
                        child: Text(space == null ? '공간 치수 입력' : '공간 치수 수정'),
                      ),
                      if (_demo)
                        TextButton(
                          onPressed: _busy ? null : _prepareDemo,
                          child: const Text('준비한 사례로 체험하기'),
                        ),
                    ],
                  ),
                ),
              ),
              if (estimate != null) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '입력된 포장 합계 ${_number(estimate.knownLitres)} L',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: estimate.ratio.clamp(0.0, 1.0),
                          minHeight: 10,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '산술 비율 ${(estimate.ratio * 100).toStringAsFixed(1)}% · 실제 점유율 아님',
                        ),
                        Text(
                          '치수 확인 ${estimate.measuredCount}/${estimate.totalCount}묶음 (${(estimate.coverage * 100).round()}%)',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text('미상·재확인 ${estimate.unknownCount}묶음은 계산에서 제외했어요.'),
                        if (estimate.staleCount > 0)
                          Text(
                            '수량·단위가 바뀐 ${estimate.staleCount}묶음의 포장을 다시 확인해주세요.',
                            style: const TextStyle(
                              color: FridgeTheme.terracotta,
                            ),
                          ),
                        const SizedBox(height: 10),
                        Text(
                          estimate.arithmeticRemaining < 0
                              ? '입력한 포장 합계가 공간 부피보다 큽니다.'
                              : '산술 차이 ${_number(estimate.arithmeticRemaining)} L',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '모양·배치·선반·통풍 여유는 계산하지 않습니다. 남은 차이가 있어도 실제로 들어간다고 보장하지 않아요.',
                          style: TextStyle(
                            fontSize: 12,
                            color: FridgeTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: FridgeTheme.terracotta),
                  ),
                ),
              const SizedBox(height: 20),
              Text('재료별 포장 치수', style: Theme.of(context).textTheme.titleLarge),
              const Text(
                'g·kg·ml·L의 재고 수량을 포장 부피로 자동 환산하지 않습니다. 묶음 전체를 담는 현재 포장 기준으로 입력하세요.',
                style: TextStyle(fontSize: 12, color: FridgeTheme.muted),
              ),
              const SizedBox(height: 12),
              if (batches.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('이 보관함에 재료가 없어요.', textAlign: TextAlign.center),
                ),
              ...batches.map((b) {
                final m = _data!.measurements[b.id];
                final valid = m != null && m.valid && m.matches(b);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            FoodIllustration(
                              name: b.name,
                              category: b.category,
                              artKey: b.artKey,
                              photoFile: b.photoFile,
                              size: 45,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    b.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(b.quantityLabel),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Text(
                          valid
                              ? '포장 ${m.packages}개 · ${_number(m.litres)} L${m.source == 'preparedDemo' ? ' · 준비 사례' : ''}'
                              : m == null
                              ? '포장 치수 미상 · 계산 제외'
                              : '재고 변경 후 재확인 필요 · 계산 제외',
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _editDimensions(batch: b),
                              child: Text(m == null ? '치수 입력' : '치수 다시 확인'),
                            ),
                            if (m != null)
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () {
                                        final next = _copy();
                                        next.measurements.remove(b.id);
                                        _save(next);
                                      },
                                child: const Text('미상으로 변경'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    ),
  );

  Future<void> _prepareDemo() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('준비한 치수 예시를 넣을까요?'),
        content: const Text(
          '냉장 공간 40×35×30cm와 샘플 두부·우유의 예시 포장 크기를 사용합니다. 실제 상품을 측정한 값이 아니며 재고 수량은 바꾸지 않습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('예시 적용'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final next = _copy();
    next.spaces[StorageType.fridge] = const BoxDimensions(
      widthCm: 40,
      heightCm: 35,
      depthCm: 30,
    );
    next.spaceSources[StorageType.fridge] = 'preparedDemo';
    for (final b in widget.store.activeBatches.where(
      (b) => b.id == 'tofu' || b.id == 'milk',
    )) {
      next.measurements[b.id] = PackageMeasurement(
        batchId: b.id,
        box: b.id == 'tofu'
            ? const BoxDimensions(widthCm: 12, heightCm: 4, depthCm: 8)
            : const BoxDimensions(widthCm: 7, heightCm: 20, depthCm: 7),
        packages: 1,
        quantityAtMeasurement: b.quantity,
        unitAtMeasurement: b.unit,
        source: 'preparedDemo',
      );
    }
    setState(() => _storage = StorageType.fridge);
    await _save(next);
  }

  Future<void> _editDimensions({InventoryBatch? batch}) async {
    final current = batch == null
        ? _data!.spaces[_storage]
        : _data!.measurements[batch.id]?.box;
    final controllers = [
      TextEditingController(text: current?.widthCm.toString() ?? ''),
      TextEditingController(text: current?.heightCm.toString() ?? ''),
      TextEditingController(text: current?.depthCm.toString() ?? ''),
      TextEditingController(
        text: batch == null
            ? '1'
            : (_data!.measurements[batch.id]?.packages ?? 1).toString(),
      ),
    ];
    final form = GlobalKey<FormState>();
    final route = DialogRoute<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(batch == null ? '수납 공간 안쪽 치수' : '${batch.name} 포장 치수'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  batch == null
                      ? '선반 등으로 나뉜 공간이라면 한 구역의 치수를 입력하세요.'
                      : '같은 크기의 포장 한 개의 바깥 치수와 포장 개수를 입력하세요. 재고 ${batch.quantityLabel}에서 자동 계산하지 않습니다.',
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < (batch == null ? 3 : 4); i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      controller: controllers[i],
                      keyboardType: TextInputType.numberWithOptions(
                        decimal: i < 3,
                      ),
                      decoration: InputDecoration(
                        labelText: i < 3
                            ? '${['가로', '높이', '깊이'][i]} (cm)'
                            : '이 묶음의 포장 개수',
                      ),
                      validator: (v) {
                        final n = double.tryParse(v ?? '');
                        if (n == null || !n.isFinite || n <= 0) {
                          return '0보다 큰 숫자를 입력해주세요.';
                        }
                        if (i == 3 && n != n.roundToDouble()) {
                          return '포장 개수는 정수로 입력해주세요.';
                        }
                        return null;
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, true);
            },
            child: const Text('확인하고 저장'),
          ),
        ],
      ),
    );
    final result = await Navigator.of(context).push(route);
    if (result == true && mounted) {
      final box = BoxDimensions(
        widthCm: double.parse(controllers[0].text),
        heightCm: double.parse(controllers[1].text),
        depthCm: double.parse(controllers[2].text),
      );
      final next = _copy();
      if (batch == null) {
        next.spaces[_storage] = box;
        next.spaceSources[_storage] = 'manual';
      } else {
        next.measurements[batch.id] = PackageMeasurement(
          batchId: batch.id,
          box: box,
          packages: double.parse(controllers[3].text).toInt(),
          quantityAtMeasurement: batch.quantity,
          unitAtMeasurement: batch.unit,
          source: 'manual',
        );
      }
      await _save(next);
    }
    await route.completed;
    for (final c in controllers) {
      c.dispose();
    }
  }
}
