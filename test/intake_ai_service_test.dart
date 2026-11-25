import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/intake_ai_service.dart';
import 'package:my_fridge/models/inventory.dart';

void main() {
  test(
    'explicit Korean quantities are grounded and categories allowlisted',
    () {
      final result = IntakeAiService.decode({
        'candidates': [
          {
            'name': '두부',
            'quantity': 2,
            'unit': '팩',
            'evidence': '두부 두 팩',
            'category': '가공식품',
          },
          {
            'name': '우유',
            'quantity': 1,
            'unit': '개',
            'evidence': '우유 하나',
            'category': 'invalid',
          },
        ],
      }, '두부 두 팩 우유 하나');
      expect(result.first.needsQuantityReview, isFalse);
      expect(result.first.batch.category, '가공식품');
      expect(result.last.needsQuantityReview, isTrue);
      expect(result.last.batch.category, '기타');
    },
  );
  test(
    'multiple grounded items preserve quantity and leave expiry unknown',
    () {
      final result = IntakeAiService.decode({
        'candidates': [
          {'name': '우유', 'quantity': 2, 'unit': '개', 'evidence': '우유 2개'},
          {'name': '달걀', 'quantity': 6, 'unit': '개', 'evidence': '달걀 6개'},
        ],
      }, '우유 2개, 달걀 6개 샀어');
      expect(result.map((c) => c.batch.quantity), [2, 6]);
      expect(result.every((c) => !c.needsQuantityReview), isTrue);
      expect(
        result.every((c) => c.batch.expiryStatus == ExpiryStatus.unknown),
        isTrue,
      );
      expect(result[0].batch.id, isNot(result[1].batch.id));
    },
  );
  test('receipt prices or model-invented quantity require correction', () {
    final result = IntakeAiService.decode({
      'candidates': [
        {'name': '두부', 'quantity': 3000, 'unit': '개', 'evidence': '두부 3,000'},
      ],
    }, '두부 3,000');
    expect(result.single.needsQuantityReview, isTrue);
    expect(result.single.batch.quantity, 1);
  });
  test('fabricated evidence and oversized list fail closed', () {
    expect(
      () => IntakeAiService.decode({
        'candidates': [
          {'name': '두부', 'quantity': 1, 'unit': '개', 'evidence': '두부 1개'},
        ],
      }, '우유 2개'),
      throwsFormatException,
    );
    expect(
      () => IntakeAiService.decode({'candidates': List.filled(31, {})}, ''),
      throwsFormatException,
    );
  });
  test('only masked receipt text is sent through mocked transport', () async {
    final ai = AiService(
      baseUrl: 'https://example.invalid/ai',
      client: MockClient((request) async {
        final prompt = jsonDecode(request.body)['text'] as String;
        expect(prompt, isNot(contains('010-1234-5678')));
        expect(prompt, contains('[개인정보 가림]'));
        expect(prompt, contains('"category":"가공식품"'));
        expect(prompt, contains('우유/요거트→유제품'));
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'name': '두부',
                'quantity': 1,
                'unit': '팩',
                'category': '가공식품',
                'evidence': '두부 1팩',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(ai.dispose);
    final result = await IntakeAiService(ai)
        .parse('전화 010-1234-5678\n두부 1팩', receipt: true);
    expect(result.single.batch.name, '두부');
    expect(result.single.batch.category, '가공식품');
  });
}
