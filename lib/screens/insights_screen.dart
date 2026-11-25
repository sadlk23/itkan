import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';
import '../models/recipe.dart';
import '../services/ai_service.dart';
import '../services/cooking_preferences.dart';
import '../services/insight_ai_service.dart';
import '../services/inventory_store.dart';
import '../widgets/common.dart';
import 'recipe_screen.dart';

class ConsumptionTotal {
  ConsumptionTotal(this.name, this.unit);
  final String name, unit;
  double consumed = 0, wasted = 0;
  int wasteEvents = 0;
}

List<ConsumptionTotal> calculateConsumption(
  List<InventoryChange> history, {
  DateTime? now,
  int days = 30,
}) {
  final cutoff = (now ?? DateTime.now()).subtract(Duration(days: days));
  final groups = <String, ConsumptionTotal>{};
  for (final change in history) {
    if (change.undone ||
        change.createdAt.isBefore(cutoff) ||
        !['consume', 'discard', 'cooking'].contains(change.action)) {
      continue;
    }
    final eventGroups = <String>{};
    for (final before in change.before) {
      if (before.quantityMode != QuantityMode.measured) continue;
      final after = change.after.where((b) => b.id == before.id).firstOrNull;
      if (after == null || after.unit != before.unit) continue;
      var amount = before.quantity - after.quantity;
      if (amount <= 0) continue;
      var unit = before.unit;
      if (unit == 'kg') {
        amount *= 1000;
        unit = 'g';
      }
      if (unit == 'L') {
        amount *= 1000;
        unit = 'ml';
      }
      final key = '${before.name}|$unit';
      final total = groups.putIfAbsent(
        key,
        () => ConsumptionTotal(before.name, unit),
      );
      if (change.action == 'discard') {
        total.wasted += amount;
        eventGroups.add(key);
      } else {
        total.consumed += amount;
      }
    }
    for (final key in eventGroups) {
      groups[key]!.wasteEvents++;
    }
  }
  return groups.values.toList()
    ..sort((a, b) => b.wasteEvents.compareTo(a.wasteEvents));
}

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key, required this.store, this.aiService});
  final InventoryStore store;
  final AiService? aiService;
  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  late final AiService _ai;
  bool _aiBusy = false;
  int _requestEpoch = 0;
  String? _aiError;
  InsightAdvice? _advice;
  List<Map<String, Object>> _adviceFacts = [];
  List<Recipe> _recipes = [];
  bool showSuggestions = true, dailyAllowed = true;
  String frequency = '매번 열 때';
  String get todayKey {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  @override
  void initState() {
    super.initState();
    _ai = widget.aiService ?? AiService();
    widget.store.addListener(_invalidateAi);
    load();
  }

  void _invalidateAi() {
    _requestEpoch++;
    if (!mounted) return;
    setState(() {
      _aiBusy = false;
      _advice = null;
      _adviceFacts = [];
      _recipes = [];
      _aiError = null;
    });
  }

  @override
  void dispose() {
    _requestEpoch++;
    widget.store.removeListener(_invalidateAi);
    _ai.dispose();
    super.dispose();
  }

  List<Map<String, Object>> _facts() {
    final totals = calculateConsumption(widget.store.history);
    return [
      for (var i = 0; i < totals.length; i++)
        {
          'id': 'record_$i',
          'name': totals[i].name,
          'unit': totals[i].unit,
          'consumed': totals[i].consumed,
          'wasted': totals[i].wasted,
          'wasteEvents': totals[i].wasteEvents,
        },
    ];
  }

  Future<void> _explain() async {
    final epoch = ++_requestEpoch;
    final facts = _facts();
    setState(() {
      _aiBusy = true;
      _aiError = null;
      _advice = null;
    });
    try {
      final answer = await InsightAiService(_ai).explain(facts);
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _advice = answer;
        _adviceFacts = facts;
      });
    } catch (error) {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _aiError = '$error');
      }
    } finally {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _aiBusy = false);
      }
    }
  }

  Future<void> _recommend(InventoryBatch batch) async {
    final epoch = ++_requestEpoch;
    final demo = widget.store.isDemo;
    final batches = widget.store.activeBatches.toList();
    setState(() {
      _aiBusy = true;
      _aiError = null;
      _recipes = [];
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await CookingPreferences.load(isDemo: demo);
      if (!mounted || epoch != _requestEpoch) return;
      final recipes = await _ai.recommend(
        batches,
        selectedBatchIds: {batch.id},
        allergies: prefs.getStringList('allergies') ?? [],
        preferences: saved.preferences,
        equipment: saved.equipment,
      );
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _recipes = recipes;
        if (recipes.isEmpty) _aiError = '조건에 맞는 요리를 찾지 못했어요. 재료나 조건을 바꿔주세요.';
      });
    } catch (error) {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _aiError = '$error');
      }
    } finally {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _aiBusy = false);
      }
    }
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        showSuggestions = p.getBool('insight_suggestions') ?? true;
        frequency = p.getString('insight_frequency') ?? '매번 열 때';
        dailyAllowed = p.getString('insight_last_shown') != todayKey;
      });
    }
    if (showSuggestions && frequency == '하루 한 번 확인' && dailyAllowed) {
      await p.setString('insight_last_shown', todayKey);
    }
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('insight_suggestions', showSuggestions);
    await p.setString('insight_frequency', frequency);
    if (showSuggestions && frequency == '하루 한 번 확인' && dailyAllowed) {
      await p.setString('insight_last_shown', todayKey);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final totals = calculateConsumption(widget.store.history);
      final imminent = widget.store.activeBatches.where((b) {
        final d = b.daysRemaining();
        return d != null && d >= 0 && d <= 3;
      }).toList();
      final low = widget.store.batches
          .where(
            (b) =>
                b.quantityMode == QuantityMode.status &&
                (b.stockLevel == StockLevel.low ||
                    b.stockLevel == StockLevel.none),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(title: const Text('소비 기록과 제안')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const InfoBox(
              '최근 30일의 실제 사용·폐기 이력을 단위별로 집계합니다. 아래 제안은 날짜와 반복 폐기 규칙에 근거하며, AI 모델의 예측 결과가 아닙니다.',
            ),
            Text(
              widget.store.isDemo ? '샘플 모드의 기록' : '내 재고의 기록',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (totals.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('아직 사용·폐기 기록이 없어요. 기록이 쌓이면 근거와 함께 보여드립니다.'),
              ),
            ...totals.map(
              (t) => Card(
                child: ListTile(
                  title: Text('${t.name} · ${t.unit}'),
                  subtitle: Text(
                    '사용 ${formatQuantity(t.consumed)}${t.unit} / 폐기 ${formatQuantity(t.wasted)}${t.unit}\n폐기 기록 ${t.wasteEvents}회',
                  ),
                ),
              ),
            ),
            if (totals.isNotEmpty) ...[
              const InfoBox(
                '원하면 위 집계를 온라인 AI에 보내 짧은 조언을 받을 수 있어요. 예측이나 자동 구매는 하지 않습니다.',
              ),
              OutlinedButton.icon(
                onPressed: _aiBusy || !_ai.isConfigured ? null : _explain,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('이 기록으로 AI 조언 받기'),
              ),
            ],
            if (!_ai.isConfigured)
              const InfoBox('AI 연결 설정 후 기록 조언과 재료별 요리 추천을 사용할 수 있어요.'),
            if (_aiBusy) ...[
              Semantics(
                liveRegion: true,
                child: const Text('기록과 재료에 맞는 제안을 찾고 있어요.'),
              ),
              const LinearProgressIndicator(),
              TextButton(onPressed: _invalidateAi, child: const Text('요청 취소')),
            ],
            if (_aiError != null)
              Semantics(
                liveRegion: true,
                child: InfoBox('$_aiError\n위 버튼으로 다시 요청할 수 있어요. 기록은 그대로입니다.'),
              ),
            if (_advice != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI 조언 · 최근 30일 기록 기반',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(_advice!.text),
                      const SizedBox(height: 8),
                      const Text('사용된 집계 근거'),
                      ..._adviceFacts
                          .where((f) => _advice!.evidenceIds.contains(f['id']))
                          .map(
                            (f) => Text(
                              '${f['name']}: 사용 ${f['consumed']}${f['unit']}, 폐기 ${f['wasted']}${f['unit']} · ${f['wasteEvents']}회',
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ..._recipes.map(
              (recipe) => Card(
                child: ListTile(
                  title: Text(recipe.title),
                  subtitle: Text(
                    'AI 추천 · ${recipe.servings}인분 · ${recipe.minutes}분\n${recipe.reason}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          RecipeScreen(recipe: recipe, store: widget.store),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('제안 표시 설정', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: showSuggestions,
              onChanged: (v) {
                setState(() => showSuggestions = v);
                save();
              },
              title: const Text('앱 안에서 제안 받기'),
              subtitle: const Text('이 화면의 제안 카드 · 시스템 알림과 별도'),
            ),
            DropdownButtonFormField<String>(
              initialValue: frequency,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '확인 주기'),
              items: [
                '매번 열 때',
                '하루 한 번 확인',
              ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) {
                setState(() => frequency = v!);
                save();
              },
            ),
            if (showSuggestions &&
                frequency == '하루 한 번 확인' &&
                !dailyAllowed) ...[
              const InfoBox('오늘의 제안을 이미 확인했어요. 자동 표시는 하루 한 번으로 설정되어 있습니다.'),
              TextButton(
                onPressed: () => setState(() => dailyAllowed = true),
                child: const Text('오늘 제안 다시 보기'),
              ),
            ],
            if (showSuggestions &&
                (frequency != '하루 한 번 확인' || dailyAllowed)) ...[
              const SizedBox(height: 20),
              Text('지금 살펴볼 것', style: Theme.of(context).textTheme.titleMedium),
              ...imminent.map(
                (b) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text('${b.name} · ${b.expiryLabel()}'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('제품 표시와 보관 상태를 확인하고 사용할 메뉴를 살펴보세요.'),
                        TextButton.icon(
                          onPressed: _aiBusy || !_ai.isConfigured
                              ? null
                              : () => _recommend(b),
                          icon: const Icon(Icons.restaurant_outlined),
                          label: const Text('이 재료로 한 끼 추천'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ...low.map(
                (b) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.shopping_basket_outlined),
                    title: Text('${b.name} · ${b.stockLevel.label}'),
                    subtitle: const Text('다음 장보기 전에 남은 상태를 확인해보세요.'),
                  ),
                ),
              ),
              ...totals
                  .where((t) => t.wasteEvents >= 2)
                  .map(
                    (t) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.eco_outlined),
                        title: Text('${t.name}, 조금씩 사보는 건 어떨까요?'),
                        subtitle: Text(
                          '근거: 최근 30일 ${t.wasteEvents}회, ${formatQuantity(t.wasted)}${t.unit} 폐기. 실제 필요량을 확인한 뒤 구매하세요.',
                        ),
                      ),
                    ),
                  ),
              if (imminent.isEmpty &&
                  low.isEmpty &&
                  totals.every((t) => t.wasteEvents < 2))
                const InfoBox(
                  '지금 조건에 맞는 제안이 없어요. 근거가 부족하면 구매량을 임의로 추천하지 않습니다.',
                ),
            ],
            const InfoBox(
              '이 화면은 앱을 열 때 최신 기록을 계산합니다. 백그라운드 분석이나 자동 구매를 실행하지 않습니다.',
            ),
          ],
        ),
      );
    },
  );
}
