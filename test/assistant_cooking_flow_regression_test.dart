import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/models/assistant_command.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/screens/assistant_screen.dart';
import 'package:my_fridge/screens/recipe_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/assistant_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store extends InventoryStore {
  _Store(this.rows, [this.session]);
  final List<InventoryBatch> rows;
  Map<String, dynamic>? session;
  Map<String, double>? applied;

  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches =>
      rows.where((b) => b.active).toList();
  @override
  Map<String, dynamic>? get cookingSession => session;
  @override
  Future<void> saveCookingSessionIfCurrent(
    Map<String, dynamic> next, {
    required String? expectedSessionId,
  }) async {
    if (expectedSessionId != session?['id']) throw StateError('조리가 교체됨');
    session = Map.of(next);
    notifyListeners();
  }

  @override
  Future<void> applyCookingUsage(
    String sessionId,
    Map<String, double> usage, {
    Map<String, int>? expectedRevisions,
  }) async {
    if (session?['id'] != sessionId) throw StateError('조리가 교체됨');
    applied = Map.of(usage);
    session = {...session!, 'status': 'completed', 'usageApplied': true};
    notifyListeners();
  }
}

Map<String, dynamic> _session(Recipe recipe, String status) => {
  'id': 'session-${recipe.id}',
  'recipeId': recipe.id,
  'recipe': recipe.toJson(),
  'step': 0,
  'status': status,
  'usageApplied': false,
};

