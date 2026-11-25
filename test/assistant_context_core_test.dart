import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/models/assistant_command.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/assistant_service.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';

class ContextStore extends InventoryStore {
  @override
  bool get isDemo => false;
  @override
  List<InventoryBatch> get activeBatches => batches;
  @override
  List<InventoryBatch> get batches => rows;
  final List<InventoryBatch> rows = [
    InventoryBatch(id: 'cold', name: '두부', quantity: 300, unit: 'g'),
    InventoryBatch(
      id: 'frozen',
      name: '두부',
      quantity: 500,
      unit: 'g',
      storageType: StorageType.freezer,
    ),
  ];
}

void main() {
  late ContextStore store;
  late AssistantService service;
  setUp(() {
    store = ContextStore();
    service = AssistantService(
      store: store,
      memory: AssistantMemory(),
      ai: AiService(baseUrl: ''),
    );
  });
  tearDown(() {
    service.dispose();
    store.dispose();
  });

  test(
    'AI omitted selection is grounded in explicit named inventory only',
    () async {
      store.rows.add(
        InventoryBatch(id: 'egg', name: '달걀', quantity: 2, unit: '개'),
      );
      final remote = AssistantService(
        store: store,
        memory: AssistantMemory(),
        ai: AiService(
          baseUrl: 'https://example.invalid',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'command': {
                  'intent': 'recommend',
                  'servings': 2,
                  'equipment': '전자레인지',
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        ),
      );
      final command = await remote.interpret('두부랑 계란으로 2인분 추천해줘', useAi: true);
      expect(command.batchIds, ['cold', 'frozen', 'egg']);
      expect(command.suppliedFields, contains('batchIds'));
      expect(command.servings, 2);
      expect(command.equipment, '전자레인지');
      remote.dispose();
    },
  );

  test(
    'negative ingredient mentions never become required selections',
    () async {
      final remote = AssistantService(
        store: store,
        memory: AssistantMemory(),
        ai: AiService(
          baseUrl: 'https://example.invalid',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'command': {'intent': 'recommend'},
              }),
              200,
            ),
          ),
        ),
      );
      for (final input in ['두부 없이 추천', '두부는 빼고 추천', '두부 말고 추천', '두부 제외 추천']) {
        final command = await remote.interpret(input, useAi: true);
        expect(command.batchIds, isEmpty, reason: input);
      }
      remote.dispose();
    },
  );

  test('explicit empty AI selection is not broadened by mentions', () async {
    final remote = AssistantService(
      store: store,
      memory: AssistantMemory(),
      ai: AiService(
        baseUrl: 'https://example.invalid',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'command': {'intent': 'recommend', 'batchIds': []},
            }),
            200,
          ),
        ),
      ),
    );
    final command = await remote.interpret('두부로 추천', useAi: true);
    expect(command.batchIds, isEmpty);
    remote.dispose();
  });

  test(
    'reset invalidates an unapproved create action in the same mode',
    () async {
      final proposal = service.prepare(
        const AssistantCommand(
          intent: AssistantIntent.create,
          item: '우유',
          quantity: 1,
          unit: '팩',
        ),
        '우유 1팩 추가',
      );
      service.memory.clear();
      await expectLater(
        service.execute(proposal, approved: true),
        throwsStateError,
      );
    },
  );

  test('short correction replaces pending amount without executing', () async {
    service.prepare(
      const AssistantCommand(
        intent: AssistantIntent.consume,
        item: '두부',
        batchId: 'cold',
        quantity: 100,
        unit: 'g',
      ),
      '두부 100g 사용',
    );
    final correction = await service.interpret('아니, 50g', useAi: true);
    expect(correction.intent, AssistantIntent.consume);
    expect(correction.quantity, 50);
    expect(service.prepare(correction, '아니, 50g').after!.quantity, 250);
    expect(store.batches.first.quantity, 300);
  });

  test(
    'quantity reply keeps action and avoids remote interpretation',
    () async {
      service.prepare(
        const AssistantCommand(
          intent: AssistantIntent.consume,
          item: '두부',
          batchId: 'cold',
        ),
        '두부 사용',
      );
      final reply = await service.interpret('100g', useAi: true);
      expect(reply.intent, AssistantIntent.consume);
      expect(reply.batchId, 'cold');
      expect(service.prepare(reply, '100g').after!.quantity, 200);
      expect(store.batches.first.quantity, 300);
    },
  );

  test(
    'storage clarification selects duplicate batch without losing amount',
    () async {
      service.prepare(
        const AssistantCommand(
          intent: AssistantIntent.consume,
          item: '두부',
          quantity: 100,
          unit: 'g',
        ),
        '두부 100g 사용',
      );
      final reply = await service.interpret('냉동에 있는 거', useAi: true);
      expect(reply.batchId, 'frozen');
      expect(reply.quantity, 100);
      expect(service.prepare(reply, '냉동에 있는 거').after!.quantity, 400);
    },
  );

  test('numbered clarification follows displayed candidate order', () async {
    service.prepare(
      const AssistantCommand(
        intent: AssistantIntent.consume,
        item: '두부',
        quantity: 100,
        unit: 'g',
      ),
      '두부 100g 사용',
    );
    final reply = await service.interpret('두 번째 거', useAi: true);
    expect(reply.batchId, 'frozen');
  });

  test('brief recipe refinement preserves remaining constraints', () async {
    service.memory.recommendation = const AssistantCommand(
      intent: AssistantIntent.recommend,
      servings: 2,
      maxMinutes: 20,
      equipment: '전자레인지',
      excludedIngredients: ['땅콩'],
    );
    final reply = await service.interpret('맵지 않게', useAi: false);
    final conditions = service.recommendationConditions(reply);
    expect(conditions.servings, 2);
    expect(conditions.maxMinutes, 20);
    expect(conditions.equipment, '전자레인지');
    expect(conditions.excludedIngredients, ['땅콩']);
    expect(conditions.preferences, contains('맵지'));
  });

  test('vague consumption retains action without inventing amount', () async {
    final command = await service.interpret('두부 조금 썼어', useAi: false);
    expect(command.intent, AssistantIntent.consume);
    expect(command.item, '두부');
    expect(command.quantity, isNull);
  });
}
