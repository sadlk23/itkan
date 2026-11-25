import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';
import '../models/recipe.dart';
import '../models/shopping.dart';
import 'inventory_store.dart';

class ShoppingStore extends ChangeNotifier {
  ShoppingStore({required this.inventory}) {
    inventory.addListener(_invalidateReceiptIndex);
  }
  final InventoryStore inventory;
  static final Map<String, Future<void>> _queues = {};
  List<ManualShoppingEntry> _manual = [];
  List<MealPlan> _plans = [];
  Set<String> _purchased = {}, _hidden = {};
  Map<String, double?> _purchaseAmounts = {};
  Map<String, String> _purchaseRefs = {}, _intakeLinked = {};
  Map<String, Set<String>> _closedAdmissions = {};
  Map<String, InventoryChange>? _activeAdds;
  final Map<String, List<InventoryChange>> _addsByPurchase = {};
  final Map<String, int> _purchaseWrites = {};
  static int _sequence = 0;
  Map<String, Map<String, double>> _intakeAdmissions = {};
  bool _disposed = false;
  String? _undoBefore, _undoAfter, _undoKey, _undoReceiptIds;
  int _undoRevision = 0;
  Set<String> _undoPurchaseRefs = {};
  Map<String, String> get _currentPurchaseRefs => {
    for (final id in _purchased) id: _reference(id),
  };
  bool get canUndo =>
      _undoBefore != null &&
      _undoKey == storageKey &&
      _undoReceiptIds == _activePurchaseReceiptIds;
  int? get undoRevision => canUndo ? _undoRevision : null;
  String get _mode => inventory.isDemo ? 'demo' : 'real';
  String get storageKey => 'shopping_v2_$_mode';
  List<MealPlan> get plans => List.unmodifiable(_plans);
  List<ShoppingItem> get items => _calculate();

  /// Intake represents the checked purchase amount, not a later lower shortage.
  List<ShoppingItem> get purchasedForIntake => items
      .where((item) => item.purchased && !item.intakeLinked)
      .map(
        (item) => ShoppingItem(
          id: item.id,
          name: item.name,
          unit: item.unit,
          quantity: remainingIntakeQuantity(item.id),
          manualQuantity: item.manualQuantity,
          planQuantity: item.planQuantity,
          purchased: true,
          purchaseReference: item.purchaseReference,
          purchaseBatchId:
              'purchase:${item.purchaseReference}:${_purchaseWrites[item.purchaseReference] ?? 0}:${remainingIntakeQuantity(item.id) ?? 'unknown'}',
          contributors: item.contributors,
        ),
      )
      .toList();
  List<String> get unquantifiedIngredients => _plans
      .expand((p) => p.recipes)
      .expand((r) => r.ingredients)
      .where(
        (i) =>
            !i.optional &&
            (i.quantity == null ||
                inventory.activeBatches.any(
                  (b) =>
                      b.availableForUseOn(inventory.now) &&
                      b.quantityMode == QuantityMode.status &&
                      _sameName(b.name, i.name),
                )),
      )
      .map((i) => i.name)
      .toSet()
      .toList();

  List<InventoryBatch> get expiredPlanBatches {
    final names = _plans
        .expand((plan) => plan.recipes)
        .expand((recipe) => recipe.ingredients)
        .where((ingredient) => !ingredient.optional)
        .map((ingredient) => _normalizedName(ingredient.name))
        .toSet();
    return inventory.activeBatches
        .where(
          (batch) =>
              !batch.availableForUseOn(inventory.now) &&
              names.contains(_normalizedName(batch.name)),
        )
        .toList();
  }

