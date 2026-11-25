import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/inventory.dart';
import '../models/recipe.dart';

/// Sends recipe and kitchen requests to the configured AI endpoint.
/// A proxy returns {"recipes": [...]} or {"answer": "JSON text"}.
class AiService {
  static int _recipeSequence = 0;
  AiService({
    http.Client? client,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? format,
    String? proxyToken,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl ?? const String.fromEnvironment('AI_BASE_URL'),
       _apiKey = apiKey ?? const String.fromEnvironment('AI_API_KEY'),
       _model = model ?? const String.fromEnvironment('AI_MODEL'),
       _proxyToken = proxyToken ?? const String.fromEnvironment('AI_PROXY_TOKEN'),
       _format =
           format ??
           const String.fromEnvironment('AI_API_FORMAT', defaultValue: 'proxy');
  final http.Client _client;
  final String _baseUrl, _apiKey, _model, _format;
  final String _proxyToken;
  bool get isConfigured => _baseUrl.trim().isNotEmpty;
  void dispose() => _client.close();

  /// Returns validated JSON data, never executes a proposed action.
  Future<Map<String, dynamic>> requestStructured(String prompt) async {
    if (!isConfigured) throw StateError('제공받은 AI API 연결 설정이 필요합니다.');
    final uri = Uri.tryParse(_baseUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw StateError('AI 요청 주소를 확인해주세요.');
    }
    if (!['proxy', 'response', 'chat'].contains(_format)) {
      throw StateError('지원하지 않는 AI 응답 형식입니다.');
    }
    if (_format != 'proxy' && _model.isEmpty) {
      throw StateError('제공받은 모델 설정이 필요합니다.');
    }
    final body = switch (_format) {
      'response' => {
        'model': _model,
        'input': prompt,
        'store': false,
        'max_output_tokens': 4000,
      },
      'chat' => {
        'model': _model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      },
      _ => {'text': prompt},
    };
    final encodedBody = utf8.encode(jsonEncode(body));
    if (_format == 'proxy' && encodedBody.length > 128 * 1024) {
      throw StateError('요청에 담긴 정보가 너무 많아요. 사용할 재료나 질문의 범위를 줄여주세요.');
    }
    final response = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
            if (_format == 'proxy' && _proxyToken.isNotEmpty) 'x-itkan-client': _proxyToken,
          },
          body: encodedBody,
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('AI 요청 실패 (${response.statusCode}). 재고는 변경되지 않았습니다.');
    }
    final payload = _extractPayload(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
    if (payload is! Map) throw const FormatException('AI 응답을 검증할 수 없습니다.');
    return Map<String, dynamic>.from(payload);
  }

  List<Map<String, dynamic>> _recommendationInventory(
    List<InventoryBatch> batches,
  ) {
    Map<String, dynamic> row(InventoryBatch b) => {
      'name': b.name,
      if (b.quantityMode == QuantityMode.measured) ...{
        'quantity': b.quantity,
        'unit': b.unit,
      } else
        'stockLevel': b.stockLevel.name,
      if (b.daysRemaining() case final days?) ...{
        'daysRemaining': days,
        'expiryStatus': b.expiryStatus.name,
      },
    };
    final individual = [
      for (final b in batches) {'batchId': b.id, ...row(b)},
    ];
    if (utf8.encode(jsonEncode(jsonEncode(individual))).length <= 96 * 1024) {
      return individual;
    }
    // The model needs the available quantity and date, not every purchase ID.
    // Preserve distinct dates, units and stock levels while combining like rows.
    final grouped =
        <
          (String, QuantityMode, String, int?, ExpiryStatus, StockLevel?),
          Map<String, dynamic>
        >{};
    for (final b in batches) {
      final level = b.quantityMode == QuantityMode.status ? b.stockLevel : null;
      final key = (
        b.name,
        b.quantityMode,
        b.unit,
        b.daysRemaining(),
        b.expiryStatus,
        level,
      );
      final existing = grouped[key];
      if (existing == null) {
        grouped[key] = row(b);
      } else if (level == null) {
        existing['quantity'] = (existing['quantity'] as double) + b.quantity;
      }
    }
    return grouped.values.toList();
  }

  /// Null selection uses all active inventory. An explicit selection sends only
  /// those batch IDs (not every batch sharing a name). Empty, stale or inactive
  /// selections fail before HTTP so the request cannot silently broaden scope.
  Future<List<Recipe>> recommend(
    List<InventoryBatch> batches, {
    List<String> allergies = const [],
    List<String> excludedIngredients = const [],
    int servings = 1,
    int maxMinutes = 30,
    String preferences = '',
    String equipment = '',
    Set<String>? selectedBatchIds,
  }) async {
    if (servings < 1 || maxMinutes < 1) {
      throw ArgumentError('인분과 조리 시간은 1 이상이어야 합니다.');
    }
    // A passed recorded date is not a safety diagnosis. Exclude it from the
    // available supply until the user checks and corrects the inventory entry.
    final active = batches.where((batch) => batch.isAvailableForUse).toList();
    if (selectedBatchIds != null) {
      if (selectedBatchIds.isEmpty) {
        throw ArgumentError.value(
          selectedBatchIds,
          'selectedBatchIds',
          '요리에 사용할 재료를 선택해주세요.',
        );
      }
      final activeIds = active.map((batch) => batch.id).toSet();
      if (!activeIds.containsAll(selectedBatchIds)) {
        throw ArgumentError.value(
          selectedBatchIds,
          'selectedBatchIds',
          '선택한 재료가 없거나 모두 사용됐거나 표시 기한이 지났어요. 재고의 날짜·보관 상태를 확인하고 다시 선택해주세요.',
        );
      }
    }
    final scopedBatches = selectedBatchIds == null
        ? active
        : active.where((batch) => selectedBatchIds.contains(batch.id)).toList();
    final inventory = _recommendationInventory(scopedBatches);
    final prompt =
        '''보유 재료를 활용할 요리를 최대 3개 추천하세요. $servings 인분, $maxMinutes 분 이하입니다.
${selectedBatchIds == null ? '전체 보유 재고를 기준으로 추천하세요.' : '사용자가 선택한 재료만 보유 재고로 간주하세요. 선택한 모든 재료명을 각 요리의 필수 재료에 동일한 이름으로 포함하세요. 목록 밖 재료를 보유했다고 가정하지 마세요. 추가로 필요한 재료는 추천 이유와 재료 목록에서 구분하세요.'}
선호 조건: ${jsonEncode(preferences)}
사용 가능한 조리 도구: ${jsonEncode(equipment)}
사용자가 전자레인지만 사용한다고 한 경우 가스불·팬·지짐·볶기·오븐 단계는 금지합니다. 실제 전자레인지 조리에 맞는 용기와 짧은 가열 구간·중간 섞기·상태 확인을 단계에 적으세요. 출력과 양에 따른 권장 시간을 구분하고 특히 달걀 등은 충분히 익었는지 확인하도록 안내하세요. 전자레인지에서 금속 용기나 껍데기째 달걀을 사용하도록 제안하지 마세요. 도구에 맞지 않는 조리법 이름만 바꿔 제안하지 마세요.
알레르기 제외 성분: ${jsonEncode(allergies)}
이번 요청에서 반드시 제외할 재료: ${jsonEncode(excludedIngredients)}
재고: ${jsonEncode(inventory)}
현재 날짜: ${DateTime.now().toIso8601String()}
임박 재료를 우선하되 미상 날짜를 추정하지 마세요. daysRemaining이 음수인 재료는 표시 기한이 지난 상태이며 신선하거나 안전하다고 단정하지 마세요. 선택 재료에 포함되어 있으면 추천 이유에 기한 경과와 사용 전 제품 표시·보관 상태 확인 필요를 명시하세요. expiryStatus의 actual/estimated/unknown을 구분하고 추정 날짜를 확정 기한으로 말하지 마세요. 재고를 수정하거나 실행했다고 말하지 마세요.
출력은 JSON 객체 {"recipes":[{"title":"요리명","servings":1,"minutes":20,"reason":"추천 이유","ingredients":[{"name":"재료명","quantity":100,"unit":"g","optional":false}],"steps":["조리 단계"],"allergens":["확인된 성분"],"allergensKnown":false}]} 만 반환하세요.
재료 수량을 알 수 없으면 null로 표시하세요. 재료명은 가능한 한 입력 재고명과 일치시키세요. 팩/개를 g/ml로 임의 환산하지 마세요.
조리 단계에서 실제 사용하는 모든 재료를 ingredients에 빠짐없이 적으세요. 식용유·소금·후추·물 등 양념도 생략하지 마세요. ingredients에 없는 재료를 단계에서 새로 사용하지 마세요. 재고에 없는 재료는 보유하지 않은 것으로 간주하고, 추가로 필요한 재료명을 reason에 명시하세요. 재료를 선택 사항으로 표기할 때만 단계에서도 생략 가능하다고 설명하세요.
확인된 알레르기 성분이 있는 요리는 제외하세요. 알레르기 안전을 보장하지 마세요. 출처 URL을 생성하지 마세요.''';
    final payload = await requestStructured(prompt);
    if (payload['recipes'] is! List) {
      throw const FormatException('AI 응답에서 레시피 목록을 찾지 못했어요.');
    }
    final entries = payload['recipes'] as List;
    if (entries.length > 3) {
      throw const FormatException('추천은 최대 3개까지 받을 수 있어요. 다시 요청해주세요.');
    }
    final requestId =
        'ai-recipe-${DateTime.now().microsecondsSinceEpoch}-${_recipeSequence++}';
    final inventoryNames = scopedBatches.map((b) => b.name.trim()).toSet();
    String inventoryName(String name) {
      final trimmed = name.trim();
      if (inventoryNames.contains(trimmed)) return trimmed;
      final matches = inventoryNames
          .where(
            (candidate) => ingredientKey(candidate) == ingredientKey(trimmed),
          )
          .toList();
      return matches.length == 1 ? matches.single : trimmed;
    }

    final recipes = entries.indexed.map((entry) {
      final e = entry.$2;
      if (e is! Map) throw const FormatException('레시피 형식을 확인할 수 없어요.');
      return Recipe.fromJson({
        ...Map<String, dynamic>.from(e),
        if (e['ingredients'] is List)
          'ingredients': (e['ingredients'] as List).map((ingredient) {
            if (ingredient is! Map || ingredient['name'] is! String) {
              return ingredient;
            }
            return {
              ...ingredient,
              'name': inventoryName(ingredient['name'] as String),
            };
          }).toList(),
        'id': '$requestId-${entry.$1}',
        // Generated claims cannot establish complete allergen knowledge.
        'allergensKnown': false,
        'preferredBatchIds': selectedBatchIds?.toList() ?? <String>[],
      }, sourceOverride: 'ai');
    }).toList();
    final selectedNames = scopedBatches.map((b) => b.name.trim()).toSet();
    for (final recipe in recipes) {
      final excluded = excludedIngredients.map(ingredientKey).toSet();
      if (recipe.ingredients.any(
        (i) => excluded.contains(ingredientKey(i.name)),
      )) {
        throw const FormatException(
          '제외한 재료가 수정안에 포함되어 있어 적용하지 않았어요. 다시 요청해주세요.',
        );
      }
      if (recipe.servings != servings || recipe.minutes > maxMinutes) {
        throw const FormatException(
          'AI가 인분·시간 조건을 지키지 않았어요. 조건을 유지한 채 다시 요청해주세요.',
        );
      }
      if (selectedBatchIds != null &&
          !recipe.ingredients
              .where((i) => !i.optional)
              .map((i) => i.name.trim())
              .toSet()
              .containsAll(selectedNames)) {
        throw const FormatException('선택한 재료를 사용하는 요리가 아니에요. 다시 요청해주세요.');
      }
    }
    return recipes.where((r) => !hasDeclaredAllergen(r, allergies)).toList();
  }

  dynamic _extractPayload(dynamic data) {
    if (data is! Map) throw const FormatException('AI 응답 형식이 올바르지 않아요.');
    if (data['recipes'] is List ||
        data['command'] is Map ||
        data['reply'] is String ||
        data['candidates'] is List ||
        data['intake'] is List) {
      return data;
    }
    String text = '';
    if (_format == 'proxy' && data['answer'] is String) text = data['answer'];
    if (_format == 'chat' &&
        data['choices'] is List &&
        (data['choices'] as List).isNotEmpty) {
      final first = data['choices'][0];
      if (first is Map &&
          first['message'] is Map &&
          first['message']['content'] is String) {
        text = first['message']['content'];
      }
    }
    if (_format == 'response' && data['output'] is List) {
      for (final entry in data['output']) {
        if (entry is! Map ||
            entry['type'] != 'message' ||
            entry['content'] is! List) {
          continue;
        }
        for (final content in entry['content']) {
          if (content is Map &&
              content['type'] == 'output_text' &&
              content['text'] is String) {
            text += content['text'] as String;
          }
        }
      }
    }
    text = text.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
    }
    if (text.isEmpty) {
      throw const FormatException('AI가 읽을 수 있는 레시피를 반환하지 않았어요.');
    }
    return jsonDecode(text);
  }

