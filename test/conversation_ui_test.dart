import 'dart:async';
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
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capture_fonts.dart';

const captureAi = bool.fromEnvironment('CAPTURE_AI');

class _Inventory extends InventoryStore {
  void signalChange() => notifyListeners();
  final rows = demoInventory(DateTime.now());
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

http.Response _json(Map<String, dynamic> data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
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
    SharedPreferences.setMockInitialValues({});
    AssistantMemory.instance.clear();
    for (final name in ['flutter_tts', 'plugin.csdcorp.com/speech_to_text']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(name),
            (call) async =>
                call.method == 'getDefaultEngine' ? 'test-engine' : true,
          );
    }
  });
  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'conversation restores context draft and replies at scale $scale',
      (tester) async {
        final store = _Inventory();
        addTearDown(store.dispose);
        var calls = 0;
        final prompts = <String>[];
        AiService transport() => AiService(
          baseUrl: 'https://example.invalid/ai',
          client: MockClient((request) async {
            prompts.add((jsonDecode(request.body) as Map)['text'] as String);
            calls++;
            if (calls == 1) {
              return _json({
                'command': {'intent': 'search', 'item': '두부'},
              });
            }
            if (calls == 2) {
              return _json({
                'command': {
                  'intent': 'coach',
                  'question': '그 재료 보관할 때 주의할 점은?',
                },
              });
            }
            return _json({
              'reply': '두부는 제품 표시와 개봉 여부를 먼저 확인해주세요. 냉장 보관 중인 두부를 기준으로 말씀드렸어요.',
            });
          }),
        );
        await _mount(
          tester,
          AssistantScreen(store: store, aiService: transport()),
          scale: scale,
        );
        await tester.enterText(find.byType(TextField), '두부 있어?');
        await tester.tap(find.byTooltip('명령 보내기'));
        await tester.pumpAndSettle();
        expect(find.text('그걸로 추천해줘'), findsOneWidget);
        await tester.tap(find.text('그걸로 추천해줘'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '그걸로 추천해줘',
        );
        expect(
          calls,
          1,
        ); // A suggestion fills the draft; it never sends on its own.
        await tester.enterText(find.byType(TextField), '그 재료 보관할 때 주의할 점은?');
        await tester.tap(find.byTooltip('명령 보내기'));
        await tester.pumpAndSettle();
        expect(calls, 3);
        expect(prompts.last, contains('두부'));
        expect(find.textContaining('먼저 레시피에서 요리를 시작'), findsNothing);
        await tester.enterText(find.byType(TextField), '그리고 내일은?');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final boundary = await _mount(
          tester,
          AssistantScreen(store: store, aiService: transport()),
          scale: scale,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '그리고 내일은?',
        );
        expect(find.textContaining('두부는 제품 표시'), findsOneWidget);
        expect(find.textContaining('입력: 두부 있어?'), findsOneWidget);
        expect(find.byTooltip('이어받은 맥락 자세히 보기'), findsOneWidget);
        expect(find.text('확인하고 반영'), findsNothing);
        expect(calls, 3);
        expect(
          tester.getRect(find.byTooltip('명령 보내기')).bottom,
          lessThanOrEqualTo(844),
        );
        await _capture(
          tester,
          boundary,
          'conversation-restored-${scale == 1 ? 'normal' : 'large'}',
        );
        await tester.tap(find.byTooltip('대화 맥락 초기화'));
        await tester.pumpAndSettle();
        expect(AssistantMemory.instance.turns, isEmpty);
        expect(AssistantMemory.instance.draft, isEmpty);
        expect(AssistantMemory.instance.lastBatchId, isNull);
        expect(find.textContaining('입력: 두부 있어?'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
  testWidgets(
    'reset while request is pending removes private draft and response',
    (tester) async {
      final store = _Inventory();
      addTearDown(store.dispose);
      final reply = Completer<http.Response>();
      await _mount(
        tester,
        AssistantScreen(
          store: store,
          aiService: AiService(
            baseUrl: 'https://example.invalid/ai',
            client: MockClient((_) => reply.future),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '개인 입력 두부 있어?');
      await tester.tap(find.byTooltip('명령 보내기'));
      await tester.pump();
      AssistantMemory.instance.clear();
      store.signalChange();
      await tester.pump();
      reply.complete(
        _json({
          'command': {'intent': 'search', 'item': '두부'},
        }),
      );
      await tester.pumpAndSettle();
      expect(AssistantMemory.instance.turns, isEmpty);
      expect(AssistantMemory.instance.draft, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.textContaining('입력: 개인 입력'), findsNothing);
      expect(find.text('실패한 입력 다시 시도'), findsNothing);
      expect(find.textContaining('대화가 초기화되어 이전 요청'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'new quantity replaces old confirmation without writing inventory',
    (tester) async {
      final store = _Inventory();
      addTearDown(store.dispose);
      await _mount(
        tester,
        AssistantScreen(
          store: store,
          aiService: AiService(baseUrl: ''),
        ),
      );
      for (final text in ['두부 100g 사용', '50g']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.tap(find.byTooltip('명령 보내기'));
        await tester.pumpAndSettle();
      }
      expect(find.text('확인하고 반영'), findsOneWidget);
      expect(find.textContaining('이어진 요청으로 확인 내용을 갱신'), findsOneWidget);
      expect(AssistantMemory.instance.pending!.quantity, 50);
      expect(store.history, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