  Future<void> initialize() => reload();
  Future<void> reload() async {
    final key = storageKey;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (storageKey != key) return;
    final raw = prefs.getString(key);
    _manual = [];
    _plans = [];
    _purchased = {};
    _purchaseAmounts = {};
    _purchaseRefs = {};
    _closedAdmissions = {};
    _intakeLinked = {};
    _intakeAdmissions = {};
    _hidden = {};
    if (raw != null) {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _manual = (data['manual'] as List)
          .map(
            (e) => ManualShoppingEntry.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList();
      _plans = (data['plans'] as List)
          .map((e) => MealPlan.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      _purchased = (data['purchased'] as List).cast<String>().toSet();
      _purchaseAmounts = (data['purchaseAmounts'] as Map? ?? {}).map(
        (key, value) => MapEntry(key as String, (value as num?)?.toDouble()),
      );
      _purchaseRefs = Map<String, String>.from(
        data['purchaseRefs'] as Map? ?? {},
      );
      _closedAdmissions = (data['closedAdmissions'] as Map? ?? {}).map(
        (key, ids) =>
            MapEntry(key as String, (ids as List).cast<String>().toSet()),
      );
      _intakeLinked = Map<String, String>.from(
        data['intakeLinks'] as Map? ?? {},
      );
      _intakeAdmissions = (data['intakeAdmissions'] as Map? ?? {}).map(
        (key, value) => MapEntry(
          key as String,
          (value as Map).map(
            (id, amount) => MapEntry(id as String, (amount as num).toDouble()),
          ),
        ),
      );
      _hidden = (data['hidden'] as List? ?? []).cast<String>().toSet();
      // Earlier v2 lists stored checked IDs before the amount snapshot existed.
      if (_purchased.any((id) => !_purchaseAmounts.containsKey(id))) {
        for (final item in items.where((i) => _purchased.contains(i.id))) {
          _purchaseAmounts.putIfAbsent(item.id, () => item.quantity);
        }
      }
    } else {
      final legacy =
          jsonDecode(prefs.getString('shopping_$_mode') ?? '[]') as List;
      for (final raw in legacy) {
        final e = Map<String, dynamic>.from(raw as Map);
        final name = e['name'] as String? ?? '';
        if (name.trim().isEmpty) continue;
        final entry = ManualShoppingEntry(
          name: name.trim(),
          quantity: (e['quantity'] as num?)?.toDouble(),
          unit: e['unit'] as String? ?? '',
        );
        _manual.add(entry);
        if (e['checked'] == true) {
          _purchased.add(entry.id);
          _purchaseAmounts[entry.id] = entry.quantity;
        }
      }
      await _save(prefs, key, _encoded());
    }
    if (!_disposed) notifyListeners();
  }

  String _encoded() => jsonEncode({
    'version': 2,
    'manual': _manual.map((e) => e.toJson()).toList(),
    'plans': _plans.map((p) => p.toJson()).toList(),
    'purchased': _purchased.toList(),
    'purchaseAmounts': _purchaseAmounts,
    'purchaseRefs': _purchaseRefs,
    'closedAdmissions': _closedAdmissions.map(
      (key, ids) => MapEntry(key, ids.toList()),
    ),
    'intakeLinks': _intakeLinked,
    'intakeAdmissions': _intakeAdmissions,
    'hidden': _hidden.toList(),
  });
  Future<void> _save(SharedPreferences prefs, String key, String state) async {
    final ok = await prefs.setString(key, state);
    if (!ok) throw StateError('장보기 목록을 저장하지 못했어요.');
  }

  Future<void> _change(
    void Function() change, {
    bool undoable = true,
    bool recheckNeeds = false,
  }) {
    final key = storageKey;
    final task = (_queues[key] ?? Future.value()).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await reload();
      if (storageKey != key) throw StateError('보관 모드가 바뀌었어요. 다시 시도해주세요.');
      final original = _encoded();
      final originalRefs = undoable ? _currentPurchaseRefs : <String, String>{};
      final before = recheckNeeds
          ? {for (final item in items) item.id: item.quantity}
          : null;
      try {
        change();
        if (before != null) {
          final current = items;
          final requested = {
            for (final entry in _manual) entry.id,
            for (final plan in _plans)
              for (final recipe in plan.recipes)
                for (final ingredient in recipe.ingredients)
                  if (!ingredient.optional)
                    shoppingKeyFor(
                      ingredient.name,
                      _canonical(ingredient.quantity, ingredient.unit).$2,
                    ),
          };
          for (final id in _purchased.difference(requested)) {
            _forgetPurchase(id);
          }
          for (final item in current) {
            if (before.containsKey(item.id) &&
                before[item.id] != item.quantity &&
                _purchased.contains(item.id) &&
                _recordedAmounts(item.id).isEmpty) {
              _forgetPurchase(item.id);
            }
          }
        }
        final updated = _encoded();
        if (updated != original) await _save(prefs, key, updated);
        if (storageKey != key) return;
        if (!undoable) {
          _undoBefore = null;
          _undoAfter = null;
          _undoKey = null;
        } else if (updated != original) {
          _undoBefore = original;
          _undoAfter = updated;
          _undoKey = key;
          final currentRefs = _currentPurchaseRefs;
          _undoPurchaseRefs = {
            for (final id in {...originalRefs.keys, ...currentRefs.keys})
              if (originalRefs[id] != currentRefs[id]) ...[
                ?originalRefs[id],
                ?currentRefs[id],
              ],
          };
          _undoReceiptIds = _activePurchaseReceiptIds;
          _undoRevision++;
        }
      } catch (_) {
        await reload();
        rethrow;
      }
      if (!_disposed) notifyListeners();
    });
    final queued = task.then((_) {}, onError: (Object e, StackTrace s) {});
    _queues[key] = queued;
    queued.then((_) {
      if (identical(_queues[key], queued)) _queues.remove(key);
    });
    return task;
  }

