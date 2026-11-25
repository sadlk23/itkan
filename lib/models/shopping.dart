import 'dart:convert';

import 'recipe.dart';

String shoppingKeyFor(String name, String unit) => base64Url.encode(
  utf8.encode(
    '${name.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase()}|$unit',
  ),
);

class ShoppingItem {
  const ShoppingItem({
    required this.id,
    required this.name,
    required this.unit,
    required this.quantity,
    required this.manualQuantity,
    required this.planQuantity,
    required this.purchased,
    this.contributors = const [],
    this.planQuantityUnknown = false,
    this.intakeLinked = false,
    this.intakeChangeId,
    this.purchaseReference,
    this.purchaseBatchId,
  });
  final String id, name, unit;
  final double? quantity;
  final double? manualQuantity;
  final double planQuantity;
  final bool planQuantityUnknown;
  final bool purchased, intakeLinked;
  final String? intakeChangeId, purchaseReference, purchaseBatchId;
  final List<String> contributors;
}

class RecipeShoppingResult {
  const RecipeShoppingResult({
    this.alreadyPlanned = false,
    this.amounts = const [],
    this.unknown = const [],
  });
  final bool alreadyPlanned;
  final List<({String name, double quantity, String unit})> amounts;
  final List<String> unknown;
  bool get hasMissing => amounts.isNotEmpty || unknown.isNotEmpty;

  bool matches(RecipeShoppingResult other) =>
      alreadyPlanned == other.alreadyPlanned &&
      amounts.length == other.amounts.length &&
      unknown.length == other.unknown.length &&
      amounts.toSet().containsAll(other.amounts) &&
      unknown.toSet().containsAll(other.unknown);
}

class MealPlan {
  const MealPlan({
    required this.id,
    required this.title,
    required this.recipes,
  });
  final String id, title;
  final List<Recipe> recipes;
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'recipes': recipes.map((r) => r.toJson()).toList(),
  };
  factory MealPlan.fromJson(Map<String, dynamic> json) => MealPlan(
    id: json['id'] as String,
    title: json['title'] as String,
    recipes: (json['recipes'] as List)
        .map((r) => Recipe.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList(),
  );
}

class ManualShoppingEntry {
  const ManualShoppingEntry({
    required this.name,
    this.quantity,
    this.unit = '',
  });
  final String name, unit;
  final double? quantity;
  String get id => shoppingKeyFor(name, unit);
  Map<String, dynamic> toJson() => {
    'name': name,
    'quantity': quantity,
    'unit': unit,
  };
  factory ManualShoppingEntry.fromJson(Map<String, dynamic> json) =>
      ManualShoppingEntry(
        name: json['name'] as String,
        quantity: (json['quantity'] as num?)?.toDouble(),
        unit: json['unit'] as String? ?? '',
      );
}
