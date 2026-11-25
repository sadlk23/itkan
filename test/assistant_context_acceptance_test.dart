import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/models/assistant_command.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/assistant_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Acceptance tests use synthetic stock and mock HTTP only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late InventoryStore store;
  late AssistantService service;
  final memory = AssistantMemory.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    memory.clear();
    AssistantService.lastRecipes = [];
    store = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await store.initialize();
    service = AssistantService(
      store: store,
      ai: AiService(baseUrl: ''),
    );
  });

  tearDown(() async {
    service.dispose();
    memory.clear();
    AssistantService.lastRecipes = [];
    await store.close();
    store.dispose();
  });

  test(
    'same-mode deletion forgets dialogue, pending intent and recipe results',
    () async {
      await store.setDemoMode(false);
      memory.remember('user', 'SYNTHETIC_PRIVATE_TURN');
      memory.pending = const AssistantCommand(
        intent: AssistantIntent.consume,
        item: '두부',
      );
      memory.recommendation = const AssistantCommand(
        intent: AssistantIntent.recommend,
        preferences: '합성 조건',
      );
      AssistantService.lastRecipes = AiService.demoRecipes;
      await store.clearAll();
      expect(memory.turns, isEmpty);
      expect(memory.pending, isNull);
      expect(memory.recommendation, isNull);
      expect(AssistantService.lastRecipes, isEmpty);
    },
  );

  test(
    'mode transition cannot carry a sample recipe into personal cooking',
    () async {
      AssistantService.lastRecipes = AiService.demoRecipes;
      memory.remember('assistant', '샘플 요리를 추천했어요.');
      await store.setDemoMode(false);
      expect(AssistantService.lastRecipes, isEmpty);
      expect(memory.turns, isEmpty);
      expect(store.cookingSession, isNull);
    },
  );

  test(
    'resetting conversation rejects an already running interpretation',
    () async {
      final gate = Completer<http.Response>();
      final remote = AssistantService(
        store: store,
        ai: AiService(
          baseUrl: 'https://example.invalid/ai',
          client: MockClient((_) => gate.future),
        ),
      );
      addTearDown(remote.dispose);
      final request = remote.interpret('두부로 뭘 만들까?', useAi: true);
      final rejected = expectLater(request, throwsStateError);
      memory.clear();
      gate.complete(
        http.Response(
          jsonEncode({
            'command': {
              'intent': 'recommend',
              'batchIds': ['tofu'],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await rejected;
      expect(memory.turns, isEmpty);
      expect(store.history, isEmpty);
    },
  );

  test(
    'ambiguous stock followup preserves amount but still needs approval',
    () async {
      await store.add(
        InventoryBatch(
          id: 'second-tofu',
          name: '두부',
          quantity: 200,
          unit: 'g',
          storageType: StorageType.freezer,
        ),
      );
      final command = await service.interpret('두부 100g 사용', useAi: false);
      final ambiguous = service.prepare(command, '두부 100g 사용');
      expect(ambiguous.canExecute, isFalse);
      expect(ambiguous.candidates, hasLength(2));
      final selected = service.prepare(
        command.withTarget('second-tofu'),
        '냉동 두부',
      );
      expect(selected.canExecute, isTrue);
      expect(selected.needsApproval, isTrue);
      expect(selected.before!.quantity, 200);
      expect(selected.after!.quantity, 100);
      await expectLater(
        service.execute(selected, approved: false),
        throwsStateError,
      );
      expect(
        store.batches.singleWhere((b) => b.id == 'second-tofu').quantity,
        200,
      );
    },
  );

  test(
    'an unrelated question does not silently perform a pending quantity change',
    () async {
      final initial = await service.interpret('두부 사용', useAi: false);
      expect(service.prepare(initial, '두부 사용').canExecute, isFalse);
      final other = await service.interpret('우유 있어?', useAi: false);
      expect(other.intent, AssistantIntent.search);
      service.search(other);
      expect(store.batches.singleWhere((b) => b.id == 'tofu').quantity, 300);
      expect(store.history, isEmpty);
    },
  );

  test('general kitchen conversation uses previous dialogue and stock without requiring a recipe', () async {
    String? prompt;
    memory.remember('user', '전자레인지만 있고 매운 것은 싫어.');
    memory.remember('assistant', '전자레인지로 만들 수 있는 맵지 않은 음식을 찾을게요.');
    final remote = AssistantService(
      store: store,
      ai: AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient((request) async {
          prompt = (jsonDecode(request.body) as Map)['text'] as String;
          return http.Response(
            jsonEncode({'reply': '보유한 두부로 간단한 찜을 고려할 수 있어요.'}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    addTearDown(remote.dispose);
    final answer = await remote.converse(
      '그럼 지금 있는 걸로 간단히 뭘 먹을까?',
      allergies: ['땅콩'],
      equipment: '전자레인지',
    );
    expect(answer, contains('두부'));
    expect(prompt, contains('매운 것은 싫어'));
    expect(prompt, contains('맵지 않은 음식을 찾을게요'));
    expect(prompt, contains('전자레인지'));
    expect(prompt, contains('땅콩'));
    expect(prompt, contains('tofu'));
    expect(memory.turns.last['text'], answer);
    expect(store.history, isEmpty);
    expect(store.cookingSession, isNull);
  });
}