  Future<void> addManual(String name, {double? quantity, String unit = ''}) =>
      _change(() {
        final trimmed = name.trim();
        if (trimmed.isEmpty) throw ArgumentError('재료 이름을 입력해주세요.');
        if (quantity != null &&
            (!quantity.isFinite || quantity <= 0 || unit.isEmpty)) {
          throw ArgumentError('양수 수량과 단위를 확인해주세요.');
        }
        final q = _canonical(quantity, unit);
        final entry = ManualShoppingEntry(
          name: trimmed,
          quantity: q.$1,
          unit: q.$2,
        );
        _retireReceivedManual(entry.id);
        _forgetPurchase(entry.id);
        final index = _manual.indexWhere((m) => m.id == entry.id);
        if (index < 0) {
          _manual.add(entry);
        } else if (entry.quantity != null && _manual[index].quantity != null) {
          _manual[index] = ManualShoppingEntry(
            name: trimmed,
            unit: q.$2,
            quantity: _manual[index].quantity! + entry.quantity!,
          );
        }
        _hidden.remove(entry.id);
      });

  RecipeShoppingResult previewRecipeShopping(
    Recipe recipe, {
    String planId = 'next-meals',
  }) => _recipeShopping(recipe, planId).result;

  Future<RecipeShoppingResult> addRecipeToPlan(
    Recipe recipe, {
    String planId = 'next-meals',
    bool onlyIfMissing = false,
    RecipeShoppingResult? expected,
  }) async {
    late RecipeShoppingResult result;
    await _change(() {
      final proposal = _recipeShopping(recipe, planId);
      result = proposal.result;
      if (expected != null && !result.matches(expected)) return;
      if (result.alreadyPlanned || (onlyIfMissing && !result.hasMissing)) {
        return;
      }
      _plans = proposal.plans;
      _hidden = proposal.hidden;
    }, recheckNeeds: true);
    return result;
  }

  ({List<MealPlan> plans, Set<String> hidden, RecipeShoppingResult result})
  _recipeShopping(Recipe recipe, String planId) {
    final index = _plans.indexWhere((p) => p.id == planId);
    final current = index < 0 ? null : _plans[index];
    final recipes = [...?current?.recipes];
    final recipeIndex = recipes.indexWhere((r) => r.id == recipe.id);
    if (recipeIndex >= 0) {
      if (jsonEncode(recipes[recipeIndex].toJson()) ==
          jsonEncode(recipe.toJson())) {
        return (
          plans: _plans,
          hidden: _hidden,
          result: const RecipeShoppingResult(alreadyPlanned: true),
        );
      }
      recipes[recipeIndex] = recipe;
    } else {
      recipes.add(recipe);
    }
    final plan = MealPlan(
      id: planId,
      title: current?.title ?? '함께 만들 메뉴',
      recipes: recipes,
    );
    final plans = [..._plans];
    if (index < 0) {
      plans.add(plan);
    } else {
      plans[index] = plan;
    }

    final ingredients = recipe.ingredients.where((i) => !i.optional);
    final keys = {
      for (final i in ingredients)
        shoppingKeyFor(i.name, _canonical(i.quantity, i.unit).$2),
    };
    final hidden = _hidden.difference(keys);
    final previous = {for (final row in items) row.id: row.planQuantity};
    final amounts = <({String name, double quantity, String unit})>[];
    final unknown = {
      for (final i in ingredients)
        if (i.quantity == null) i.name,
    };
    // Calculate both shopping lists with the same allocation of stock across menus.
    for (final row in _calculate(plans: plans, hidden: hidden)) {
      if (!keys.contains(row.id)) continue;
      final increase = row.planQuantity - (previous[row.id] ?? 0);
      if (row.planQuantityUnknown) {
        unknown.add(row.name);
      } else if (increase > 0) {
        amounts.add((name: row.name, quantity: increase, unit: row.unit));
      }
    }
    return (
      plans: plans,
      hidden: hidden,
      result: RecipeShoppingResult(amounts: amounts, unknown: unknown.toList()),
    );
  }

