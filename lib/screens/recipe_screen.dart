import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/inventory.dart';
import '../design/recipe_ingredient_banner.dart';
import '../design/food_illustration.dart';
import '../models/recipe.dart';
import '../services/inventory_store.dart';
import '../services/shopping_store.dart';
import 'assistant_screen.dart';

class RecipeScreen extends StatefulWidget {
  const RecipeScreen({
    super.key,
    required this.recipe,
    required this.store,
    this.autoResume = false,
  });
  final Recipe recipe;
  final InventoryStore store;
  final bool autoResume;
  @override
  State<RecipeScreen> createState() => _RecipeScreenState();
}

class _RecipeScreenState extends State<RecipeScreen> {
  String _mode = 'detail';
  String? _sessionId;
  int _step = 0;
  bool _busy = false;
  bool _paused = false;
  String? _error;
  final Map<String, TextEditingController> _amounts = {};
  final Map<String, int> _usageRevisions = {};
  final FlutterTts _tts = FlutterTts();
  bool _speaking = false;
  Recipe? _sessionRecipe;
  Recipe get recipe => _sessionRecipe ?? widget.recipe;

  @override
  void initState() {
    super.initState();
    if (widget.autoResume) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || !_canResume) return;
        await _start(resume: true);
      });
    }
  }

  Future<void> _assistant([String? question]) async {
    await _stopReading();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => AssistantScreen(
          store: widget.store,
          recipe: recipe,
          recipeStep: _step,
          initialText: question,
        ),
      ),
    );
    if (!mounted) return;
    final session = widget.store.cookingSession;
    if (session == null || session['status'] == 'ended') {
      if (_sessionId != null) _returnToDetail();
      return;
    }
    if (session['status'] == 'completed') {
      if (session['id'] == _sessionId) {
        setState(() => _mode = 'done');
      } else if (_sessionId != null) {
        _returnToDetail();
      }
      return;
    }
    if (_sessionId == null && session['recipeId'] != recipe.id) return;
    final savedRecipe = Recipe.fromJson(
      Map<String, dynamic>.from(session['recipe'] as Map),
    );
    final sameUsage = session['id'] == _sessionId && _mode == 'usage';
    setState(() {
      _sessionId = session['id'] as String;
      _sessionRecipe = savedRecipe;
      _step = ((session['step'] as num?)?.toInt() ?? 0).clamp(
        0,
        savedRecipe.steps.length - 1,
      );
      _paused = session['status'] == 'paused';
      _mode = sameUsage && session['status'] == 'awaitingUsage'
          ? 'usage'
          : 'cooking';
    });
    if (!sameUsage && session['status'] == 'awaitingUsage') {
      await _prepareUsage();
    }
  }

  void _returnToDetail() {
    setState(() {
      _sessionId = null;
      _mode = 'detail';
      _paused = false;
      _step = 0;
    });
  }

  @override
  void dispose() {
    _tts.stop().catchError((_) => null);
    for (final c in _amounts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      final current = widget.store.cookingSession;
      if (_sessionId != null &&
          (current?['id'] != _sessionId ||
              ['ended', 'completed'].contains(current?['status']))) {
        _returnToDetail();
        setState(() => _error = '다른 화면에서 조리 상태가 바뀌었어요. 현재 조리를 확인해주세요.');
      } else {
        setState(() => _error = '저장하지 못했어요. 입력은 유지됩니다. 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _session(String status) => {
    'id': _sessionId,
    'recipeId': recipe.id,
    'recipe': recipe.toJson(),
    'step': _step,
    'status': status,
    'usageApplied': false,
  };
  Future<void> _save(String status) => widget.store.saveCookingSessionIfCurrent(
    _session(status),
    expectedSessionId: _sessionId,
  );

  bool get _canResume {
    final s = widget.store.cookingSession;
    return s != null &&
        s['recipeId'] == recipe.id &&
        s['status'] != 'completed' &&
        s['status'] != 'ended';
  }

  Future<void> _start({bool resume = false}) async {
    final active = widget.store.cookingSession;
    final expectedId = active?['id'] as String?;
    if (resume && !_canResume) return;
    final awaitingUsage = resume && active?['status'] == 'awaitingUsage';
    if (!resume &&
        active != null &&
        active['status'] != 'completed' &&
        active['status'] != 'ended') {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('진행 중인 요리를 종료할까요?'),
          content: const Text('기존 조리를 종료하고 새 요리를 시작합니다. 종료만으로 재고가 차감되지는 않습니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('종료하고 시작'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    await _run(() async {
      _sessionRecipe = resume
          ? Recipe.fromJson(Map<String, dynamic>.from(active!['recipe'] as Map))
          : recipe;
      _sessionId = resume
          ? active!['id'] as String
          : 'cook-${DateTime.now().microsecondsSinceEpoch}';
      _step = resume
          ? ((active!['step'] as num?)?.toInt() ?? 0).clamp(
              0,
              recipe.steps.length - 1,
            )
          : 0;
      if (!awaitingUsage) {
        await widget.store.saveCookingSessionIfCurrent(
          _session('cooking'),
          expectedSessionId: expectedId,
        );
      }
      if (mounted) {
        setState(() {
          _mode = 'cooking';
          _paused = false;
        });
      }
    });
    if (mounted && _error == null && awaitingUsage && _mode == 'cooking') {
      await _prepareUsage();
    }
  }

  Future<void> _move(int step) => _run(() async {
    await _stopReading();
    final previous = _step;
    _step = step;
    try {
      await _save('cooking');
    } catch (_) {
      _step = previous;
      rethrow;
    }
    if (mounted) setState(() {});
  });

  double? _convert(double value, String from, String to) {
    try {
      return convertQuantity(value, from, to);
    } on ArgumentError {
      return null;
    }
  }

  bool _matches(InventoryBatch batch, RecipeIngredient ingredient) {
    final name = batch.name.trim();
    if (name == ingredient.name.trim()) return true;
    return ingredientKey(name) == ingredientKey(ingredient.name) &&
        !recipe.ingredients.any((other) => other.name.trim() == name);
  }

  List<InventoryBatch> _batches(RecipeIngredient ingredient) {
    final list = widget.store.batches
        .where(
          (b) =>
              _matches(b, ingredient) &&
              b.quantityMode == QuantityMode.measured &&
              b.quantity > 0,
        )
        .toList();
    list.sort((a, b) {
      if (a.isAvailableForUse != b.isAvailableForUse) {
        return a.isAvailableForUse ? -1 : 1;
      }
      final selectedA = recipe.preferredBatchIds.contains(a.id);
      final selectedB = recipe.preferredBatchIds.contains(b.id);
      if (selectedA != selectedB) return selectedA ? -1 : 1;
      return compareBatchExpiry(a, b);
    });
    return list;
  }

  String _availability(RecipeIngredient i) {
    if (i.optional) return '차감 선택';
    if (i.quantity == null) return '필요량 미상 · 직접 확인';
    final batches = _batches(i).where((b) => b.isAvailableForUse);
    if (batches.isEmpty) {
      final status = widget.store.activeBatches.where(
        (b) =>
            _matches(b, i) &&
            b.isAvailableForUse &&
            b.quantityMode == QuantityMode.status,
      );
      if (status.isNotEmpty) return '보유 중 · 잔량 확인 필요';
      final elapsed = widget.store.activeBatches.any(
        (b) => _matches(b, i) && !b.isAvailableForUse,
      );
      return elapsed ? '표시 기한이 지난 재고만 있음 · 기본 사용량 0' : '보유 재료 없음';
    }
    double amount = 0;
    bool comparable = false;
    for (final b in batches) {
      final v = _convert(b.quantity, b.unit, i.unit);
      if (v != null) {
        amount += v;
        comparable = true;
      }
    }
    if (!comparable) return '단위 확인 필요';
    return amount >= i.quantity!
        ? '보유량 충족'
        : '${formatQuantity(i.quantity! - amount)}${i.unit} 부족';
  }

  Future<void> _readStep() async {
    try {
      await _tts.stop();
      final available = await _tts.isLanguageAvailable('ko-KR');
      if (available != true && available != 1) {
        if (mounted) {
          setState(
            () => _error = '한국어 음성 엔진을 사용할 수 없어요. 화면의 단계 안내로 계속 진행할 수 있습니다.',
          );
        }
        return;
      }
      await _tts.setLanguage('ko-KR');
      await _tts.setSpeechRate(0.45);
      _tts.setCompletionHandler(() {
        if (mounted) setState(() => _speaking = false);
      });
      _tts.setErrorHandler((_) {
        if (mounted) {
          setState(() {
            _speaking = false;
            _error = '음성 안내를 재생하지 못했어요. 화면 안내를 확인해주세요.';
          });
        }
      });
      if (mounted) setState(() => _speaking = true);
      await _tts.speak('${_step + 1}단계. ${recipe.steps[_step]}');
    } catch (_) {
      if (mounted) {
        setState(() {
          _speaking = false;
          _error = '음성 안내를 사용할 수 없어요. 화면 안내로 계속 진행해주세요.';
        });
      }
    }
  }

  Future<void> _stopReading() async {
    try {
      await _tts.stop();
    } catch (_) {
      /* Touch navigation stays available. */
    }
    if (mounted) setState(() => _speaking = false);
  }

  Future<void> _sendMissing() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('장보기 계획에 추가할까요?'),
        content: Text(
          '${recipe.title}를 다음 식사 계획에 추가합니다. 여러 메뉴의 필요량을 합친 뒤 현재 재고를 한 번만 배정해 부족한 양을 계산합니다. 같은 메뉴를 다시 보내면 중복 추가하지 않습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('확인하고 반영'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      final shopping = ShoppingStore(inventory: widget.store);
      try {
        await shopping.initialize();
        await shopping.addRecipeToPlan(recipe);
      } finally {
        shopping.dispose();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('장보기 계획에 반영했어요. 부족한 재료를 목록에서 확인하세요.')),
        );
      }
    });
  }

  Future<void> _prepareUsage() => _run(() async {
    await _stopReading();
    await _save('awaitingUsage');
    if (!mounted) return;
    final previousControllers = _amounts.values.toList();
    _amounts.clear();
    _usageRevisions.clear();
    for (final i in recipe.ingredients) {
      double remaining = i.optional ? 0 : i.quantity ?? 0;
      for (final b in _batches(i)) {
        final need = _convert(remaining, i.unit, b.unit);
        final allocated = need == null || !b.isAvailableForUse
            ? 0.0
            : need.clamp(0, b.quantity).toDouble();
        _amounts[b.id] = TextEditingController(text: formatQuantity(allocated));
        _usageRevisions[b.id] = b.revision;
        if (need != null) remaining -= _convert(allocated, b.unit, i.unit)!;
      }
    }
    setState(() => _mode = 'usage');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in previousControllers) {
        controller.dispose();
      }
    });
  });
  Future<void> _apply() async {
    final usage = <String, double>{};
    for (final entry in _amounts.entries) {
      final q = double.tryParse(entry.value.text);
      final batches = widget.store.batches.where((b) => b.id == entry.key);
      if (batches.isNotEmpty &&
          batches.first.revision != _usageRevisions[entry.key]) {
        setState(() => _error = '확인 중 재고가 바뀌었어요. 현재 재고로 사용량을 다시 확인해주세요.');
        return;
      }
      if (q == null ||
          !q.isFinite ||
          q < 0 ||
          batches.isEmpty ||
          q > batches.first.quantity) {
        setState(() => _error = '사용량을 현재 재고 이내의 수량으로 입력해주세요.');
        return;
      }
      if (q > 0) usage[entry.key] = q;
    }
    if (usage.isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('재고 차감 없이 조리를 완료할까요?'),
          content: const Text(
            '이번 요리는 완료로 기록하고 재료 수량은 그대로 유지해요. 상태형 재료의 충분·부족·없음은 재료 상세에서 따로 확인해주세요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('사용량 다시 확인'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('차감 없이 완료'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    await _run(() async {
      await widget.store.applyCookingUsage(
        _sessionId!,
        usage,
        expectedRevisions: _usageRevisions,
      );
      if (mounted) {
        setState(() => _mode = 'done');
      }
    });
  }

  Future<void> _end() async {
    await _stopReading();
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('재고 차감 없이 종료할까요?'),
        content: const Text('이번 요리의 진행을 종료합니다. 재료 수량은 그대로 유지됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('계속 요리'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('종료'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _run(() async {
        await _save('ended');
        if (mounted) _returnToDetail();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_mode == 'usage' ? '사용량 확인' : recipe.title),
        actions: [
          IconButton(
            tooltip: '음성 명령 · 요리 코치',
            onPressed: _busy ? null : _assistant,
            icon: const Icon(Icons.chat_bubble_outline),
          ),
        ],
      ),
      bottomNavigationBar: _mode == 'detail'
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _start(resume: _canResume),
                  icon: const Icon(Icons.restaurant_rounded),
                  label: Text(_canResume ? '저장된 조리 이어하기' : '요리 시작하기'),
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(_error!),
                ),
              ),
            if (_busy) const LinearProgressIndicator(),
            if (_mode == 'detail') ..._details(),
            if (_mode == 'cooking') ..._cooking(),
            if (_mode == 'usage') ..._usage(),
            if (_mode == 'done') ...[
              const SizedBox(height: 45),
              const Icon(Icons.check_circle_outline, size: 80),
              const SizedBox(height: 24),
              Text(
                '한 끼를 기록했어요',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                '확인한 사용량만 재고에 반영했습니다. 변경 이력에서 확인할 수 있어요.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('냉장고로 돌아가기'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _details() => [
    RecipeIngredientBanner(
      names: recipe.ingredients.map((i) => i.name).toList(),
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      children: [
        Chip(label: Text(recipe.isDemo ? '샘플 레시피' : 'AI 생성 레시피')),
        Chip(label: Text('${recipe.minutes}분 · ${recipe.servings}인분')),
      ],
    ),
    Text(recipe.reason, style: Theme.of(context).textTheme.bodyLarge),
    const SizedBox(height: 16),
    if (!recipe.allergensKnown)
      const Text(
        '알레르기가 있다면 제품별 원재료를 확인해주세요. 레시피만으로 안전을 보장할 수 없어요.',
        style: TextStyle(fontSize: 12, height: 1.5, color: Color(0xFFAA482A)),
      ),
    const SizedBox(height: 24),
    Text('필요한 재료', style: Theme.of(context).textTheme.titleLarge),
    ...recipe.ingredients.map(
      (i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FoodIllustration(name: i.name, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i.name, style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    i.quantity == null
                        ? '수량 미상'
                        : '${formatQuantity(i.quantity!)} ${i.unit}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _availability(i),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 16),
    OutlinedButton.icon(
      onPressed: _busy ? null : _sendMissing,
      icon: const Icon(Icons.shopping_basket_outlined),
      label: const Text('부족한 재료 장보기에 보내기'),
    ),
    const Text('AI 레시피와 영상은 서로 다른 참고 정보입니다. 제품 표시와 보관 상태를 직접 확인하세요.'),
    TextButton.icon(
      onPressed: () async {
        try {
          if (!await launchUrl(
                recipe.youtubeSearch,
                mode: LaunchMode.externalApplication,
              ) &&
              mounted) {
            setState(() => _error = '영상 검색을 열지 못했어요.');
          }
        } catch (_) {
          if (mounted) setState(() => _error = '영상 검색을 열지 못했어요.');
        }
      },
      icon: const Icon(Icons.open_in_new),
      label: const Text('유튜브 참고 영상 검색'),
    ),
    const SizedBox(height: 20),
  ];
  List<Widget> _cooking() => [
    Text(
      '${recipe.servings}인분 · ${recipe.minutes}분',
      style: Theme.of(context).textTheme.bodyLarge,
    ),
    const SizedBox(height: 16),
    LinearProgressIndicator(value: (_step + 1) / recipe.steps.length),
    const SizedBox(height: 16),
    Text(
      'STEP ${_step + 1} / ${recipe.steps.length}',
      style: Theme.of(context).textTheme.labelLarge,
    ),
    const SizedBox(height: 12),
    Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        border: Border.all(color: const Color(0xFFD5DFDC)),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        recipe.steps[_step],
        style: Theme.of(context).textTheme.titleLarge?.copyWith(height: 1.6),
      ),
    ),
    const SizedBox(height: 20),
    OutlinedButton.icon(
      onPressed: _busy
          ? null
          : () => _assistant('현재 ${_step + 1}단계를 더 자세히 설명해줘'),
      icon: const Icon(Icons.chat_bubble_outline),
      label: const Text('이 단계 질문하기'),
    ),
    OutlinedButton.icon(
      onPressed: _busy
          ? null
          : _speaking
          ? _stopReading
          : _readStep,
      icon: Icon(
        _speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
      ),
      label: Text(_speaking ? '읽기 중지' : '현재 단계 읽어주기'),
    ),
    if (_paused) const Text('일시정지 중입니다. 계속하기를 누르면 단계를 진행할 수 있어요.'),
    Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _busy || _paused || _step == 0
                ? null
                : () => _move(_step - 1),
            child: const Text('이전'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: _busy || _paused
                ? null
                : _step < recipe.steps.length - 1
                ? () => _move(_step + 1)
                : _prepareUsage,
            child: Text(_step < recipe.steps.length - 1 ? '다음 단계' : '사용량 확인'),
          ),
        ),
      ],
    ),
    TextButton(
      onPressed: _busy
          ? null
          : () => _run(() async {
              await _save(_paused ? 'cooking' : 'paused');
              if (mounted) setState(() => _paused = !_paused);
            }),
      child: Text(_paused ? '계속하기' : '일시정지'),
    ),
    TextButton(onPressed: _busy ? null : _end, child: const Text('차감 없이 종료')),
    const SizedBox(height: 24),
    const Text('조리 진행은 기기에 저장합니다. 완료 후 실제 사용량을 확인하기 전에는 재고를 바꾸지 않습니다.'),
  ];
  List<Widget> _usage() => [
    Text(recipe.title, style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 10),
    const Text(
      '실제로 사용한 양을 확인해주세요. 각 구매 묶음의 단위로 표시하며, 호환되지 않는 단위는 자동 환산하지 않습니다.',
    ),
    TextButton.icon(
      onPressed: _busy ? null : _prepareUsage,
      icon: const Icon(Icons.refresh),
      label: const Text('현재 재고로 사용량 다시 확인'),
    ),
    const SizedBox(height: 20),
    ...recipe.ingredients.expand((i) {
      final batches = _batches(i);
      if (batches.isEmpty) {
        final statusBatches = widget.store.activeBatches
            .where(
              (b) => _matches(b, i) && b.quantityMode == QuantityMode.status,
            )
            .toList();
        return [
          ListTile(
            title: Text(i.name),
            subtitle: Text(
              statusBatches.isEmpty
                  ? '일치하는 보유 재고가 없어 차감하지 않습니다.'
                  : '상태로 관리 중 · ${statusBatches.map((b) => b.stockLevel.label).join(', ')}\n수량은 차감하지 않아요. 조리 후 재료 상세에서 남은 상태를 확인해주세요.',
            ),
          ),
        ];
      }
      return batches.map(
        (b) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.name, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  '${recipe.preferredBatchIds.contains(b.id) ? '선택한 묶음 · ' : ''}${b.storageType.label} · 등록 ${b.createdAt.toIso8601String().substring(0, 10)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '보유 ${formatQuantity(b.quantity)}${b.unit} · ${b.expiryLabel()}',
                ),
                if ((b.daysRemaining() ?? 0) < 0)
                  const Text(
                    '표시 기한이 지나 기본 사용량은 0이에요. 제품 표시와 보관 상태를 확인하고 실제 사용한 경우에만 입력해주세요.',
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amounts[b.id],
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '실제 사용량 (${b.unit})',
                    helperText: _convert(1, i.unit, b.unit) == null
                        ? '자동 환산 불가 · 직접 입력해주세요'
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Text(
                  '반영 후 ${formatQuantity(b.quantity - (double.tryParse(_amounts[b.id]?.text ?? '') ?? 0))}${b.unit}',
                ),
              ],
            ),
          ),
        ),
      );
    }),
    const SizedBox(height: 24),
    FilledButton(
      onPressed: _busy ? null : _apply,
      child: Text(
        _amounts.values.every((c) => double.tryParse(c.text) == 0)
            ? '재고 차감 없이 조리 완료'
            : '확인하고 재고에 반영',
      ),
    ),
    TextButton(
      onPressed: _busy
          ? null
          : () => _run(() async {
              await _save('cooking');
              if (mounted) setState(() => _mode = 'cooking');
            }),
      child: const Text('취소하고 조리로 돌아가기'),
    ),
  ];
}
