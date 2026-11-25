import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:my_fridge/models/assistant_command.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/assistant_service.dart';
import 'package:my_fridge/services/intake_ai_service.dart';
import 'package:my_fridge/services/insight_ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';

class ActualHttpOverrides extends HttpOverrides {}

/// Captures only successful model output text; excludes request/config/headers.
class ModelTextTraceClient extends http.BaseClient {
  ModelTextTraceClient(this.inner);
  final http.Client inner;
  final outputTexts = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    final bytes = await response.stream.toBytes();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final body = jsonDecode(utf8.decode(bytes));
        void readOutput(dynamic value) {
          if (value is Map) {
            if (value['type'] == 'output_text' && value['text'] is String) {
              outputTexts.add(value['text'] as String);
            }
            if (value['output_text'] is String) {
              outputTexts.add(value['output_text'] as String);
            }
            for (final child in value.values) {
              readOutput(child);
            }
          } else if (value is List) {
            for (final child in value) {
              readOutput(child);
            }
          }
        }

        readOutput(body);
      } catch (_) {
        /* No raw bodies, errors or transport metadata retained. */
      }
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      contentLength: bytes.length,
      request: response.request,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
    );
  }

  @override
  void close() => inner.close();
}

/// Records only successfully decoded application payloads, never transport data.
class TracedAiService extends AiService {
  TracedAiService({
    required super.client,
    required super.baseUrl,
    required super.apiKey,
    super.model,
    super.format,
  });
  final decoded = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> requestStructured(String prompt) async {
    final result = await super.requestStructured(prompt);
    decoded.add(result);
    return result;
  }
}