  Future<void> upsertPlan({
    required String planId,
    required String title,
    required List<Recipe> recipes,
  }) => _change(() {
    if (planId.trim().isEmpty) throw ArgumentError('계획 ID가 필요합니다.');
    final unique = {for (final r in recipes) r.id: r};
    _plans.removeWhere((p) => p.id == planId);
    _plans.add(
      MealPlan(id: planId, title: title, recipes: unique.values.toList()),
    );
    _hidden.clear();
  }, recheckNeeds: true);
  Future<void> removePlan(String id) =>
      _change(() => _plans.removeWhere((p) => p.id == id), recheckNeeds: true);
  Future<void> removeRecipe(String planId, String recipeId) => _change(() {
    _plans = _plans
        .map(
          (p) => p.id == planId
              ? MealPlan(
                  id: p.id,
                  title: p.title,
                  recipes: p.recipes.where((r) => r.id != recipeId).toList(),
                )
              : p,
        )
        .where((p) => p.recipes.isNotEmpty)
        .toList();
  }, recheckNeeds: true);

  void _startPurchase(String id, double? quantity) {
    _purchased.add(id);
    _purchaseAmounts[id] = quantity;
    _purchaseRefs[id] =
        'shopping:${DateTime.now().microsecondsSinceEpoch}-${_sequence++}:$id';
  }

  String _reference(String id) =>
      _purchaseRefs[id] ?? 'shopping:legacy:$_mode:$id';

  void _forgetPurchase(String id) {
    if (!_purchased.contains(id)) return;
    final used = _recordedAmounts(id).keys.where((event) {
      final change = _additions[event]!;
      return change.source != 'shopping' ||
          change.after.any(
            (b) => b.ingredientId == null && _legacyPurchaseId.hasMatch(b.id),
          );
    });
    if (used.isNotEmpty) (_closedAdmissions[id] ??= {}).addAll(used);
    _purchased.remove(id);
    _purchaseAmounts.remove(id);
    _purchaseRefs.remove(id);
    _intakeLinked.remove(id);
    _intakeAdmissions.remove(id);
  }

  // Stock already received first covers the menu shortage, then the manual request.
  void _retireReceivedManual(String id) {
    if (!_purchased.contains(id) || !hasIntake(id)) return;
    final entries = _manual.where((entry) => entry.id == id).toList();
    if (entries.isEmpty) return;
    final manual = entries.fold(
      0.0,
      (sum, entry) => sum + (entry.quantity ?? 0),
    );
    final remaining = remainingIntakeQuantity(id);
    _manual.removeWhere((entry) => entry.id == id);
    if (remaining == null || remaining <= 0 || manual == 0) return;
    _manual.add(
      ManualShoppingEntry(
        name: entries.first.name,
        unit: entries.first.unit,
        quantity: remaining.clamp(0.0, manual).toDouble(),
      ),
    );
  }

