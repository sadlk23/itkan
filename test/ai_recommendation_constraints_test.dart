import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/ai_service.dart';

void main() {
  final recipe = AiService.demoRecipes.first.toJson();
  AiService serviceFor(List<Map<String, dynamic>> recipes) => AiService(
    baseUrl: 'https://example.invalid/ai',
    client: MockClient(
      (_) async => http.Response.bytes(
        utf8.encode(jsonEncode({'recipes': recipes})),
        200,
      ),
    ),
  );
  for (final scenario in ['count', 'minutes', 'servings']) {
    test(
      'rejects $scenario contract violations instead of exposing recipes',
      () async {
        final recipes = scenario == 'count'
            ? List.generate(4, (_) => recipe)
            : [
                {
                  ...recipe,
                  if (scenario == 'minutes') 'minutes': 31,
                  if (scenario == 'servings') 'servings': 2,
                },
              ];
        final service = serviceFor(recipes);
        addTearDown(service.dispose);
        await expectLater(service.recommend([]), throwsFormatException);
      },
    );
  }
  test('unambiguous egg alias is canonicalized to the actual selected inventory name', () async {
    final service = serviceFor([
      {
        ...recipe,
        'ingredients': [
          {'name': '계란', 'quantity': 1, 'unit': '개'},
        ],
      },
    ]);
    addTearDown(service.dispose);
    final inventory = [
      InventoryBatch(id: 'egg', name: '달걀', quantity: 2, unit: '개'),
    ];
    final result = await service.recommend(
      inventory,
      selectedBatchIds: {'egg'},
    );
    expect(result.single.ingredients.single.name, inventory.single.name);
    await expectLater(
      service.recommend(inventory, excludedIngredients: ['계란']),
      throwsFormatException,
    );
  });
  test('exact inventory name wins over a known alias', () async {
    final service = serviceFor([
      {
        ...recipe,
        'ingredients': [
          {'name': '계란', 'quantity': 1, 'unit': '개'},
        ],
      },
    ]);
    addTearDown(service.dispose);
    final result = await service.recommend([
      InventoryBatch(id: 'egg1', name: '달걀', quantity: 2, unit: '개'),
      InventoryBatch(id: 'egg2', name: '계란', quantity: 2, unit: '개'),
    ]);
    expect(result.single.ingredients.single.name, '계란');
  });
  test('model cannot assert complete allergen knowledge', () async {
    final service = serviceFor([
      {...recipe, 'allergensKnown': true},
    ]);
    addTearDown(service.dispose);
    expect((await service.recommend([])).single.allergensKnown, isFalse);
  });
  for (final entry in {
    '두부': '대두',
    '순두부': '콩',
    '연두부': 'soy',
    '두유': '대두',
    '계란': '알류',
    '달걀': '난류',
    '우유': 'milk',
  }.entries) {
    test(
      'filters explicit ${entry.key} equivalence even when model omits allergen',
      () async {
        final service = serviceFor([
          {
            ...recipe,
            'allergens': <String>[],
            'ingredients': [
              {'name': entry.key, 'quantity': 1, 'unit': '개'},
            ],
          },
        ]);
        addTearDown(service.dispose);
        expect(await service.recommend([], allergies: [entry.value]), isEmpty);
      },
    );
  }
  test(
    'app assigns distinct recipe IDs even when the model duplicates IDs',
    () async {
      final service = serviceFor([recipe, recipe, recipe]);
      addTearDown(service.dispose);
      final first = await service.recommend([]);
      final second = await service.recommend([]);
      expect(first.map((r) => r.id).toSet(), hasLength(3));
      expect([...first, ...second].map((r) => r.id).toSet(), hasLength(6));
      expect(first.any((r) => r.id == recipe['id']), isFalse);
    },
  );
  test(
    'every explicitly selected ingredient must be required in the result',
    () async {
      final service = serviceFor([recipe]);
      addTearDown(service.dispose);
      final inventory = [
        InventoryBatch(id: 'tofu', name: '두부', quantity: 200, unit: 'g'),
        InventoryBatch(id: 'carrot', name: '당근', quantity: 1, unit: '개'),
      ];
      await expectLater(
        service.recommend(inventory, selectedBatchIds: {'tofu', 'carrot'}),
        throwsFormatException,
      );
      expect(
        await service.recommend(inventory, selectedBatchIds: {'tofu'}),
        hasLength(1),
      );
    },
  );
  test('optional use alone does not satisfy an explicit selection', () async {
    final service = serviceFor([recipe]);
    addTearDown(service.dispose);
    await expectLater(
      service.recommend(
        [InventoryBatch(id: 'water', name: '물', quantity: 1000, unit: 'ml')],
        selectedBatchIds: {'water'},
      ),
      throwsFormatException,
    );
  });
  test('one-off ingredient exclusions reject model output without changing allergies', () async {
    final service = serviceFor([recipe]);
    addTearDown(service.dispose);
    await expectLater(
      service.recommend([], excludedIngredients: [' 두 부 ']),
      throwsFormatException,
    );
    expect(await service.recommend([]), hasLength(1));
  });
  test(
    'equipment is transmitted and direct intake candidates are supported',
    () async {
      var calls = 0;
      final service = AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            expect(jsonDecode(request.body)['text'], contains('전자레인지, 오븐 없음'));
            return http.Response('{"recipes":[]}', 200);
          }
          return http.Response('{"candidates":[]}', 200);
        }),
      );
      addTearDown(service.dispose);
      await service.recommend([], equipment: '전자레인지, 오븐 없음');
      expect(await service.requestStructured('test'), {'candidates': []});
    },
  );
}
