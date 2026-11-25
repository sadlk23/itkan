import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/models/assistant_command.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/assistant_service.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late InventoryStore store;
  late AssistantService service;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('assistant_test_');
    store = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: '${dir.path}/test.db',
    );
    await store.initialize();
    service = AssistantService(
      store: store,
      ai: AiService(baseUrl: ''),
      memory: AssistantMemory(),
    );
  });
  tearDown(() async {
    service.dispose();
    await store.close();
    store.dispose();
    await dir.delete(recursive: true);
  });
  test('local cooking start distinguishes selection and numbered start', () {
    expect(
      AssistantService.parseLocal('요리 시작').intent,
      AssistantIntent.cookingStart,
    );
    expect(
      AssistantService.parseLocal('조리 시작해줘').intent,
      AssistantIntent.cookingStart,
    );
    final numbered = AssistantService.parseLocal('2번 요리 시작');
    expect(numbered.intent, AssistantIntent.cookingStart);
    expect(numbered.recipeIndex, 2);
    expect(
      AssistantService.parseLocal('2번 선택').intent,
      AssistantIntent.selectRecipe,
    );
  });
  test('local pronoun recommendation keeps the selected batch among duplicate names', () async {
    final first = store.activeBatches.first;
    await store.add(first.copyWith(id: 'same-name-other-batch'));
    service.selectBatch(first.id);
    final command = await service.interpret('그걸로 추천해줘', useAi: false);
    expect(service.recommendationConditions(command).batchIds, [first.id]);
  });
  test('cooking start saves snapshot without deduction and requires matching replacement confirmation', () async {
    final recipe = AiService.demoRecipes.first;
    await service.startCooking(recipe);
    final first = store.cookingSession!;
    expect(first['step'], 0);
    expect(first['status'], 'cooking');
    expect(first['usageApplied'], false);
    expect((first['recipe'] as Map)['title'], recipe.title);
    expect(store.history, isEmpty);
    await expectLater(service.startCooking(recipe), throwsStateError);
    await expectLater(
      service.startCooking(recipe, replacingSessionId: 'stale-id'),
      throwsStateError,
    );
    expect(store.cookingSession!['id'], first['id']);
    await service.startCooking(
      recipe,
      replacingSessionId: first['id'] as String,
    );
    expect(store.cookingSession!['id'], isNot(first['id']));
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
    expect(store.history, isEmpty);
  });

  test('rejects unknown fields, intents, negative and infinite quantities', () {
    for (final data in [
      {'intent': 'deleteAll'},
      {'intent': 'create', 'sql': 'DROP TABLE batches'},
      {'intent': 'create', 'quantity': -1},
      {'intent': 'create', 'quantity': double.infinity},
    ]) {
      expect(() => AssistantCommand.fromJson(data), throwsFormatException);
    }
  });
  test('preview and cancelled approval never mutate quantity', () async {
    final c = await service.interpret('두부 100g 사용', useAi: false);
    final p = service.prepare(c, '두부 100g 사용');
    expect(p.before!.quantity, 300);
    expect(p.after!.quantity, 200);
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
    await expectLater(service.execute(p, approved: false), throwsStateError);
    expect(store.history, isEmpty);
  });
  test(
    'approved repeated action applies exactly once and undo restores',
    () async {
      final p = service.prepare(
        AssistantService.parseLocal('두부 100g 사용'),
        '두부 100g 사용',
      );
      await service.execute(p, approved: true);
      await service.execute(p, approved: true);
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 200);
      expect(store.history.length, 1);
      await store.undo(store.history.first.id);
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
    },
  );
  test('out of bounds and unsupported conversion do not produce executable proposals', () {
    final excessive = service.prepare(
      AssistantService.parseLocal('두부 999g 사용'),
      '',
    );
    final crossDimension = service.prepare(
      AssistantService.parseLocal('두부 1개 사용'),
      '',
    );
    expect(excessive.canExecute, false);
    expect(crossDimension.canExecute, false);
    expect(store.history, isEmpty);
  });
  test(
    'ambiguous batch requires choice and snapshot rejects intervening mutation',
    () async {
      await store.add(
        InventoryBatch(id: 'other-tofu', name: '두부', quantity: 200, unit: 'g'),
      );
      final c = AssistantService.parseLocal('두부 100g 사용');
      final ambiguous = service.prepare(c, '');
      expect(ambiguous.candidates.length, 2);
      expect(ambiguous.canExecute, false);
      final chosen = service.prepare(c.withTarget('tofu'), '');
      await store.consume('tofu', 10);
      await expectLater(
        service.execute(chosen, approved: true),
        throwsStateError,
      );
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 290);
    },
  );
  test('followup remembers item and missing quantity but unknown pronoun clarifies', () async {
    expect(
      AssistantService.parseLocal(
        '그거 100g 사용',
        memory: AssistantMemory(),
      ).intent,
      AssistantIntent.clarify,
    );
    service.search(
      const AssistantCommand(intent: AssistantIntent.search, item: '두부'),
    );
    final c = await service.interpret('그거 사용', useAi: false);
    final p = service.prepare(c, '그거 사용');
    expect(p.canExecute, false);
    final clarified = await service.interpret('100g', useAi: false);
    expect(clarified.item, '두부');
    expect(clarified.quantity, 100);
    expect(service.prepare(clarified, '100g').canExecute, true);
  });
  test('local volume synonyms parse without corrupting milliliter', () {
    expect(AssistantService.parseLocal('우유 100밀리리터 추가').unit, 'ml');
    expect(AssistantService.parseLocal('우유 1리터 추가').unit, 'L');
    expect(
      AssistantService.parseLocal('우유 하나 있어').intent,
      AssistantIntent.clarify,
    );
  });
  test('AI interpretation only proposes and never writes inventory', () async {
    final remote = AssistantService(
      store: store,
      memory: AssistantMemory(),
      ai: AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'command': {
                'intent': 'consume',
                'item': '두부',
                'quantity': 50,
                'unit': 'g',
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
    );
    final c = await remote.interpret('두부 조금 썼어', useAi: true);
    expect(c.intent, AssistantIntent.consume);
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 300);
    expect(store.history, isEmpty);
    remote.dispose();
  });
  test('changing sample mode invalidates an old approval', () async {
    final p = service.prepare(AssistantService.parseLocal('우유 1팩 추가'), '');
    await store.setDemoMode(false);
    await expectLater(service.execute(p, approved: true), throwsStateError);
    expect(store.batches, isEmpty);
  });
  test(
    'recommendation keeps multiple ingredients, preferences and equipment',
    () {
      final ids = store.activeBatches.take(2).map((b) => b.id).toList();
      final command = AssistantCommand.fromJson({
        'intent': 'recommend',
        'batchIds': ids,
        'preferences': '맵지 않게',
        'equipment': '전자레인지',
        'servings': 2,
        'maxMinutes': 20,
      });
      final result = service.recommendationConditions(command);
      expect(result.batchIds, ids);
      expect(result.preferences, '맵지 않게');
      expect(result.equipment, '전자레인지');
      service.memory.recommendation = result;
      final changed = service.recommendationConditions(
        AssistantCommand.fromJson({
          'intent': 'recommend',
          'refineRecommendation': true,
          'maxMinutes': 15,
        }),
      );
      expect(changed.batchIds, ids);
      expect(changed.preferences, '맵지 않게');
      expect(changed.equipment, '전자레인지');
      expect(changed.servings, 2);
      expect(changed.maxMinutes, 15);
      final reset = service.recommendationConditions(
        AssistantCommand.fromJson({
          'intent': 'recommend',
          'refineRecommendation': true,
          'batchIds': <String>[],
          'preferences': '',
          'equipment': '',
          'servings': 1,
        }),
      );
      expect(reset.batchIds, isEmpty);
      expect(reset.preferences, isEmpty);
      expect(reset.equipment, isEmpty);
      expect(reset.servings, 1);
      expect(reset.maxMinutes, 20);
    },
  );
  test('new recommendations use saved defaults and reject stale batch ids', () {
    final result = service.recommendationConditions(
      const AssistantCommand(intent: AssistantIntent.recommend),
      defaultPreferences: '채식',
      defaultEquipment: '인덕션',
    );
    expect(result.preferences, '채식');
    expect(result.equipment, '인덕션');
    expect(
      () => service.recommendationConditions(
        AssistantCommand.fromJson({
          'intent': 'recommend',
          'batchIds': ['missing'],
        }),
      ),
      throwsStateError,
    );
    for (final invalid in [
      true,
      [''],
      [3],
    ]) {
      expect(
        () => AssistantCommand.fromJson({
          'intent': 'recommend',
          'batchIds': invalid,
        }),
        throwsFormatException,
      );
    }
  });
  test(
    'local time refinement does not reset previous recipe conditions',
    () async {
      service.memory.recommendation = AssistantCommand(
        intent: AssistantIntent.recommend,
        batchIds: [store.activeBatches.first.id],
        preferences: '맵지 않게',
        equipment: '전자레인지',
        servings: 2,
        maxMinutes: 30,
      );
      final interpreted = await service.interpret(
        '시간만 15분으로 바꿔줘',
        useAi: false,
      );
      final result = service.recommendationConditions(interpreted);
      expect(result.maxMinutes, 15);
      expect(result.servings, 2);
      expect(result.preferences, '맵지 않게');
      expect(result.equipment, '전자레인지');
      expect(result.batchIds, [store.activeBatches.first.id]);
    },
  );
  test(
    'inventory context includes more than 100 batches and unknown quantity',
    () async {
      await store.addMany(
        List.generate(
          105,
          (i) => InventoryBatch(
            id: 'context-$i',
            name: '재료$i',
            quantity: 1,
            unit: '개',
            quantityMode: i == 104
                ? QuantityMode.status
                : QuantityMode.measured,
            stockLevel: StockLevel.low,
            expiryDate: DateTime(2027, 1, 1),
            expiryStatus: ExpiryStatus.estimated,
          ),
        ),
      );
      final context = service.inventoryContext();
      expect(context.length, greaterThan(100));
      final last = context.singleWhere((b) => b['id'] == 'context-104');
      expect(last['quantity'], isNull);
      expect(last['stockLevel'], 'low');
      expect(last['expiryStatus'], 'estimated');
      expect(last['expiryDate'], startsWith('2027-01-01'));
      expect(last['createdAt'], isNotEmpty);
    },
  );
  test('coach request includes allergies stock equipment and recipe step without writes', () async {
    String? prompt;
    final remote = AssistantService(
      store: store,
      memory: AssistantMemory(),
      ai: AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient((request) async {
          prompt = (jsonDecode(request.body) as Map)['text'] as String;
          return http.Response(
            jsonEncode({'reply': '성분 표시를 확인해주세요.'}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    await remote.coach(
      '대신 뭘 넣어?',
      AiService.demoRecipes.first,
      1,
      allergies: ['땅콩'],
      preferences: '맵지 않게',
      equipment: '전자레인지',
    );
    expect(prompt, contains('현재 단계: 2'));
    expect(prompt, contains('땅콩'));
    expect(prompt, contains('전자레인지'));
    expect(prompt, contains(store.activeBatches.first.id));
    expect(store.history, isEmpty);
    remote.dispose();
  });
  test(
    'multi intake routes only registration requests to candidate review',
    () {
      expect(AssistantService.isMultiItemIntake('두부 1팩, 우유 2팩 등록'), isTrue);
      expect(AssistantService.isMultiItemIntake('두부 1팩 사용, 우유 2팩 사용'), isFalse);
      expect(AssistantService.isMultiItemIntake('우유 1팩 추가'), isFalse);
    },
  );
  test(
    'one-time exclusions survive refinement and allow explicit clearing',
    () async {
      final initial = await service.interpret('우유 없이 2인분 추천', useAi: false);
      service.memory.recommendation = service.recommendationConditions(initial);
      expect(service.memory.recommendation!.excludedIngredients, ['우유']);
      final refined = service.recommendationConditions(
        AssistantCommand.fromJson({
          'intent': 'recommend',
          'refineRecommendation': true,
          'maxMinutes': 10,
        }),
      );
      expect(refined.excludedIngredients, ['우유']);
      final reset = service.recommendationConditions(
        AssistantCommand.fromJson({
          'intent': 'recommend',
          'refineRecommendation': true,
          'excludedIngredients': [],
        }),
      );
      expect(reset.excludedIngredients, isEmpty);
      expect(
        () => AssistantCommand.fromJson({
          'intent': 'recommend',
          'excludedIngredients': [3],
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'late interpretation is rejected after mode change without remembering it',
    () async {
      final gate = Completer<http.Response>();
      final memory = AssistantMemory();
      final remote = AssistantService(
        store: store,
        memory: memory,
        ai: AiService(
          baseUrl: 'https://example.invalid/ai',
          client: MockClient((_) => gate.future),
        ),
      );
      final pending = remote.interpret('우유를 장보기에', useAi: true);
      final rejected = expectLater(pending, throwsStateError);
      await store.setDemoMode(false);
      gate.complete(
        http.Response(
          jsonEncode({
            'command': {'intent': 'shopping', 'item': '우유'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await rejected;
      expect(memory.turns, isEmpty);
      expect(store.history, isEmpty);
      remote.dispose();
    },
  );
}