  static bool hasDeclaredAllergen(Recipe recipe, List<String> allergies) {
    // Only explicit equivalences: this is not a hidden-ingredient safety check.
    String normalized(String value) {
      final name = value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
      return switch (name) {
        '대두' ||
        '콩' ||
        '두부' ||
        '순두부' ||
        '연두부' ||
        '두유' ||
        'soy' ||
        'soybean' => '대두',
        '달걀' ||
        '계란' ||
        '난류' ||
        '알류' ||
        '계란흰자' ||
        '달걀흰자' ||
        '계란노른자' ||
        '달걀노른자' ||
        'egg' ||
        'eggs' => '난류',
        '우유' || 'milk' => '우유',
        _ => name,
      };
    }

    final known = {
      ...recipe.allergens.map(normalized),
      ...recipe.ingredients.map((i) => normalized(i.name)),
    };
    return allergies.any((a) => known.contains(normalized(a)));
  }

  static List<Recipe> get demoRecipes => [
    Recipe(
      id: 'demo-tofu-kimchi',
      title: '두부 김치찌개',
      source: 'demo',
      servings: 1,
      minutes: 20,
      reason: '두부를 먼저 활용하고 보유한 김치와 대파를 함께 사용할 수 있어요.',
      ingredients: const [
        RecipeIngredient(name: '두부', quantity: 150, unit: 'g'),
        RecipeIngredient(name: '김치', quantity: 200, unit: 'g'),
        RecipeIngredient(name: '대파', quantity: 20, unit: 'g'),
        RecipeIngredient(name: '물', quantity: 300, unit: 'ml', optional: true),
      ],
      steps: const [
        '두부 150g을 먹기 좋은 크기로 썰고 대파 20g을 송송 썰어주세요.',
        '냄비에 김치 200g과 물 300ml를 넣고 끓여주세요.',
        '두부를 넣고 약불에서 끓여주세요. 상태를 보며 물을 보충하세요.',
        '대파를 넣고 한 번 더 끓인 뒤 간을 확인하면 완성이에요.',
      ],
      generatedAt: DateTime(2026, 11, 6),
      allergens: const ['대두'],
      allergensKnown: false,
    ),
  ];
}
