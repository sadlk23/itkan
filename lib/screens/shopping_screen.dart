import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/inventory.dart';
import '../design/app_theme.dart';
import '../models/shopping.dart';
import '../services/inventory_store.dart';
import '../services/shopping_store.dart';
import '../widgets/common.dart';
import '../widgets/coupang_search_options.dart';

enum _ShoppingMall {
  coupang('쿠팡'),
  naver('네이버쇼핑'),
  kurly('컬리');

  const _ShoppingMall(this.label);
  final String label;

  Uri search(String ingredient) => switch (this) {
    coupang => Uri.https('www.coupang.com', '/np/search', {'q': ingredient}),
    naver => Uri.https('search.shopping.naver.com', '/ns/search', {
      'query': ingredient,
    }),
    kurly => Uri.https('www.kurly.com', '/search', {'sword': ingredient}),
  };

  Uri get cart => switch (this) {
    coupang => Uri.https('cart.coupang.com', '/cartView.pang'),
    naver => Uri.https('shopping.naver.com', '/cart'),
    kurly => Uri.https('www.kurly.com', '/cart'),
  };
}

class ShoppingScreen extends StatefulWidget {
  const ShoppingScreen({
    super.key,
    required this.store,
    required this.onIntake,
    this.onPurchasedIntake,
    this.openShoppingUrl,
  });
  final InventoryStore store;
  final VoidCallback onIntake;
  final Future<String?> Function(List<ShoppingItem>)? onPurchasedIntake;
  final Future<bool> Function(Uri)? openShoppingUrl;
  @override
  State<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends State<ShoppingScreen> {
  late final shopping = ShoppingStore(inventory: widget.store);
  bool busy = true, loading = true;
  String? error;
  late bool demo = widget.store.isDemo;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(inventoryChanged);
    load();
  }

