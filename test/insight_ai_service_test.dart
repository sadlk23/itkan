import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/insight_ai_service.dart';

void main() {
  final facts = <Map<String, Object>>[
    {
      'id': 'record_0',
      'name': '우유',
      'unit': 'ml',
      'consumed': 300,
      'wasted': 100,
      'wasteEvents': 2,
    },
  ];
  test(
    'advice retains verified evidence references and computed facts',
    () async {
      final ai = AiService(
        baseUrl: 'https://example.test',
        client: MockClient((request) async {
          expect(jsonDecode(request.body)['text'], contains('"wasted":100'));
          return http.Response(
            jsonEncode({
              'reply': '다음 구매 전에 남은 우유를 확인하세요.',
              'evidenceIds': ['record_0'],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(ai.dispose);
      final result = await InsightAiService(ai).explain(facts);
      expect(result.evidenceIds, ['record_0']);
    },
  );
  test('invented evidence and missing evidence are rejected', () async {
    for (final ids in [
      <String>['unknown'],
      <String>[],
    ]) {
      final ai = AiService(
        baseUrl: 'https://example.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'reply': '조언', 'evidenceIds': ids}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await expectLater(
        InsightAiService(ai).explain(facts),
        throwsFormatException,
      );
      ai.dispose();
    }
  });
}
