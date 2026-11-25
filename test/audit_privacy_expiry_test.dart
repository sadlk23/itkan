import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/intake_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('past dated supply is excluded and explicit expired selection is rejected before HTTP', () async {
    final now = DateTime.now();
    final past = InventoryBatch(
      id: 'past',
      name: '지난 두부',
      quantity: 100,
      unit: 'g',
      expiryStatus: ExpiryStatus.actual,
      expiryDate: now.subtract(const Duration(days: 2)),
    );
    final current = InventoryBatch(
      id: 'current',
      name: '당근',
      quantity: 100,
      unit: 'g',
    );
    var calls = 0;
    var prompt = '';
    final ai = AiService(
      baseUrl: 'https://example.invalid',
      client: MockClient((request) async {
        calls++;
        prompt = jsonDecode(request.body)['text'] as String;
        return http.Response('{"recipes":[]}', 200);
      }),
    );
    await ai.recommend([past, current]);
    expect(prompt, contains('당근'));
    expect(prompt, isNot(contains('지난 두부')));
    await expectLater(
      ai.recommend([past, current], selectedBatchIds: {'past'}),
      throwsArgumentError,
    );
    expect(calls, 1);
    ai.dispose();
  });

  testWidgets(
    'receipt AI receives edited source without removed private line',
    (tester) async {
      final store = InventoryStore();
      var sent = '';
      final ai = AiService(
        baseUrl: 'https://example.invalid',
        client: MockClient((request) async {
          sent = jsonDecode(request.body)['text'] as String;
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'name': '우유',
                  'quantity': 2,
                  'unit': '팩',
                  'category': '유제품',
                  'evidence': '우유 2팩',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CandidateScreen(
            store: store,
            rawText: '회원명 테스트개인정보\n우유 2팩',
            source: 'ocr',
            aiService: ai,
            drafts: const [],
          ),
        ),
      );
      await tester.tap(find.text('전송할 원문 확인 · 수정'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('receipt-source-editor')),
        '우유 2팩',
      );
      await tester.ensureVisible(find.text('AI로 품목 정리하기'));
      await tester.tap(find.text('AI로 품목 정리하기'));
      await tester.pumpAndSettle();
      expect(sent, contains('우유 2팩'));
      expect(sent, isNot(contains('테스트개인정보')));
      expect(find.text('우유'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      ai.dispose();
      store.dispose();
    },
  );

  testWidgets('leaving unsaved intake candidates requires explicit discard', (
    tester,
  ) async {
    final store = InventoryStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => CandidateScreen(
                    store: store,
                    rawText: '두부',
                    source: 'shopping',
                    drafts: [
                      InventoryBatch(
                        id: 'draft',
                        name: '두부',
                        quantity: 1,
                        unit: '개',
                      ),
                    ],
                  ),
                ),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('입고 확인을 나갈까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.text('두부'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('나가기'));
    await tester.pumpAndSettle();
    expect(find.text('열기'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
}
