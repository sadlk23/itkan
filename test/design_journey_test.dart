import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';

class _JourneyInventory extends InventoryStore {
  final rows = demoInventory(DateTime.now());
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
  void simulateQuantityChange() {
    rows[0] = rows[0].copyWith(
      quantity: rows[0].quantity + 1,
      revision: rows[0].revision + 1,
    );
    notifyListeners();
  }
}

void main() {
  Future<InventoryStore> start(
    WidgetTester tester, {
    AiService? ai,
    bool openDoor = true,
  }) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = _JourneyInventory();
    await tester.pumpWidget(
      MaterialApp(
        theme: FridgeTheme.light,
        home: HomeScreen(store: store, aiService: ai),
      ),
    );
    await tester.pumpAndSettle();
    if (openDoor) {
      await tester.ensureVisible(find.bySemanticsLabel('냉장고 문 열기'));
      await tester.tap(find.bySemanticsLabel('냉장고 문 열기'));
      await tester.pumpAndSettle();
    }
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    });
    return store;
  }

  testWidgets(
    'ingredient selection reaches recipe preference without mutating inventory',
    (tester) async {
      final store = await start(tester);
      final before = store.batches.firstWhere((b) => b.id == 'tofu').quantity;
      await tester.ensureVisible(find.byKey(const ValueKey('item-tofu')));
      await tester.tap(find.byKey(const ValueKey('item-tofu')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('이 재료로 요리 찾기'));
      await tester.tap(find.text('이 재료로 요리 찾기'));
      await tester.pumpAndSettle();
      expect(find.text('선택한 재료 · 두부'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('recipe-preference-두부')),
      );
      expect(find.text('두부를 활용한 요리'), findsOneWidget);
      expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('home question opens editable assistant input without sending', (
    tester,
  ) async {
    final store = await start(tester, openDoor: false);
    await tester.enterText(find.byType(TextField), '두부 있어?');
    await tester.tap(find.byTooltip('질문 입력 이어가기'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '두부 있어?',
    );
    expect(store.history, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inventory changes invalidate an in-flight recommendation', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final ai = AiService(
      baseUrl: 'https://example.invalid/ai',
      client: MockClient((_) => response.future),
    );
    final store = await start(tester, ai: ai) as _JourneyInventory;
    await tester.tap(find.text('AI 요리').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('내 재료로 AI 추천받기'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('내 재료로 AI 추천받기'));
    await tester.pump();
    store.simulateQuantityChange();
    await tester.pump();
    response.complete(
      http.Response(
        jsonEncode({
          'recipes': AiService.demoRecipes.map((r) => r.toJson()).toList(),
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('레시피 살펴보기'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(store.history, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home summary reads current inventory and opens a batch', (
    tester,
  ) async {
    final store = await start(tester);
    await tester.tap(find.byTooltip('냉장고 요약'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('보유 ${store.activeBatches.length}묶음'),
      findsOneWidget,
    );
    await tester.tap(find.text('두부').last);
    await tester.pumpAndSettle();
    expect(find.text('사용한 만큼 기록하기'), findsOneWidget);
    expect(store.history, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'recommendation loading prevents repeats and failure stays recoverable',
    (tester) async {
      final response = Completer<http.Response>();
      var calls = 0;
      final ai = AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient((_) {
          calls++;
          return response.future;
        }),
      );
      final store = await start(tester, ai: ai);
      await tester.tap(find.text('AI 요리').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('내 재료로 AI 추천받기'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('내 재료로 AI 추천받기'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(calls, 1);
      final button = find.ancestor(
        of: find.text('내 재료로 AI 추천받기'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      response.complete(http.Response('unavailable', 503));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('추천을 불러오지 못했어요.'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('추천을 불러오지 못했어요.'), findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(store.history, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'multiple fridge selections reach the request and can be revised',
    (tester) async {
      String sent = '';
      final ai = AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient((request) async {
          sent = (jsonDecode(request.body) as Map)['text'] as String;
          return http.Response('unavailable', 503);
        }),
      );
      final store = await start(tester, ai: ai);
      await tester.ensureVisible(find.text('요리 재료 선택'));
      await tester.tap(find.text('요리 재료 선택'));
      await tester.pumpAndSettle();
      for (final id in ['tofu', 'milk']) {
        await tester.ensureVisible(find.byKey(ValueKey('item-$id')));
        await tester.tap(find.byKey(ValueKey('item-$id')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('선택한 2개 재료로 요리 찾기'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('selected-recipe-tofu')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selected-recipe-milk')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('내 재료로 AI 추천받기').hitTestable(),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('내 재료로 AI 추천받기'));
      await tester.pumpAndSettle();
      expect(sent, contains('두부'));
      expect(sent, contains('우유'));
      expect(sent, isNot(contains('대파')));
      expect(store.history, isEmpty);
      await tester.ensureVisible(find.text('재료 다시 고르기'));
      await tester.tap(find.text('재료 다시 고르기'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('item-milk')));
      await tester.tap(find.byKey(const ValueKey('item-milk')));
      await tester.pumpAndSettle();
      expect(find.text('선택한 1개 재료로 요리 찾기'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('item-tofu')));
      await tester.tap(find.byKey(const ValueKey('item-tofu')));
      await tester.pumpAndSettle();
      final disabled = find.ancestor(
        of: find.text('선택한 0개 재료로 요리 찾기'),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(disabled).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
