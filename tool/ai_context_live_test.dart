import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:my_fridge/models/assistant_command.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/assistant_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ActualHttp extends HttpOverrides {}

class _BudgetClient extends http.BaseClient {
  _BudgetClient(this.inner);
  final http.Client inner;
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (requests >= 7) throw StateError('Live request budget exhausted.');
    requests++;
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live synthetic contextual conversation through key-free local proxy',
    () async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      final store = InventoryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      await store.initialize();
      await store.setDemoMode(false);
      await store.addMany([
        InventoryBatch(
          id: 'synthetic-tofu',
          name: '두부',
          quantity: 300,
          unit: 'g',
        ),
        InventoryBatch(id: 'synthetic-egg', name: '달걀', quantity: 4, unit: '개'),
      ], source: 'synthetic_fixture');
      final memory = AssistantMemory();
      // Read only the ignored development-client config, never provider secrets.
      final localConfig = jsonDecode(
        await File('config/ai.emulator.json').readAsString(),
      ) as Map;
      final proxyToken = localConfig['AI_PROXY_TOKEN'];
      if (proxyToken is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(proxyToken)) {
        fail('Local client configuration is not prepared.');
      }
      final client = _BudgetClient(
        IOClient(_ActualHttp().createHttpClient(null)),
      );
      final assistant = AssistantService(
        store: store,
        memory: memory,
        ai: AiService(
          baseUrl: 'http://127.0.0.1:8787/ai',
          format: 'proxy',
          apiKey: '',
          proxyToken: proxyToken,
          client: client,
        ),
      );
      final before = jsonEncode(store.batches.map((b) => b.toJson()).toList());
      final historyBefore = store.history.length;
      final cases = <Map<String, dynamic>>[];
      Future<void> scenario(
        String name,
        Future<Map<String, dynamic>> Function() run,
      ) async {
        final timer = Stopwatch()..start();
        try {
          final result = await run();
          final predicates = result['predicates'] as Map<String, bool>;
          cases.add({
            'scenario': name,
            'passed': predicates.values.every((value) => value),
            'elapsedMs': timer.elapsedMilliseconds,
            ...result,
          });
        } catch (_) {
          // Never record exception messages, transport bodies or headers.
          cases.add({
            'scenario': name,
            'passed': false,
            'elapsedMs': timer.elapsedMilliseconds,
            'failure':
                'Request or application validation failed; raw error omitted.',
          });
        }
      }

