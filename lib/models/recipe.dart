String ingredientKey(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('계란', '달걀');

class RecipeIngredient {
  const RecipeIngredient({
    required this.name,
    required this.quantity,
    required this.unit,
    this.optional = false,
  });
  final String name;
  final double? quantity;
  final String unit;
  final bool optional;

  Map<String, dynamic> toJson() => {
    'name': name,
    'quantity': quantity,
    'unit': unit,
    'optional': optional,
  };
  factory RecipeIngredient.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final unit = json['unit'];
    final qty = json['quantity'];
    if (name is! String ||
        name.trim().isEmpty ||
        unit is! String ||
        (qty != null && (qty is! num || !qty.isFinite || qty <= 0))) {
      throw const FormatException('재료 이름·수량·단위를 확인할 수 없어요.');
    }
    return RecipeIngredient(
      name: name.trim(),
      quantity: (qty as num?)?.toDouble(),
      unit: unit,
      optional: json['optional'] == true,
    );
  }
}

class Recipe {
  const Recipe({
    required this.id,
    required this.title,
    required this.source,
    required this.servings,
    required this.minutes,
    required this.ingredients,
    required this.steps,
    required this.generatedAt,
    this.reason = '',
    this.allergens = const [],
    this.allergensKnown = false,
    this.preferredBatchIds = const [],
  });
  final String id;
  final String title;
  final String source;
  final int servings;
  final int minutes;
  final List<RecipeIngredient> ingredients;
  final List<String> steps;
  final DateTime generatedAt;
  final String reason;
  final List<String> allergens;
  final bool allergensKnown;
  final List<String> preferredBatchIds;
  bool get isDemo => source == 'demo';
  Uri get youtubeSearch =>
      Uri.https('www.youtube.com', '/results', {'search_query': '$title 만들기'});

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'servings': servings,
    'minutes': minutes,
    'ingredients': ingredients.map((i) => i.toJson()).toList(),
    'steps': steps,
    'generatedAt': generatedAt.toIso8601String(),
    'reason': reason,
    'allergens': allergens,
    'allergensKnown': allergensKnown,
    'preferredBatchIds': preferredBatchIds,
  };
  factory Recipe.fromJson(Map<String, dynamic> json, {String? sourceOverride}) {
    final title = json['title'];
    final servings = json['servings'];
    final minutes = json['minutes'];
    final ingredients = json['ingredients'];
    final steps = json['steps'];
    if (title is! String ||
        title.trim().isEmpty ||
        servings is! int ||
        servings < 1 ||
        minutes is! int ||
        minutes < 1 ||
        ingredients is! List ||
        ingredients.isEmpty ||
        steps is! List ||
        steps.isEmpty ||
        steps.any((s) => s is! String || s.trim().isEmpty)) {
      throw const FormatException('조리에 필요한 레시피 정보를 확인할 수 없어요. 다시 요청해주세요.');
    }
    final allergens = json['allergens'];
    if (allergens != null &&
        (allergens is! List || allergens.any((a) => a is! String))) {
      throw const FormatException('알레르기 정보를 확인할 수 없어요.');
    }
    final names = <String>{};
    for (final ingredient in ingredients) {
      if (ingredient is! Map ||
          ingredient['name'] is! String ||
          !names.add((ingredient['name'] as String).trim())) {
        throw const FormatException('중복되거나 확인할 수 없는 재료가 있어요. 다시 요청해주세요.');
      }
    }
    return Recipe(
      id: json['id'] is String
          ? json['id']
          : 'recipe-${DateTime.now().microsecondsSinceEpoch}',
      title: title.trim(),
      source: sourceOverride ?? (json['source'] as String? ?? 'ai'),
      servings: servings,
      minutes: minutes,
      ingredients: ingredients.map((i) {
        if (i is! Map) throw const FormatException('재료 정보 형식이 올바르지 않아요.');
        return RecipeIngredient.fromJson(Map<String, dynamic>.from(i));
      }).toList(),
      steps: steps.cast<String>(),
      generatedAt:
          DateTime.tryParse(json['generatedAt'] as String? ?? '') ??
          DateTime.now(),
      reason: json['reason'] is String ? json['reason'] : '',
      allergens: (allergens as List?)?.cast<String>() ?? [],
      allergensKnown: json['allergensKnown'] == true,
      preferredBatchIds:
          (json['preferredBatchIds'] as List?)
              ?.whereType<String>()
              .toSet()
              .toList() ??
          const [],
    );
  }
}