  Future<void> setPurchased(String id, bool value) => _change(() {
    final item = items.where((item) => item.id == id).firstOrNull;
    if (value) {
      if (item == null && _fullyIntakeLinked(id)) return;
      if (item == null) throw StateError('현재 장보기 항목을 다시 확인해주세요.');
      if (item.purchased) return;
      _retireReceivedManual(id);
      _forgetPurchase(id);
      final updated = items.where((item) => item.id == id).firstOrNull;
      if (updated != null) _startPurchase(id, updated.quantity);
    } else if (_recordedAmounts(id).isNotEmpty) {
      throw StateError('이미 입고한 구매예요. 기록에서 해당 입고를 먼저 되돌려주세요.');
    } else {
      _forgetPurchase(id);
    }
  });
  Future<void> removeItem(String id) => _change(() {
    _manual.removeWhere((e) => e.id == id);
    _hidden.add(id);
    _forgetPurchase(id);
  });

  double? _manualReceiptAmount(
    ShoppingItem item,
    InventoryChange change, {
    bool allowLegacyShopping = false,
  }) {
    if (_closedAdmissions[item.id]?.contains(change.id) ?? false) return null;
    return _receiptAmount(
      item.id,
      _purchaseAmounts.containsKey(item.id)
          ? _purchaseAmounts[item.id]
          : item.quantity,
      change.after.where(
        (batch) =>
            change.source != 'shopping' ||
            batch.ingredientId == _reference(item.id) ||
            (allowLegacyShopping &&
                batch.ingredientId == null &&
                _legacyPurchaseId.hasMatch(batch.id)),
      ),
    );
  }

  // Shopping receipts saved before purchase references were introduced can
  // still be linked by explicit selection in the history dialog.
  static final _legacyPurchaseId = RegExp(r'^purchase-\d+-\d+$');

  List<InventoryChange> linkableIntakes(ShoppingItem item) {
    final used = _recordedAmounts(item.id);
    return _additions.values
        .where(
          (change) =>
              !used.containsKey(change.id) &&
              _manualReceiptAmount(item, change, allowLegacyShopping: true) !=
                  null,
        )
        .toList();
  }

  Future<void> markIntakeLinked(String id, String changeId) => _change(() {
    if (_recordedAmounts(id).containsKey(changeId)) return;
    if (_fullyIntakeLinked(id)) throw StateError('이 구매는 이미 전량 입고했어요.');
    final item = items.where((i) => i.id == id).firstOrNull;
    final change = _additions[changeId];
    final amount = item == null || change == null
        ? null
        : _manualReceiptAmount(item, change, allowLegacyShopping: true);
    if (amount == null) throw StateError('이름과 단위가 일치하는 실제 입고 기록을 선택해주세요.');
    if (!_purchased.contains(id)) _startPurchase(id, item!.quantity);
    (_intakeAdmissions[id] ??= {})[changeId] = amount;
    _intakeLinked[id] = changeId;
  }, undoable: false);
  Future<void> clear() => _change(() {
    _purchaseRefs = {};
    _closedAdmissions = {};
    _manual = [];
    _plans = [];
    _purchased = {};
    _purchaseAmounts = {};
    _intakeAdmissions = {};
    _intakeLinked = {};
    _hidden = {};
  });
  Future<void> undoLast() async {
    final key = storageKey;
    final task = (_queues[key] ?? Future.value()).then((_) async {
      if (!canUndo || storageKey != key) throw StateError('되돌릴 장보기 변경이 없습니다.');
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (storageKey != key ||
          _undoKey != key ||
          prefs.getString(key) != _undoAfter) {
        throw StateError('이후 변경이 있어 되돌릴 수 없습니다.');
      }
      if (!await prefs.setString(key, _undoBefore!)) {
        throw StateError('되돌리기를 저장하지 못했어요.');
      }
      if (_undoKey == key) {
        _undoBefore = null;
        _undoAfter = null;
        _undoKey = null;
      }
      await reload();
    });
    final queued = task.then((_) {}, onError: (Object e, StackTrace s) {});
    _queues[key] = queued;
    queued.then((_) {
      if (identical(_queues[key], queued)) _queues.remove(key);
    });
    return task;
  }

