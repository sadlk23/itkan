import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:my_fridge/main.dart';
import 'package:my_fridge/models/assistant_command.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/screens/assistant_screen.dart';
import 'package:my_fridge/screens/shopping_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/assistant_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/shopping_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Kitchen extends InventoryStore {
  List<InventoryBatch> stock = [];
  bool sample = true;
  @override
  bool get isInitialized => true;
  @override
  List<InventoryBatch> get batches => stock;
  @override
  List<InventoryBatch> get activeBatches =>
      stock.where((b) => b.active).toList();
  @override
  bool get isDemo => sample;

  void switchMode() {
    sample = !sample;
    notifyListeners();
  }
}

Recipe _recipe(String title, List<RecipeIngredient> ingredients) => Recipe(
  id: title,
  title: title,
  source: 'demo',
  servings: 1,
  minutes: 15,
  ingredients: ingredients,
  steps: const ['재료를 익힌다'],
  generatedAt: DateTime(2026, 11, 23),
);

const _request = '이 요리에 없는 재료 장보기에 담아줘';
const _tofu = RecipeIngredient(name: '두부', quantity: 300, unit: 'g');
const _speech = MethodChannel('plugin.csdcorp.com/speech_to_text');

Future<void> _open(
  WidgetTester tester,
  _Kitchen kitchen, {
  Recipe? recipe,
  AiService? ai,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AssistantScreen(store: kitchen, recipe: recipe, aiService: ai),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _send(
  WidgetTester tester,
  String text, {
  bool voice = false,
}) async {
  if (voice) {
    await tester.tap(find.byTooltip('마이크로 말하기'));
    await tester.pumpAndSettle();
    final result = jsonEncode({
      'alternates': [
        {'recognizedWords': text, 'confidence': 1.0},
      ],
      'resultType': 2,
    });
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _speech.name,
      _speech.codec.encodeMethodCall(MethodCall('textRecognition', result)),
      (_) {},
    );
    await tester.pump();
  } else {
    await tester.enterText(find.byType(TextField), text);
    FocusManager.instance.primaryFocus?.unfocus();
  }
  await tester.tap(find.byTooltip('명령 보내기'));
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Kitchen kitchen;
  late ShoppingStore shopping;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AssistantMemory.instance.clear();
    kitchen = _Kitchen();
    shopping = ShoppingStore(inventory: kitchen);
    for (final channel in [_speech, const MethodChannel('flutter_tts')]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async =>
                call.method == 'getDefaultEngine' ? 'test-engine' : true,
          );
    }
  });
  tearDown(() {
    shopping.dispose();
    kitchen.dispose();
  });

  test('recognizes recipe shortages independently of manual items and read-only questions', () {
    for (final text in [
      _request,
      '없는 재료 담아 줘',
      '장바구니에 모자라는 재료를 넣어주세요',
      '레시피에 부족한 재료 장보기 추가',
    ]) {
      final command = AssistantService.parseLocal(text);
      expect(command.intent, AssistantIntent.recipeShopping, reason: text);
      expect(command.item, isEmpty, reason: text);
    }
    expect(
      AssistantService.parseLocal('추천 2번 요리의 부족분 장바구니에 담아줘').recipeIndex,
      2,
    );
    expect(AssistantService.parseLocal('김치찌개에 없는 재료 담아줘').item, '김치찌개');
    final manual = AssistantService.parseLocal('우유 1팩 장보기 추가');
    expect(manual.intent, AssistantIntent.shopping);
    expect([manual.item, manual.quantity, manual.unit], ['우유', 1, '팩']);
    for (final text in [
      '이 요리에 부족한 재료가 있어?',
      '없는 재료는 장바구니에 담지 마',
      '없는 재료 중 두부만 장보기에 담아줘',
    ]) {
      expect(
        [AssistantIntent.recipeShopping, AssistantIntent.shopping],
        isNot(contains(AssistantService.parseLocal(text).intent)),
        reason: text,
      );
    }
  });

  testWidgets(
    'selected recipe sends actual shortages once, keeps unknown quantities, and undoes the right change',
    (tester) async {
      kitchen.stock = [
        InventoryBatch(id: 'tofu', name: '두부', quantity: 100, unit: 'g'),
        InventoryBatch(
          id: 'salt',
          name: '소금',
          quantity: 1,
          unit: 'g',
          quantityMode: QuantityMode.status,
        ),
      ];
      final recipe = _recipe('두부조림', [
        _tofu,
        const RecipeIngredient(name: '소금', quantity: 2, unit: 'g'),
        const RecipeIngredient(name: '식초', quantity: null, unit: ''),
        const RecipeIngredient(
          name: '후추',
          quantity: 1,
          unit: 'g',
          optional: true,
        ),
      ]);
      final ai = AiService(
        baseUrl: 'https://example.invalid',
        client: MockClient((_) => throw StateError('명시적인 요청은 로컬에서 처리해야 합니다.')),
      );
      await _open(tester, kitchen, recipe: recipe, ai: ai);
      await _tapText(tester, '없는 재료 장보기에 담아줘');
      await tester.tap(find.byTooltip('명령 보내기'));
      await tester.pumpAndSettle();
      await shopping.reload();
      expect(shopping.plans.single.recipes.single.id, recipe.id);
      expect(
        shopping.items.firstWhere((item) => item.name == '두부').quantity,
        200,
      );
      expect(find.textContaining('두부 200g'), findsOneWidget);
      expect(find.textContaining('수량 직접 확인'), findsOneWidget);
      expect(shopping.unquantifiedIngredients, containsAll(['소금', '식초']));
      expect(
        shopping.items.any((item) => item.name == '후추' || item.name == '없는 재료'),
        isFalse,
      );
      await _send(tester, _request);
      expect(find.textContaining('이미 장보기 계획에'), findsOneWidget);
      expect(find.text('장보기 실행 취소'), findsOneWidget);
      await _tapText(tester, '장보기 실행 취소');
      await shopping.reload();
      expect(shopping.plans, isEmpty);
      expect(shopping.items, isEmpty);
      expect(kitchen.batches.first.quantity, 100);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'result returns to the existing shopping tab with fresh quantities',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('kitchen_visited', true);
      AssistantMemory.instance.syncMode(kitchen.isDemo);
      AssistantMemory.instance.selectedRecipe = _recipe('두부조림', [_tofu]);
      await tester.pumpWidget(FridgeApp(store: kitchen));
      await tester.pumpAndSettle();
      await tester.tap(find.text('장보기'));
      await tester.pumpAndSettle();
      expect(find.text('장바구니가 가벼워요'), findsOneWidget);

      await tester.tap(find.byTooltip('AI에게 물어보기'));
      await tester.pumpAndSettle();
      await _send(tester, _request);
      await _tapText(tester, '장보기 목록 보기');

      expect(find.byType(AssistantScreen), findsNothing);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      expect(
        tester
            .widget<ShoppingScreen>(find.byType(ShoppingScreen))
            .onPurchasedIntake,
        isNotNull,
      );
      await tester.scrollUntilVisible(
        find.text('두부 · 300g'),
        220,
        scrollable: find
            .descendant(
              of: find.byType(ShoppingScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('두부 · 300g'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'asks for a target, rejects invalid numbers and carries a choice reply into shopping',
    (tester) async {
      final recipes = [
        _recipe('두부조림', [_tofu]),
        _recipe('감자찜', [
          const RecipeIngredient(name: '감자', quantity: 2, unit: '개'),
        ]),
      ];
      AssistantMemory.instance.syncMode(kitchen.isDemo);
      AssistantService.lastRecipes = recipes;
      await _open(tester, kitchen);
      await _send(tester, '없는 재료 장바구니에 넣어줘');
      await shopping.reload();
      expect(shopping.plans, isEmpty);
      expect(find.text('1. 두부조림'), findsOneWidget);
      expect(find.text('2. 감자찜'), findsOneWidget);
      await _send(tester, '0번');
      await shopping.reload();
      expect(shopping.plans, isEmpty);
      await _send(tester, '두 번째');
      await shopping.reload();
      expect(shopping.plans.single.recipes.single.id, recipes[1].id);
      expect(shopping.items.single.name, '감자');
      expect(AssistantMemory.instance.selectedRecipe?.id, recipes[1].id);
      await _send(tester, '없는요리에 없는 재료 장보기에 담아줘');
      expect(find.textContaining('어느 요리의 부족한 재료'), findsWidgets);
      await shopping.reload();
      expect(shopping.plans.single.recipes, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('enough inventory or no recipe produces no plan or undo', (
    tester,
  ) async {
    await _open(tester, kitchen);
    await _send(tester, _request);
    expect(find.textContaining('요리를 먼저 선택해주세요'), findsOneWidget);
    kitchen.stock = [
      InventoryBatch(id: 'tofu', name: '두부', quantity: 500, unit: 'g'),
    ];
    await tester.pumpWidget(const SizedBox.shrink());
    await _open(tester, kitchen, recipe: _recipe('두부조림', [_tofu]));
    await _send(tester, _request);
    expect(find.textContaining('새로 담을 재료가 없어요'), findsOneWidget);
    expect(find.text('장보기 실행 취소'), findsNothing);
    await shopping.reload();
    expect(shopping.plans, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'voice previews and cancels, asks again on changed shortage, and drops the preview on a mode switch',
    (tester) async {
      final recipe = _recipe('두부조림', [_tofu]);
      await _open(tester, kitchen, recipe: recipe);
      await _send(tester, _request, voice: true);
      await shopping.reload();
      expect(shopping.plans, isEmpty);
      expect(find.textContaining('두부 300g'), findsOneWidget);
      await _tapText(tester, '취소');
      await shopping.reload();
      expect(shopping.plans, isEmpty);
      await _send(tester, _request, voice: true);
      kitchen.stock = [
        InventoryBatch(id: 'tofu', name: '두부', quantity: 100, unit: 'g'),
      ];
      await _tapText(tester, '인식 내용 확인하고 실행');
      expect(find.textContaining('두부 200g'), findsOneWidget);
      await shopping.reload();
      expect(shopping.plans, isEmpty);
      await _tapText(tester, '인식 내용 확인하고 실행');
      await shopping.reload();
      expect(shopping.items.single.quantity, 200);
      await _tapText(tester, '장보기 실행 취소');
      await _send(tester, _request, voice: true);
      kitchen.switchMode();
      await tester.pumpAndSettle();
      expect(find.text('인식 내용 확인하고 실행'), findsNothing);
      expect(AssistantMemory.instance.selectedRecipe, isNull);
      await shopping.reload();
      expect(shopping.plans, isEmpty);
      kitchen.switchMode();
      await shopping.reload();
      expect(shopping.plans, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