      try {
        await scenario('search_establishes_reference', () async {
          final command = await assistant.interpret('두부 있어?', useAi: true);
          final found = command.intent == AssistantIntent.search
              ? assistant.search(command)
              : <InventoryBatch>[];
          memory.remember('assistant', '두부 300g이 냉장실에 있어요.');
          return {
            'command': command.toJson(),
            'predicates': {
              'searchIntent': command.intent == AssistantIntent.search,
              'correctTarget':
                  found.length == 1 && found.single.id == 'synthetic-tofu',
              'referenceRemembered': memory.lastBatchId == 'synthetic-tofu',
            },
          };
        });
        await scenario('ambiguous_amount_asks_without_guessing', () async {
          final command = await assistant.interpret('그거 조금 썼어', useAi: true);
          final draft = assistant.prepare(command, '그거 조금 썼어');
          memory.remember('assistant', draft.clarification ?? '수량과 단위를 알려주세요.');
          return {
            'command': command.toJson(),
            'predicates': {
              'noInventedAmount': command.quantity == null,
              'notExecutable': !draft.canExecute,
              'pendingConsume':
                  memory.pending?.intent == AssistantIntent.consume,
            },
          };
        });
        await scenario(
          'short_quantity_reply_preserves_action_and_approval',
          () async {
            final requestsBefore = client.requests;
            final command = await assistant.interpret('100g', useAi: true);
            final draft = assistant.prepare(command, '100g');
            memory.remember(
              'assistant',
              '두부 300g에서 200g으로 바꿀까요? 아직 저장하지 않았어요.',
            );
            return {
              'command': command.toJson(),
              'predicates': {
                'consumePreserved': command.intent == AssistantIntent.consume,
                'correctPreview':
                    draft.after?.quantity == 200 &&
                    draft.before?.id == 'synthetic-tofu',
                'approvalRequired': draft.needsApproval,
                'noExtraHttp': client.requests == requestsBefore,
              },
            };
          },
        );
        await scenario('recommendation_constraints', () async {
          final command = await assistant.interpret(
            '두부와 달걀로 전자레인지만 써서 맵지 않게 15분 안에 먹을 요리 추천해줘',
            useAi: true,
          );
          final condition = assistant.recommendationConditions(command);
          memory.recommendation = condition;
          memory.remember('assistant', '두부와 달걀, 전자레인지, 맵지 않게, 15분 조건으로 찾을게요.');
          return {
            'command': command.toJson(),
            'conditions': condition.toJson(),
            'predicates': {
              'recommendIntent': command.intent == AssistantIntent.recommend,
              'bothIngredients': condition.batchIds.toSet().containsAll([
                'synthetic-tofu',
                'synthetic-egg',
              ]),
              'time': condition.maxMinutes == 15,
              'equipment': condition.equipment.contains('전자레인지'),
              'taste': condition.preferences.contains('맵'),
            },
          };
        });
        await scenario('short_servings_followup_keeps_constraints', () async {
          final command = await assistant.interpret('그럼 2인분으로', useAi: true);
          final condition = assistant.recommendationConditions(command);
          memory.recommendation = condition;
          memory.remember('assistant', '나머지 조건은 그대로 두고 2인분으로 바꿨어요.');
          return {
            'command': command.toJson(),
            'conditions': condition.toJson(),
            'predicates': {
              'recommendIntent': command.intent == AssistantIntent.recommend,
              'servings': condition.servings == 2,
              'ingredientsPreserved': condition.batchIds.toSet().containsAll([
                'synthetic-tofu',
                'synthetic-egg',
              ]),
              'timePreserved': condition.maxMinutes == 15,
              'equipmentPreserved': condition.equipment.contains('전자레인지'),
              'tastePreserved': condition.preferences.contains('맵'),
            },
          };
        });
        await scenario('general_followup_without_recipe', () async {
          memory.remember('user', '그 조건이면 어떤 점을 조심하면 돼?');
          final reply = await assistant.converse(
            '그 조건이면 어떤 점을 조심하면 돼?',
            equipment: '전자레인지',
          );
          return {
            'reply': reply,
            'predicates': {
              'replyPresent': reply.trim().isNotEmpty,
              'noRecipeRequired': memory.selectedRecipe == null,
              'conversationStored': memory.turns.last['text'] == reply,
            },
            'semanticQuality': 'Manual review required; non-empty output alone is not a quality pass.',
          };
        });
      } finally {
        final unchanged =
            before ==
                jsonEncode(store.batches.map((b) => b.toJson()).toList()) &&
            historyBefore == store.history.length &&
            store.cookingSession == null;
        final file = File('docs/evidence/ai-context-live.json');
        await file.parent.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'timestampUtc': DateTime.now().toUtc().toIso8601String(),
            'syntheticDataOnly': true,
            'transport': 'key-free local proxy',
            'maxHttpRequests': 7,
            'actualHttpRequests': client.requests,
            'inventoryUnchanged': unchanged,
            'cases': cases,
            'limitations': 'One run; deterministic continuation may avoid model calls. No culinary safety or population-level quality claim.',
          }),
        );
        assistant.dispose();
        await store.close();
        store.dispose();
        expect(unchanged, isTrue);
      }
      expect(
        cases.every((c) => c['passed'] == true),
        isTrue,
        reason: 'Review sanitized docs/evidence/ai-context-live.json for failed scenarios.',
      );
    },
    skip: !const bool.fromEnvironment('RUN_CONTEXT_LIVE'),
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