  List<ShoppingItem> _calculate({List<MealPlan>? plans, Set<String>? hidden}) {
    final needs = <String, double>{},
        names = <String, String>{},
        units = <String, String>{};
    final contributors = <String, Set<String>>{};
    for (final plan in plans ?? _plans) {
      for (final recipe in plan.recipes) {
        for (final ingredient in recipe.ingredients) {
          if (ingredient.quantity == null || ingredient.optional) continue;
          final converted = _canonical(ingredient.quantity, ingredient.unit);
          final key = shoppingKeyFor(ingredient.name, converted.$2);
          needs[key] = (needs[key] ?? 0) + converted.$1!;
          names[key] = ingredient.name;
          units[key] = converted.$2;
          (contributors[key] ??= <String>{}).add(recipe.title);
        }
      }
    }
    final available = <String, double>{};
    final statusNames = inventory.activeBatches
        .where(
          (b) =>
              b.availableForUseOn(inventory.now) &&
              b.quantityMode == QuantityMode.status,
        )
        .map((b) => b.name.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase())
        .toSet();
    for (final batch in inventory.batches.where(
      (b) =>
          b.availableForUseOn(inventory.now) &&
          b.quantityMode == QuantityMode.measured,
    )) {
      final q = _canonical(batch.quantity, batch.unit);
      final key = shoppingKeyFor(batch.name, q.$2);
      available[key] = (available[key] ?? 0) + q.$1!;
    }
    final manual = <String, double?>{};
    for (final entry in _manual) {
      names[entry.id] = entry.name;
      units[entry.id] = entry.unit;
      manual[entry.id] = entry.quantity == null
          ? null
          : (manual[entry.id] ?? 0) + entry.quantity!;
    }
    final result = <ShoppingItem>[];
    for (final key in {...needs.keys, ...manual.keys}) {
      if ((hidden ?? _hidden).contains(key)) continue;
      final shortage = ((needs[key] ?? 0) - (available[key] ?? 0))
          .clamp(0, double.infinity)
          .toDouble();
      final hasManual = manual.containsKey(key);
      final linked = _fullyIntakeLinked(key);
      if (!hasManual &&
          shortage <= 0 &&
          (!_purchased.contains(key) || linked)) {
        continue;
      }
      final unknownStock =
          shortage > 0 &&
          statusNames.contains(
            names[key]!.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase(),
          );
      final quantity = unknownStock || (hasManual && manual[key] == null)
          ? null
          : shortage + (manual[key] ?? 0);
      final bought =
          _purchased.contains(key) &&
          _purchaseAmounts.containsKey(key) &&
          !(linked && shortage > 0) &&
          (quantity == null
              ? _purchaseAmounts[key] == null
              : _purchaseAmounts[key] != null &&
                    quantity <= _purchaseAmounts[key]!);
      result.add(
        ShoppingItem(
          id: key,
          name: names[key]!,
          unit: units[key]!,
          quantity: quantity,
          manualQuantity: manual[key],
          planQuantity: unknownStock ? 0 : shortage,
          planQuantityUnknown: unknownStock,
          purchased: bought,
          intakeLinked: bought && linked,
          intakeChangeId: _recordedAmounts(key).keys.lastOrNull,
          purchaseReference: bought ? _reference(key) : null,
          contributors: contributors[key]?.toList() ?? [],
        ),
      );
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  (double?, String) _canonical(double? quantity, String unit) {
    if (unit == 'kg') return (quantity == null ? null : quantity * 1000, 'g');
    if (unit == 'L') return (quantity == null ? null : quantity * 1000, 'ml');
    return (quantity, unit);
  }

  static String _normalizedName(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  static bool _sameName(String a, String b) =>
      _normalizedName(a) == _normalizedName(b);

  void _invalidateReceiptIndex() => _activeAdds = null;

  Map<String, InventoryChange> get _additions {
    _indexReceipts();
    return _activeAdds!;
  }

  void _indexReceipts() {
    if (_activeAdds != null) return;
    final active = <String, InventoryChange>{};
    _addsByPurchase.clear();
    _purchaseWrites.clear();
    for (final change in inventory.history) {
      if (change.action != 'add') continue;
      if (!change.undone) active[change.id] = change;
      if (change.source == 'shopping') {
        for (final ref
            in change.after
                .map((b) => b.ingredientId)
                .whereType<String>()
                .toSet()) {
          _purchaseWrites[ref] = (_purchaseWrites[ref] ?? 0) + 1;
          if (!change.undone) (_addsByPurchase[ref] ??= []).add(change);
        }
      }
    }
    _activeAdds = active;
  }

  String get _activePurchaseReceiptIds {
    if (_undoPurchaseRefs.isEmpty) return '';
    _indexReceipts();
    return _undoPurchaseRefs
        .expand((ref) => _addsByPurchase[ref] ?? <InventoryChange>[])
        .map((change) => change.id)
        .toSet()
        .join('|');
  }

  // A purchase row's key contains its normalized name and unit, including
  // the original units used by older saved shopping lists.
  double? _receiptAmount(
    String id,
    double? purchased,
    Iterable<InventoryBatch> batches,
  ) {
    final key = utf8.decode(base64Url.decode(id));
    final separator = key.lastIndexOf('|');
    final name = key.substring(0, separator);
    final unit = key.substring(separator + 1);
    var amount = 0.0;
    for (final batch in batches) {
      if (_normalizedName(batch.name) != name) continue;
      if (purchased == null) return 0;
      if (batch.quantityMode != QuantityMode.measured) continue;
      try {
        amount += convertQuantity(batch.quantity, batch.unit, unit);
      } on ArgumentError {
        // Different package units can't establish an admitted quantity.
      }
    }
    return amount > 0 ? amount : null;
  }

  Map<String, double> _recordedAmounts(String id) {
    if (!_purchased.contains(id)) return {};
    final active = _additions;
    final ledger = _intakeAdmissions[id];
    final result = <String, double>{
      for (final entry in (ledger ?? <String, double>{}).entries)
        if (active.containsKey(entry.key)) entry.key: entry.value,
    };
    final legacy = _intakeLinked[id];
    if (ledger == null && legacy != null && active.containsKey(legacy)) {
      result[legacy] = _purchaseAmounts[id] ?? 0;
    }
    final ref = _reference(id);
    final changes = _addsByPurchase[ref];
    if (changes == null) return result;
    for (final change in changes) {
      if (result.containsKey(change.id)) continue;
      final amount = _receiptAmount(
        id,
        _purchaseAmounts[id],
        change.after.where((b) => b.ingredientId == ref),
      );
      if (amount != null) result[change.id] = amount;
    }
    return result;
  }

  double? remainingIntakeQuantity(String id) {
    final purchased = _purchaseAmounts[id];
    if (purchased == null) return null;
    final admitted = _recordedAmounts(id).values
        .fold(0.0, (sum, value) => sum + value);
    return (purchased - admitted).clamp(0, double.infinity).toDouble();
  }

  bool hasIntake(String id) => _recordedAmounts(id).isNotEmpty;
  bool _fullyIntakeLinked(String id) =>
      hasIntake(id) &&
      (_purchaseAmounts[id] == null || remainingIntakeQuantity(id) == 0);

  Future<void> markPurchasedIntakeLinked(
    List<ShoppingItem> originals,
    String changeId,
  ) => _change(() {
    final change = _additions[changeId];
    if (change == null) throw StateError('저장된 입고 기록을 확인할 수 없어요.');
    for (final item in originals) {
      final id = item.id;
      if (!_purchased.contains(id) ||
          (item.purchaseReference != null &&
              item.purchaseReference != _reference(id)) ||
          (_closedAdmissions[id]?.contains(changeId) ?? false) ||
          _intakeAdmissions[id]?.containsKey(changeId) == true) {
        continue;
      }
      // Imported manual receipts lack purchase references. Do not assign a
      // same-name batch to both a measured row and an unknown-quantity row.
      if (change.source != 'shopping' &&
          item.quantity == null &&
          originals.where((other) => _sameName(other.name, item.name)).length >
              1) {
        continue;
      }
      final amount = _manualReceiptAmount(item, change);
      if (amount == null) continue;
      (_intakeAdmissions[id] ??= {})[changeId] = amount;
      _intakeLinked[id] = changeId;
    }
  }, undoable: false);

  @override
  void dispose() {
    _disposed = true;
    inventory.removeListener(_invalidateReceiptIndex);
    super.dispose();
  }
}