http.Response _response(Map<String, dynamic> json) => http.Response(
  jsonEncode(json),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _open(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(900, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugin.csdcorp.com/speech_to_text'),
      (_) async => true,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => 1,
    );
    AssistantMemory.instance.clear();
  });

  test(
    'egg aliases work both ways and multiple matching batches require a choice',
    () async {
      for (final (stored, spoken) in [('계란', '달걀'), ('달걀', '계란')]) {
        final rows = [
          InventoryBatch(id: 'one', name: stored, quantity: 3, unit: '개'),
        ];
        final store = _Store(rows);
        final service = AssistantService(
          store: store,
          memory: AssistantMemory(),
        );
        addTearDown(store.dispose);
        addTearDown(service.dispose);
        for (final name in [stored, spoken]) {
          final lookup = await service.interpret('$name 있어?', useAi: false);
          expect(service.search(lookup).single.name, stored);
          final command = await service.interpret('$name 1개 사용', useAi: false);
          expect(service.prepare(command, '').after!.quantity, 2);
        }
        rows.add(
          InventoryBatch(
            id: 'two',
            name: spoken,
            quantity: 2,
            unit: '개',
            storageType: StorageType.freezer,
          ),
        );
        final proposal = service.prepare(
          AssistantService.parseLocal('$spoken 1개 사용'),
          '',
        );
        expect(proposal.candidates.map((b) => b.id), ['one', 'two']);
        expect(proposal.canExecute, isFalse);
        final reply = await service.interpret('냉동에 있는 거', useAi: false);
        expect(service.prepare(reply, '').before!.id, 'two');
      }
    },
  );

  test('AI selecting one of several unspecified aliases still requires confirmation', () async {
    final store = _Store([
      InventoryBatch(id: 'a', name: '계란', quantity: 2, unit: '개'),
      InventoryBatch(
        id: 'b',
        name: '달걀',
        quantity: 2,
        unit: '개',
        storageType: StorageType.freezer,
      ),
    ]);
    final service = AssistantService(
      store: store,
      memory: AssistantMemory(),
      ai: AiService(
        baseUrl: 'https://example.invalid',
        client: MockClient(
          (_) async => _response({
            'command': {
              'intent': 'consume',
              'item': '계란',
              'quantity': 1,
              'unit': '개',
              'batchId': 'a',
              'storage': 'fridge',
            },
          }),
        ),
      ),
    );
    addTearDown(store.dispose);
    addTearDown(service.dispose);
    final proposal = service.prepare(
      await service.interpret('계란 1개 사용', useAi: true),
      '',
    );
    expect(proposal.candidates.map((b) => b.id), ['a', 'b']);
    expect(proposal.canExecute, isFalse);
  });

  test('registration uses the preferred storage and preserves explicit locations and names', () async {
    SharedPreferences.setMockInitialValues({'default_storage': 'freezer'});
    final store = _Store([]);
    final service = AssistantService(store: store, memory: AssistantMemory());
    addTearDown(store.dispose);
    addTearDown(service.dispose);
    for (final (text, expected) in [
      ('계란 2개 추가', StorageType.freezer),
      ('계란 2개 실온에 추가', StorageType.pantry),
      ('계란 2개 냉장고에 추가', StorageType.fridge),
    ]) {
      final command = await service.interpret(text, useAi: false);
      final batch = service.prepare(command, text).after!;
      expect(batch.name, '계란');
      expect(batch.storageType, expected);
    }
  });

  test(
    'new item uses the default location when AI guesses a different storage',
    () async {
      SharedPreferences.setMockInitialValues({'default_storage': 'pantry'});
      final store = _Store([]);
      final service = AssistantService(
        store: store,
        memory: AssistantMemory(),
        ai: AiService(
          baseUrl: 'https://example.invalid',
          client: MockClient(
            (_) async => _response({
              'command': {
                'intent': 'create',
                'item': '양파',
                'quantity': 1,
                'unit': '개',
                'storage': 'fridge',
              },
            }),
          ),
        ),
      );
      addTearDown(store.dispose);
      addTearDown(service.dispose);
      final command = await service.interpret('양파 1개 추가', useAi: true);
      expect(
        service.prepare(command, '').after!.storageType,
        StorageType.pantry,
      );
    },
  );

  test('500-batch interpretation, cooking answers and recommendations fit the relay budget', () async {
    final store = _Store([
      for (var i = 0; i < 499; i++)
        InventoryBatch(
          id: 'unrelated-$i',
          name: '별도 재료 $i',
          quantity: 10,
          unit: 'g',
          expiryDate: DateTime.now().add(const Duration(days: 3)),
          expiryStatus: ExpiryStatus.actual,
        ),
      InventoryBatch(id: 'target-499', name: '두부', quantity: 3, unit: '개'),
    ]);
    var call = 0;
    final ai = AiService(
      baseUrl: 'https://example.invalid',
      client: MockClient((request) async {
        final prompt = jsonDecode(request.body)['text'] as String;
        expect(request.bodyBytes.length, lessThanOrEqualTo(128 * 1024));
        switch (call++) {
          case 0:
            expect(prompt, contains('target-499'));
            expect(prompt, isNot(contains('unrelated-')));
            expect(prompt, isNot(contains('"revision"')));
            expect(prompt, isNot(contains('"createdAt"')));
            expect(prompt, isNot(contains('private-turn-marker')));
            return _response({
              'command': {'intent': 'search', 'item': '두부'},
            });
          case 1:
            final inventory = jsonDecode(
              prompt.split('보유 재고: ').last.split('\n').first,
            ) as Map;
            final rows = inventory['rows'] as List;
            expect(rows.map((row) => row['id']), ['target-499']);
            expect(prompt, isNot(contains('private-turn-marker')));
            return _response({'reply': '두부가 있어요.'});
          default:
            expect(prompt, contains('별도 재료 498'));
            expect(prompt, contains('두부'));
            return _response({'recipes': []});
        }
      }),
    );
    final service = AssistantService(
      store: store,
      memory: AssistantMemory(),
      ai: ai,
    );
    addTearDown(store.dispose);
    addTearDown(service.dispose);
    for (var i = 0; i < 24; i++) {
      service.memory.remember('user', 'private-turn-marker ${'질문' * 700}');
    }
    final command = await service.interpret('두부 있어?', useAi: true);
    expect(service.search(command).single.id, 'target-499');
    await service.converse('두부 얼마나 있어?');
    await ai.recommend(store.activeBatches);
    expect(call, 3);
  });

  test('large selected purchase IDs retain the full quantity when grouped for recommendation', () async {
    final batches = [
      for (var i = 0; i < 500; i++)
        InventoryBatch(
          id: '${'purchase' * 48}-$i',
          name: '양파',
          quantity: 2,
          unit: '개',
        ),
    ];
    final ai = AiService(
      baseUrl: 'https://example.invalid',
      client: MockClient((request) async {
        final prompt = jsonDecode(request.body)['text'] as String;
        expect(request.bodyBytes.length, lessThan(128 * 1024));
        final rows =
            jsonDecode(prompt.split('재고: ').last.split('\n').first) as List;
        expect(rows, [
          {'name': '양파', 'quantity': 1000.0, 'unit': '개'},
        ]);
        expect(prompt, isNot(contains('purchasepurchase')));
        return _response({'recipes': []});
      }),
    );
    addTearDown(ai.dispose);
    await ai.recommend(
      batches,
      selectedBatchIds: batches.map((b) => b.id).toSet(),
    );
  });

  test(
    'oversized proxy request is rejected before contacting the provider',
    () async {
      var contacted = false;
      final ai = AiService(
        baseUrl: 'https://example.invalid',
        client: MockClient((_) async {
          contacted = true;
          return _response({});
        }),
      );
      addTearDown(ai.dispose);
      await expectLater(ai.requestStructured('한' * 50000), throwsStateError);
      expect(contacted, isFalse);
    },
  );

  testWidgets(
    'turning off AI survives reopening the assistant and reloading the preferences cache',
    (tester) async {
      final store = _Store([
        InventoryBatch(id: 'broccoli', name: '브로콜리', quantity: 3, unit: '개'),
      ]);
      addTearDown(store.dispose);
      var requests = 0;
      await _open(
        tester,
        Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                ctx,
                MaterialPageRoute<void>(
                  builder: (_) => AssistantScreen(
                    store: store,
                    aiService: AiService(
                      baseUrl: 'https://example.invalid',
                      client: MockClient((_) async {
                        requests++;
                        return _response({
                          'command': {'intent': 'search', 'item': '브로콜리'},
                        });
                      }),
                    ),
                  ),
                ),
              ),
              child: const Text('대화 열기'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('대화 열기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('대화 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI로 대화 이해'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('assistant_ai_interpretation_enabled'), isFalse);
      await prefs.reload();
      AssistantMemory.instance.clear();
      await tester.tap(find.text('대화 열기'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '브로콜리 있어?');
      await tester.tap(find.byTooltip('명령 보내기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('브로콜리'), findsWidgets);
      expect(requests, 0);
      await tester.tap(find.byTooltip('대화 설정'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'AI로 대화 이해'),
            )
            .value,
        isFalse,
      );
    },
  );

  testWidgets(
    'fresh batches get fractional kg and L allocations while elapsed selected batches default to zero',
    (tester) async {
      final recipe = Recipe(
        id: 'small-portions',
        title: '국',
        source: 'test',
        servings: 1,
        minutes: 3,
        ingredients: const [
          RecipeIngredient(name: '소금', quantity: 3, unit: 'g'),
          RecipeIngredient(name: '간장', quantity: 0.125, unit: 'ml'),
        ],
        preferredBatchIds: const ['old'],
        steps: const ['섞기'],
        generatedAt: DateTime(2026),
      );
      final store = _Store([
        InventoryBatch(
          id: 'old',
          name: '소금',
          quantity: 1,
          unit: 'kg',
          expiryStatus: ExpiryStatus.actual,
          expiryDate: DateTime.now().subtract(const Duration(days: 2)),
        ),
        InventoryBatch(id: 'fresh', name: '소금', quantity: 1, unit: 'kg'),
        InventoryBatch(id: 'soy', name: '간장', quantity: 1, unit: 'L'),
      ], _session(recipe, 'awaitingUsage'));
      addTearDown(store.dispose);
      await _open(
        tester,
        RecipeScreen(recipe: recipe, store: store, autoResume: true),
      );
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((field) => field.controller!.text),
        ['0.003', '0', '0.000125'],
      );
      expect(find.textContaining('기본 사용량은 0'), findsOneWidget);
      await tester.ensureVisible(find.text('확인하고 재고에 반영'));
      await tester.tap(find.text('확인하고 재고에 반영'));
      await tester.pumpAndSettle();
      expect(store.applied, {'fresh': 0.003, 'soy': 0.000125});
    },
  );

  testWidgets(
    'returning from the assistant follows the replacement session, including its next step',
    (tester) async {
      final original = AiService.demoRecipes.single;
      final next = Recipe.fromJson({
        ...original.toJson(),
        'id': 'next-recipe',
        'title': '새 메뉴',
      });
      final store = _Store([]);
      addTearDown(store.dispose);
      AssistantMemory.instance.syncMode(store.isDemo);
      AssistantService.lastRecipes = [original, next];
      await _open(tester, RecipeScreen(recipe: original, store: store));
      await tester.tap(find.text('요리 시작하기'));
      await tester.pumpAndSettle();
      final initialId = store.session!['id'];
      await tester.tap(find.byTooltip('음성 명령 · 요리 코치'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '2번 요리 시작');
      await tester.tap(find.byTooltip('명령 보내기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('종료하고 시작'));
      await tester.pumpAndSettle();
      final replacementId = store.session!['id'];
      expect(replacementId, isNot(initialId));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('새 메뉴'), findsWidgets);
      await tester.ensureVisible(find.text('다음 단계'));
      await tester.tap(find.text('다음 단계'));
      await tester.pumpAndSettle();
      expect(store.session!['recipeId'], next.id);
      expect(store.session!['id'], replacementId);
      expect(store.session!['step'], 1);
    },
  );
}
