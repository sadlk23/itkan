import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/ai_service.dart';

void main() {
  final scopeBatches = [
    InventoryBatch(id: 'tofu-small', name: '두부', quantity: 100, unit: 'g'),
    InventoryBatch(id: 'tofu-large', name: '두부', quantity: 800, unit: 'g'),
    InventoryBatch(id: 'carrot', name: '당근', quantity: 2, unit: '개'),
    InventoryBatch(id: 'empty', name: '우유', quantity: 0, unit: 'ml'),
    InventoryBatch(
      id: 'no-oil',
      name: '기름',
      quantity: 1,
      unit: '병',
      quantityMode: QuantityMode.status,
      stockLevel: StockLevel.none,
    ),
  ];
  List<dynamic> promptInventory(String prompt) =>
      jsonDecode(prompt.split('재고: ').last.split('\n').first) as List;
  test(
    'selection sends only the selected batch quantity even for duplicate names',
    () async {
      final client = MockClient((request) async {
        final prompt = jsonDecode(request.body)['text'] as String;
        final sent = promptInventory(prompt);
        expect(sent, hasLength(2));
        expect(sent.map((item) => item['batchId']), ['tofu-small', 'carrot']);
        expect(sent.first['quantity'], 100);
        expect(prompt, isNot(contains('tofu-large')));
        expect(prompt, isNot(contains('우유')));
        expect(prompt, contains('목록 밖 재료를 보유했다고 가정하지 마세요'));
        expect(prompt, contains('추가로 필요한 재료'));
        return http.Response('{"recipes":[]}', 200);
      });
      final service = AiService(
        baseUrl: 'https://example.invalid/ai',
        client: client,
      );
      await service.recommend(
        scopeBatches,
        selectedBatchIds: {'tofu-small', 'carrot'},
      );
      service.dispose();
    },
  );
  test(
    'empty unknown and inactive selections fail before any request',
    () async {
      var requests = 0;
      final service = AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient((_) async {
          requests++;
          return http.Response('{"recipes":[]}', 200);
        }),
      );
      for (final ids in <Set<String>>[
        {},
        {'missing'},
        {'empty'},
        {'no-oil'},
        {'tofu-small', 'missing'},
      ]) {
        await expectLater(
          service.recommend(scopeBatches, selectedBatchIds: ids),
          throwsArgumentError,
        );
      }
      expect(requests, 0);
      service.dispose();
    },
  );
  test('null selection preserves full active inventory including same-name batches', () async {
    final service = AiService(
      baseUrl: 'https://example.invalid/ai',
      client: MockClient((request) async {
        final sent = promptInventory(
          jsonDecode(request.body)['text'] as String,
        );
        expect(sent.map((item) => item['batchId']), [
          'tofu-small',
          'tofu-large',
          'carrot',
        ]);
        return http.Response('{"recipes":[]}', 200);
      }),
    );
    await service.recommend(scopeBatches);
    service.dispose();
  });

  Map<String, dynamic> responseRecipe() => AiService.demoRecipes.first.toJson();
  test(
    'missing configuration never pretends to return a live recommendation',
    () async {
      final service = AiService(baseUrl: '');
      expect(service.isConfigured, false);
      await expectLater(service.recommend([]), throwsStateError);
      service.dispose();
    },
  );
  test('recommendation keeps app selected batch priority rather than model-supplied IDs', () async {
    final service = AiService(
      baseUrl: 'https://example.invalid/ai',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'recipes': [
              {
                ...responseRecipe(),
                'preferredBatchIds': ['forged'],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final result = await service.recommend(
      scopeBatches,
      selectedBatchIds: {'tofu-small'},
    );
    expect(result.single.preferredBatchIds, ['tofu-small']);
    expect(Recipe.fromJson(result.single.toJson()).preferredBatchIds, [
      'tofu-small',
    ]);
    service.dispose();
  });
  test(
    'proxy parses validated recipes and excludes declared allergens',
    () async {
      final client = MockClient((request) async {
        expect(jsonDecode(request.body)['text'], contains('재고: []'));
        return http.Response(
          jsonEncode({
            'recipes': [responseRecipe()],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = AiService(
        baseUrl: 'https://example.invalid/ai',
        client: client,
      );
      expect((await service.recommend([])).single.isDemo, false);
      expect(await service.recommend([], allergies: ['대두']), isEmpty);
      service.dispose();
    },
  );
  test('response envelope scans message items instead of assuming output index zero', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'output': [
            {'type': 'reasoning'},
            {
              'type': 'message',
              'content': [
                {
                  'type': 'output_text',
                  'text': jsonEncode({
                    'recipes': [responseRecipe()],
                  }),
                },
              ],
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    final service = AiService(
      baseUrl: 'https://example.invalid/responses',
      model: 'provided-model',
      format: 'response',
      client: client,
    );
    expect((await service.recommend([])).single.title, '두부 김치찌개');
    service.dispose();
  });
  test(
    'invalid quantities fail closed rather than producing actionable usage',
    () {
      final json = responseRecipe();
      json['ingredients'] = [
        {'name': '두부', 'quantity': -1, 'unit': 'g'},
      ];
      expect(() => Recipe.fromJson(json), throwsFormatException);
    },
  );
  test('HTTP failure does not silently fall back to sample recipes', () async {
    final service = AiService(
      baseUrl: 'https://example.invalid/ai',
      client: MockClient((_) async => http.Response('no', 429)),
    );
    await expectLater(service.recommend([]), throwsStateError);
    service.dispose();
  });
  test('unknown ingredient amount survives snapshot roundtrip', () {
    final json = responseRecipe();
    json['ingredients'] = [
      {'name': '소금', 'quantity': null, 'unit': 'g'},
    ];
    final recipe = Recipe.fromJson(json);
    expect(
      Recipe.fromJson(recipe.toJson()).ingredients.single.quantity,
      isNull,
    );
  });
}
