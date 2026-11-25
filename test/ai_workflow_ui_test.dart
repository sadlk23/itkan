// Real widgets with mock transport; CAPTURE_AI=true writes review screenshots.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/models/assistant_command.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/assistant_screen.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/screens/intake_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/intake_ai_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capture_fonts.dart';

class _Inventory extends InventoryStore {
  final rows = demoInventory(DateTime.now());
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

const captureAi = bool.fromEnvironment('CAPTURE_AI');

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _recipe(String title) => {
  'title': title,
  'servings': 1,
  'minutes': 10,
  'reason': '보유한 두부를 활용했어요.',
  'ingredients': [
    {'name': '두부', 'quantity': 100, 'unit': 'g', 'optional': false},
  ],
  'steps': ['두부를 썰어 익히세요.'],
  'allergens': ['대두'],
  'allergensKnown': true,
};

Future<GlobalKey> _mount(
  WidgetTester tester,
  Widget screen, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (captureAi) {
    await tester.runAsync(loadCaptureFonts);
  }
  final boundary = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: captureAi
            ? FridgeTheme.light.copyWith(
                appBarTheme: FridgeTheme.light.appBarTheme.copyWith(
                  titleTextStyle: FridgeTheme.light.appBarTheme.titleTextStyle
                      ?.copyWith(fontFamily: 'ReviewKorean'),
                ),
                textTheme: FridgeTheme.light.textTheme.apply(
                  fontFamily: 'ReviewKorean',
                ),
              )
            : FridgeTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return boundary;
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  expect(tester.takeException(), isNull);
  if (!captureAi) return;
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final picture = await render.toImage(pixelRatio: 2);
    final data = await picture.toByteData(format: ui.ImageByteFormat.png);
    final output = File('docs/screenshots/ai-$name.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data!.buffer.asUint8List());
    picture.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'kitchen_visited': true});
    AssistantMemory.instance.clear();
    for (final channel in [
      'flutter_tts',
      'plugin.csdcorp.com/speech_to_text',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(channel),
            (call) async =>
                call.method == 'getDefaultEngine' ? 'test-engine' : true,
          );
    }
  });

  testWidgets('unverified intake quantity requires editing before selection', (
    tester,
  ) async {
    final store = _Inventory();
    addTearDown(store.dispose);
    final ai = AiService(
      baseUrl: 'https://example.invalid/ai',
      client: MockClient(
        (_) async => _json({
          'candidates': [
            {'name': '두부', 'quantity': null, 'unit': null, 'evidence': '두부 샀어'},
          ],
        }),
      ),
    );
    final candidates = await IntakeAiService(ai).parse('두부 샀어');
    ai.dispose();
    final boundary = await _mount(
      tester,
      CandidateScreen(
        store: store,
        rawText: '두부 샀어',
        source: 'ai_text',
        candidates: candidates,
      ),
    );
    expect(find.text('원문 근거: 두부 샀어'), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNull,
    );
    await _capture(tester, boundary, 'intake-evidence');
    await tester.tap(find.text('항목 수정'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '수량'), '2');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('batch-save')),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch-save')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNotNull,
    );
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(find.text('선택한 1개 항목 입고'), findsOneWidget);
    expect(store.history, isEmpty);
    await _capture(tester, boundary, 'intake-reviewed');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'assistant failure preserves original and retry succeeds at scale $scale',
      (tester) async {
        var calls = 0;
        final prompts = <String>[];
        final store = _Inventory();
        addTearDown(store.dispose);
        final ai = AiService(
          baseUrl: 'https://example.invalid/ai',
          client: MockClient((request) async {
            prompts.add((jsonDecode(request.body) as Map)['text'] as String);
            calls++;
            return calls == 1
                ? _json({'error': 'temporary'}, 503)
                : _json({
                    'command': {'intent': 'search', 'item': '두부'},
                  });
          }),
        );
        final boundary = await _mount(
          tester,
          AssistantScreen(store: store, aiService: ai),
          scale: scale,
        );
        await tester.enterText(find.byType(TextField), '두부 얼마나 남았어?');
        await tester.tap(find.byTooltip('명령 보내기'));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '두부 얼마나 남았어?',
        );
        expect(find.text('실패한 입력 다시 시도'), findsOneWidget);
        expect(
          tester.getRect(find.byTooltip('명령 보내기')).bottom,
          lessThanOrEqualTo(844),
        );
        expect(
          tester.getRect(find.byTooltip('대화 설정')).bottom,
          lessThanOrEqualTo(844),
        );
        expect(find.byTooltip('명령 보내기').hitTestable(), findsOneWidget);
        expect(store.history, isEmpty);
        await _capture(
          tester,
          boundary,
          'assistant-retry-${scale == 1 ? 'normal' : 'large'}',
        );
        await tester.tap(find.text('실패한 입력 다시 시도'));
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(prompts.every((p) => p.contains('두부 얼마나 남았어?')), isTrue);
        expect(find.text('실패한 입력 다시 시도'), findsNothing);
        expect(find.textContaining('입력: 두부 얼마나 남았어?'), findsOneWidget);
        expect(store.history, isEmpty);
        await _capture(
          tester,
          boundary,
          'assistant-result-${scale == 1 ? 'normal' : 'large'}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'home revision requires approval and preserves the original on cancel',
    (tester) async {
      var calls = 0;
      final prompts = <String>[];
      final store = _Inventory();
      addTearDown(store.dispose);
      final ai = AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient((request) async {
          prompts.add((jsonDecode(request.body) as Map)['text'] as String);
          calls++;
          return _json({
            'recipes': [_recipe(calls == 1 ? '처음 추천한 두부 요리' : '담백한 수정 두부 요리')],
          });
        }),
      );
      final boundary = await _mount(
        tester,
        HomeScreen(store: store, aiService: ai),
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(NavigationBar),
              matching: find.text('AI 요리'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('내 재료로 AI 추천받기'));
      await tester.tap(find.text('내 재료로 AI 추천받기'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('처음 추천한 두부 요리'), findsOneWidget);
      expect(AssistantMemory.instance.recipes.single.title, '처음 추천한 두부 요리');
      expect(AssistantMemory.instance.recommendation, isNotNull);
      Future<void> revise() async {
        await tester.ensureVisible(find.text('재고로 대체 · 조건 바꿔 수정'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('재고로 대체 · 조건 바꿔 수정'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '우유 없이 담백하게',
        );
        final milk = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilterChip, '우유'),
        );
        await tester.ensureVisible(milk);
        await tester.pumpAndSettle();
        await tester.tap(milk);
        await tester.tap(find.text('수정안 만들기'));
        await tester.pumpAndSettle();
        expect(find.text('변경 전후 확인'), findsOneWidget);
      }

      await revise();
      await _capture(tester, boundary, 'revision-review');
      final prefs = await SharedPreferences.getInstance();
      final key = store.isDemo ? 'recipes_demo' : 'recipes_real';
      final before = prefs.getString(key);
      expect(before, contains('처음 추천한 두부 요리'));
      await tester.tap(find.text('기존 유지'));
      await tester.pumpAndSettle();
      expect(find.text('처음 추천한 두부 요리'), findsOneWidget);
      expect(find.text('담백한 수정 두부 요리'), findsNothing);
      expect(prefs.getString(key), before);
      expect(AssistantMemory.instance.recipes.single.title, '처음 추천한 두부 요리');
      await revise();
      await tester.tap(find.text('수정안 저장'));
      await tester.pumpAndSettle();
      expect(find.text('처음 추천한 두부 요리'), findsNothing);
      expect(find.text('담백한 수정 두부 요리'), findsOneWidget);
      expect(prefs.getString(key), contains('담백한 수정 두부 요리'));
      expect(prompts.last, contains('이번 요청에서 반드시 제외할 재료: ["우유"]'));
      expect(store.history, isEmpty);
      expect(find.textContaining('이전 조건의 결과'), findsNothing);
      expect(AssistantMemory.instance.recipes.single.title, '담백한 수정 두부 요리');
      expect(AssistantMemory.instance.recommendation!.excludedIngredients, [
        '우유',
      ]);
      expect(find.text('이 요리로 이어서 대화'), findsOneWidget);
      await tester.ensureVisible(find.text('담백한 수정 두부 요리'));
      await _capture(tester, boundary, 'revision-approved');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