  void inventoryChanged() {
    if (demo != widget.store.isDemo) {
      demo = widget.store.isDemo;
      setState(() => loading = true);
      load();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> load() async {
    final mode = widget.store.isDemo;
    try {
      await shopping.reload();
      if (mounted && mode == widget.store.isDemo) {
        setState(() {
          error = null;
          busy = false;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted && mode == widget.store.isDemo) {
        setState(() {
          error = '목록을 읽지 못했어요: $e';
          busy = false;
          loading = false;
        });
      }
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy || loading) return;
    final mode = widget.store.isDemo;
    setState(() => busy = true);
    try {
      await action();
      if (mounted && widget.store.isDemo == mode) setState(() => error = null);
    } catch (e) {
      if (mounted && widget.store.isDemo == mode) {
        inform(context, '저장하지 못했어요: $e');
      }
    } finally {
      if (mounted && widget.store.isDemo == mode) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(inventoryChanged);
    shopping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final items = shopping.items;
    final expired = shopping.expiredPlanBatches;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('필요한 만큼만, 가볍게.', style: Theme.of(context).textTheme.titleLarge),
        const InfoBox('집에 있는 재료를 빼고, 더 필요한 것만 모았어요.'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.shopping_cart_outlined),
            label: const Text('쇼핑몰 장바구니 열기'),
            onPressed: () => chooseMall(),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null) ...[
          Text(error!),
          TextButton(onPressed: load, child: const Text('다시 읽기')),
        ],
        if (shopping.plans.isNotEmpty) ...[
          Text('선택한 요리 계획', style: Theme.of(context).textTheme.titleMedium),
          ...shopping.plans.map(
            (p) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p.title,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          tooltip: '계획 삭제',
                          onPressed: busy
                              ? null
                              : () => run(() => shopping.removePlan(p.id)),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    ...p.recipes.map(
                      (r) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(r.title),
                        subtitle: Text(
                          '${r.servings}인분 · ${r.ingredients.length}개 재료',
                        ),
                        trailing: IconButton(
                          tooltip: '이 메뉴 빼기',
                          onPressed: busy
                              ? null
                              : () => run(
                                  () => shopping.removeRecipe(p.id, r.id),
                                ),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (expired.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('표시 기한이 지난 재고 확인'),
            subtitle: const Text('장보기 부족분을 계산할 때 제외했어요.'),
            children: [
              for (final batch in expired)
                ListTile(
                  title: Text('${batch.name} · ${batch.quantityLabel}'),
                  subtitle: Text(
                    '${batch.storageType.label} · ${batch.expiryLabel(widget.store.now)}',
                  ),
                ),
            ],
          ),
        if (shopping.unquantifiedIngredients.isNotEmpty)
          InfoBox(
            '잔량 확인: ${shopping.unquantifiedIngredients.join(', ')}. 보유 중이지만 정확한 양을 모르거나 요리 수량이 미상이에요. 전량 부족하다고 계산하지 않아요.',
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                '장보기 ${items.length}개',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: busy ? null : addManual,
              icon: const Icon(Icons.add),
              label: const Text('직접 추가'),
            ),
          ],
        ),
        if (items.isEmpty)
          Container(
            padding: const EdgeInsets.all(28),
            margin: const EdgeInsets.only(top: 12, bottom: 20),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2E7),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.shopping_basket_outlined,
                  size: 52,
                  color: FridgeTheme.sage,
                ),
                const SizedBox(height: 20),
                Text(
                  '장바구니가 가벼워요',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  '살 재료를 직접 적거나\n레시피에서 부족한 재료를 담아보세요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: FridgeTheme.muted),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: busy ? null : addManual,
                  icon: const Icon(Icons.add),
                  label: const Text('첫 장보기 재료 추가'),
                ),
              ],
            ),
          ),
        ...items.map(
          (item) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: item.purchased,
                          title: Text(
                            '${item.name} · ${item.quantity == null ? '수량 확인' : '${formatQuantity(item.quantity!)}${item.unit}'}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          onChanged:
                              busy ||
                                  (item.purchased &&
                                      shopping.hasIntake(item.id))
                              ? null
                              : (v) => run(
                                  () => shopping.setPurchased(item.id, v!),
                                ),
                        ),
                      ),
                      IconButton(
                        tooltip: '장보기 항목 삭제',
                        onPressed: busy
                            ? null
                            : () => run(() => shopping.removeItem(item.id)),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  if (item.planQuantity > 0)
                    Text(
                      '계획 부족분 ${formatQuantity(item.planQuantity)}${item.unit} · ${item.contributors.join(', ')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (item.manualQuantity != null)
                    Text(
                      '직접 추가 ${formatQuantity(item.manualQuantity!)}${item.unit}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (item.purchased &&
                      !item.intakeLinked &&
                      shopping.remainingIntakeQuantity(item.id) != null)
                    Text(
                      '구매 체크한 재료 중 입고할 양: ${formatQuantity(shopping.remainingIntakeQuantity(item.id)!)}${item.unit}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  Text(
                    item.intakeLinked
                        ? '실제 입고 기록 연결됨'
                        : item.purchased && shopping.hasIntake(item.id)
                        ? '일부 입고 완료 · 남은 양을 입고해주세요'
                        : item.purchased
                        ? '구매 체크 완료 · 재고에는 아직 반영되지 않아요'
                        : '구매 전',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => chooseMall(item: item),
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('쇼핑몰에서 찾기'),
                      ),
                      if (item.purchased && !item.intakeLinked)
                        TextButton(
                          onPressed: busy ? null : () => linkIntake(item),
                          child: const Text('입고 기록 연결'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (shopping.canUndo)
          TextButton.icon(
            onPressed: busy ? null : () => run(shopping.undoLast),
            icon: const Icon(Icons.undo),
            label: const Text('방금 장보기 변경 되돌리기'),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '장을 보고 돌아왔다면, 구매한 재료를 확인하고 냉장고에 넣어주세요. 구매 체크만으로 재고가 늘어나지는 않아요.',
            style: TextStyle(
              fontSize: 12,
              color: FridgeTheme.muted,
              height: 1.6,
            ),
          ),
        ),
        OutlinedButton(
          onPressed: busy ? null : purchaseIntake,
          child: const Text('구매한 재료 입고하기'),
        ),
      ],
    );
  }

  Future<void> purchaseIntake() async {
    final selected = shopping.purchasedForIntake;
    if (selected.isEmpty) {
      inform(context, '입고할 재료를 구매 체크해주세요. 이미 입고한 재료는 다시 추가하지 않아요.');
      return;
    }
    if (widget.onPurchasedIntake == null) {
      widget.onIntake();
      return;
    }
    final mode = widget.store.isDemo;
    await run(() async {
      final changeId = await widget.onPurchasedIntake!(selected);
      if (changeId == null) return;
      if (widget.store.isDemo != mode) {
        throw StateError('보관 모드가 바뀌어 입고 연결을 중단했어요.');
      }
      await shopping.markPurchasedIntakeLinked(selected, changeId);
    });
  }

  Future<void> addManual() async {
    final mode = widget.store.isDemo;
    final name = TextEditingController(), qty = TextEditingController();
    String unit = '개';
    final form = GlobalKey<FormState>();
    final entry = await showDialog<(String, double?, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('장볼 재료 추가'),
        scrollable: true,
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: '재료 이름'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '이름을 입력해주세요.' : null,
              ),
              TextFormField(
                controller: qty,
                decoration: const InputDecoration(labelText: '수량 (모르면 비워두기)'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return null;
                  final n = double.tryParse(v);
                  return n == null || !n.isFinite || n <= 0
                      ? '양수를 입력해주세요.'
                      : null;
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: unit,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '단위'),
                items: ['개', '팩', 'g', 'kg', 'ml', 'L']
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => unit = v!,
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
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, (
                  name.text.trim(),
                  double.tryParse(qty.text),
                  qty.text.isEmpty ? '' : unit,
                ));
              }
            },
            child: const Text('추가'),
          ),
        ],
      ),
    );
    if (mounted && widget.store.isDemo == mode && entry != null) {
      await run(
        () => shopping.addManual(entry.$1, quantity: entry.$2, unit: entry.$3),
      );
    }
  }

  Future<void> chooseMall({ShoppingItem? item}) async {
    final mode = widget.store.isDemo;
    final mall = await showModalBottomSheet<_ShoppingMall>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item == null ? '쇼핑몰 장바구니 열기' : '${item.name} 검색',
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
              if (item != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    item.quantity == null
                        ? '필요한 양을 확인하고 쇼핑몰에서 상품을 골라주세요.'
                        : '필요한 양 ${formatQuantity(item.quantity!)}${item.unit} · 상품과 포장 단위는 쇼핑몰에서 선택해요.',
                  ),
                ),
              const SizedBox(height: 8),
              for (final market in _ShoppingMall.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(market.label),
                  trailing: const Icon(Icons.open_in_new, size: 20),
                  onTap: () => Navigator.pop(sheet, market),
                ),
              TextButton(
                onPressed: () => Navigator.pop(sheet),
                child: const Text('취소'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || mall == null || widget.store.isDemo != mode) return;
    if (item != null &&
        mall == _ShoppingMall.coupang &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      await searchCoupang(item.name, mode);
      return;
    }
    final uri = item == null ? mall.cart : mall.search(item.name);
    final opened = await openShoppingPage(uri);
    if (!opened && mounted && widget.store.isDemo == mode) {
      inform(context, '${mall.label} 페이지를 열지 못했어요. 브라우저를 확인해주세요.');
    }
  }

  Future<bool> openShoppingPage(Uri uri) async {
    try {
      return await (widget.openShoppingUrl?.call(uri) ??
          launchUrl(uri, mode: LaunchMode.externalApplication));
    } catch (_) {
      return false;
    }
  }

  Future<void> searchCoupang(String ingredient, bool mode) async {
    const device = MethodChannel('eatkan/device');
    try {
      final opened = await device.invokeMethod<bool>(
        'openCoupangSearch',
        ingredient,
      );
      if (opened == true) return;
    } on Exception {
      // The installed app or platform may not handle the Coupang search link.
    }
    if (!mounted || widget.store.isDemo != mode) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CoupangSearchOptions(
        ingredient: ingredient,
        searchLink: _ShoppingMall.coupang.search(ingredient),
        openPage: openShoppingPage,
      ),
    );
  }

  Future<void> linkIntake(ShoppingItem item) async {
    final mode = widget.store.isDemo;
    final matches = shopping.linkableIntakes(item);
    if (matches.isEmpty) {
      inform(context, '일치하는 입고 기록이 없어요. 먼저 재료를 입고해주세요.');
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('실제 입고 기록 선택'),
        children: matches
            .take(10)
            .map(
              (h) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, h.id),
                child: Text(
                  '${h.label}\n${h.createdAt.toLocal().toString().substring(0, 16)}',
                ),
              ),
            )
            .toList(),
      ),
    );
    if (mounted && widget.store.isDemo == mode && selected != null) {
      await run(() => shopping.markIntakeLinked(item.id, selected));
    }
  }
}
