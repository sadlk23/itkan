import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/insights_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';

class _InsightStore extends InventoryStore {
  final row = InventoryBatch(id: 'milk', name: '우유', quantity: 100, unit: 'ml');
  @override
  List<InventoryBatch> get batches => [row];
  @override
  List<InventoryBatch> get activeBatches => batches;
  @override
  List<InventoryChange> get history => [
    InventoryChange(
      id: 'usage',
      label: '사용',
      createdAt: DateTime.now(),
      before: [row.copyWith(quantity: 200)],
      after: [row],
      action: 'consume',
    ),
  ];
  void changed() => notifyListeners();
}

void main() {
  testWidgets(
    'insight requests are explicit and stale responses never appear',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = _InsightStore();
      final response = Completer<http.Response>();
      var calls = 0;
      final ai = AiService(
        baseUrl: 'https://example.test',
        client: MockClient((_) {
          calls++;
          return response.future;
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: InsightsScreen(store: store, aiService: ai),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.text('이 기록으로 AI 조언 받기'));
      await tester.pump();
      expect(calls, 1);
      store.changed();
      await tester.pump();
      response.complete(
        http.Response(
          jsonEncode({
            'reply': '오래된 조언',
            'evidenceIds': ['record_0'],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('오래된 조언'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(store.history, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );
}