// Explicit opt-in only. Synthetic records, isolated in-memory SQLite, at most
// eight HTTP requests, no real app state and no secret/error-body logging.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live synthetic app AI workflows',
    () async {
      // This opt-in Flutter test lives in tool/ to exclude normal test discovery.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      Map<String, dynamic> config;
      try {
        config = Map<String, dynamic>.from(
          jsonDecode(await File('config/ai.local.json').readAsString()) as Map,
        );
        if ((config['AI_BASE_URL'] as String? ?? '').isEmpty ||
            (config['AI_API_KEY'] as String? ?? '').isEmpty) {
          throw const FormatException();
        }
      } catch (_) {
        fail('Live configuration unavailable; no secret values are logged.');
      }
      final secret = config['AI_API_KEY'] as String;
      final client = ModelTextTraceClient(
        IOClient(ActualHttpOverrides().createHttpClient(null)),
      );
      final ai = TracedAiService(
        client: client,
        baseUrl: config['AI_BASE_URL'] as String,
        apiKey: secret,
        model: config['AI_MODEL'] as String?,
        format: config['AI_API_FORMAT'] as String?,
      );
      sqfliteFfiInit();
      final store = InventoryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      await store.initialize();
      await store.setDemoMode(false);
      await store.addMany([
        InventoryBatch(id: 'live-tofu', name: '두부', quantity: 300, unit: 'g'),
        InventoryBatch(id: 'live-egg', name: '달걀', quantity: 4, unit: '개'),
      ], source: 'synthetic_fixture');
      final assistant = AssistantService(
        store: store,
        ai: ai,
        memory: AssistantMemory(),
      );
      final before = jsonEncode(store.batches.map((b) => b.toJson()).toList());
      final historyBefore = store.history.length;
      final results = <Map<String, Object?>>[];
      Recipe? generated;
      AssistantCommand? initialConditions;
      Future<void> scenario(
        String name,
        Future<Map<String, Object?>> Function() run,
      ) async {
        const selectedCase = String.fromEnvironment('LIVE_CASE');
        if (selectedCase.isNotEmpty && name != selectedCase) return;
        final watch = Stopwatch()..start();
        final traceStart = ai.decoded.length;
        final modelTextStart = client.outputTexts.length;
        try {
          final output = await run();
          results.add({
            'case': name,
            'passed': true,
            'elapsedMs': watch.elapsedMilliseconds,
            'output': output,
          });
        } catch (error) {
          // Only app-validation/test diagnostics; never HTTP failures or bodies.
          results.add({
            'case': name,
            'passed': false,
            'elapsedMs': watch.elapsedMilliseconds,
            'errorType': error.runtimeType.toString(),
            if (error is FormatException)
              'validationMessage': error.message.replaceAll(
                secret,
                '[REDACTED]',
              ),
            if (error is TestFailure)
              'assertionMessage': (error.message ?? '').replaceAll(
                secret,
                '[REDACTED]',
              ),
            'decodedApplicationResponses': ai.decoded.skip(traceStart).toList(),
            'successfulModelOutputTexts': client.outputTexts
                .skip(modelTextStart)
                .toList(),
          });
        }
      }

      try {
        // Requests 1-2: actual interpreter -> application condition merge -> AI.
        await scenario('compound_interpret_and_recommend', () async {
          final command = await assistant.interpret(
            '두부와 달걀로 맵지 않게 전자레인지만 써서 1인분 15분 이내 요리 추천해줘',
            useAi: true,
          );
          expect(command.intent, AssistantIntent.recommend);
          final c = assistant.recommendationConditions(command);
          expect(c.batchIds.toSet(), {'live-tofu', 'live-egg'});
          expect(c.servings, 1);
          expect(c.maxMinutes, 15);
          expect(c.preferences, isNotEmpty);
          expect(c.equipment, contains('전자레인지'));
          initialConditions = c;
          final recipes = await ai.recommend(
            store.activeBatches,
            servings: c.servings,
            maxMinutes: c.maxMinutes,
            preferences: c.preferences,
            equipment: c.equipment,
            excludedIngredients: c.excludedIngredients,
            selectedBatchIds: c.batchIds.toSet(),
          );
          expect(recipes, isNotEmpty);
          expect(recipes.every((r) => !r.allergensKnown), isTrue);
          expect(
            recipes.every((r) => r.servings == 1 && r.minutes <= 15),
            isTrue,
          );
          assistant.memory.recommendation = c;
          generated = recipes.first;
          return {
            'conditions': c.toJson(),
            'recipes': recipes.map((r) => r.toJson()).toList(),
            'semanticQualityReview':
                'pending: mild flavor and equipment suitability',
          };
        });
        // Request 3: follow-up constraint preservation without another generation.
        await scenario('followup_preserves_conditions', () async {
          if (initialConditions == null) {
            throw StateError('missing prerequisite');
          }
          assistant.memory.recommendation = initialConditions;
          final command = await assistant.interpret(
            '다른 조건은 그대로 두고 2인분 20분으로 바꿔줘',
            useAi: true,
          );
          final c = assistant.recommendationConditions(command);
          expect(c.servings, 2);
          expect(c.maxMinutes, 20);
          expect(c.batchIds.toSet(), initialConditions!.batchIds.toSet());
          expect(c.preferences, initialConditions!.preferences);
          expect(c.equipment, initialConditions!.equipment);
          return {'conditions': c.toJson()};
        });
        // Request 4: ambiguous amount must not become an executable mutation.
        await scenario('ambiguous_quantity_clarifies', () async {
          final command = await assistant.interpret('두부 조금 썼어', useAi: true);
          expect(command.intent, AssistantIntent.clarify);
          expect(command.question, isNotEmpty);
          return {'command': command.toJson()};
        });
        // Request 5: existing service, generated recipe where available.
        await scenario('cooking_coach', () async {
          final recipe = generated ?? AiService.demoRecipes.first;
          final reply = await assistant.coach(
            '현재 단계에서 무엇부터 하면 돼?',
            recipe,
            0,
            preferences: '맵지 않게',
            equipment: '전자레인지',
          );
          expect(reply.trim(), isNotEmpty);
          return {
            'recipeSource': generated == null
                ? 'explicit_fixture_fallback'
                : 'live_generated',
            'reply': reply,
            'semanticQualityReview': 'pending',
          };
        });
        // Requests 6-7: drafts only, neither action invokes addMany.
        await scenario('multi_item_intake', () async {
          final candidates = await IntakeAiService(ai)
              .parse('우유 2개, 달걀 6개, 두부 두 팩 추가해줘');
          expect(candidates.length, 3);
          final byName = {for (final c in candidates) c.batch.name: c};
          expect(byName.keys.toSet(), {'우유', '달걀', '두부'});
          expect(byName['우유']!.batch.quantity, 2);
          expect(byName['달걀']!.batch.quantity, 6);
          expect(byName['두부']!.batch.quantity, 2);
          expect(byName['우유']!.batch.category, '유제품');
          expect(byName['달걀']!.batch.category, '달걀');
          expect(byName['두부']!.batch.category, '가공식품');
          expect(candidates.every((c) => !c.needsQuantityReview), isTrue);
          return {
            'candidates': candidates
                .map(
                  (c) => {
                    'batch': c.batch.toJson(),
                    'evidence': c.evidence,
                    'needsQuantityReview': c.needsQuantityReview,
                  },
                )
                .toList(),
          };
        });
        await scenario('receipt_masked_structuring', () async {
          final candidates = await IntakeAiService(ai).parse(
            '전화 010-0000-0000\n두부 1팩 3,000\n우유 2개 5,000\n합계 8,000',
            receipt: true,
          );
          expect(candidates.length, 2);
          expect(
            candidates.every(
              (c) => c.batch.expiryStatus == ExpiryStatus.unknown,
            ),
            isTrue,
          );
          expect(candidates.every((c) => c.batch.quantity < 3000), isTrue);
          expect(
            candidates.every((c) => !c.evidence.contains('010-0000-0000')),
            isTrue,
          );
          return {
            'candidates': candidates
                .map(
                  (c) => {
                    'batch': c.batch.toJson(),
                    'evidence': c.evidence,
                    'needsQuantityReview': c.needsQuantityReview,
                  },
                )
                .toList(),
          };
        });
        // Request 8: explanations grounded in synthetic aggregates.
        await scenario('insight_evidence', () async {
          final advice = await InsightAiService(ai).explain([
            {
              'id': 'synthetic-1',
              'name': '두부',
              'unit': 'g',
              'consumed': 600,
              'wasted': 100,
              'wasteEvents': 2,
            },
          ]);
          expect(advice.evidenceIds, ['synthetic-1']);
          return {
            'reply': advice.text,
            'evidenceIds': advice.evidenceIds,
            'semanticQualityReview': 'pending',
          };
        });
      } finally {
        final unchanged =
            before ==
                jsonEncode(store.batches.map((b) => b.toJson()).toList()) &&
            historyBefore == store.history.length &&
            store.cookingSession == null;
        final report = {
          'timestampUtc': DateTime.now().toUtc().toIso8601String(),
          'syntheticDataOnly': true,
          'maxHttpRequests': 8,
          'inventoryUnchanged': unchanged,
          'cases': results,
          'qualityLimit': 'Assertions verify structure, constraints and storage. Human culinary/UX review remains separate.',
        };
        final output = File('build/ai_live_workflow_results.json');
        await output.parent.create(recursive: true);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ')
              .convert(report)
              .replaceAll(secret, '[REDACTED]'),
        );
        assistant.dispose();
        await store.close();
        store.dispose();
        expect(
          unchanged,
          isTrue,
          reason: 'Synthetic inventory changed unexpectedly.',
        );
      }
      expect(
        results.every((r) => r['passed'] == true),
        isTrue,
        reason: 'One or more live cases failed. See sanitized workflow report.',
      );
    },
    skip: !const bool.fromEnvironment('RUN_LIVE_AI'),
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
