import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/widgets/inventory_browser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capture_fonts.dart';

const _capture = bool.fromEnvironment('CAPTURE_AI');

class _VisualStore extends InventoryStore {
  final rows = [
    InventoryBatch(
      id: 'tofu',
      name: '두부',
      quantity: 300,
      unit: 'g',
      category: '가공식품',
    ),
    InventoryBatch(
      id: 'unknown',
      name: '처음 넣은 수제 반찬',
      quantity: 1,
      unit: '개',
      category: '반찬',
    ),
    InventoryBatch(
      id: 'milk',
      name: '우유',
      quantity: 500,
      unit: 'ml',
      category: '유제품',
    ),
    InventoryBatch(
      id: 'unknown2',
      name: '새로운 조미료',
      quantity: 1,
      unit: '개',
      category: '조미료',
    ),
    InventoryBatch(
      id: 'apple',
      name: '사과',
      quantity: 2,
      unit: '개',
      category: '과일',
    ),
    InventoryBatch(
      id: 'tomato',
      name: '토마토',
      quantity: 2,
      unit: '개',
      category: '채소',
    ),
  ];
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'kitchen_visited': true}),
  );
  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'mixed representative and unknown ingredients remain usable scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (_capture) {
          await tester.runAsync(loadCaptureFonts);
        }
        final store = _VisualStore();
        addTearDown(store.dispose);
        final boundary = GlobalKey();
        String? opened;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _capture
                  ? FridgeTheme.light.copyWith(
                      appBarTheme: FridgeTheme.light.appBarTheme.copyWith(
                        titleTextStyle: FridgeTheme
                            .light
                            .appBarTheme
                            .titleTextStyle
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
              home: Scaffold(
                appBar: AppBar(title: const Text('나의 냉장고')),
                body: InventoryBrowser(
                  store: store,
                  onOpen: (batch) => opened = batch.id,
                  onAdd: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('처음 넣은 수제 반찬'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('item-unknown')));
        expect(opened, 'unknown');
        if (_capture) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await render.toImage(pixelRatio: 2);
            final data = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File(
              'docs/screenshots/audit-density-${scale == 1 ? 'normal' : 'large'}.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(data!.buffer.asUint8List());
            picture.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    testWidgets('home recipe first viewport scale $scale', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (_capture) {
        await tester.runAsync(loadCaptureFonts);
      }
      final store = _VisualStore();
      addTearDown(store.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _capture
                ? FridgeTheme.light.copyWith(
                    appBarTheme: FridgeTheme.light.appBarTheme.copyWith(
                      titleTextStyle: FridgeTheme
                          .light
                          .appBarTheme
                          .titleTextStyle
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
            home: HomeScreen(
              store: store,
              aiService: AiService(baseUrl: 'https://example.invalid/ai'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(NavigationBar),
              matching: find.text('AI 요리'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.text('내 재료로 AI 추천받기'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (_capture) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final picture = await render.toImage(pixelRatio: 2);
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          final output = File(
            'docs/screenshots/audit-home-recipes-${scale == 1 ? 'normal' : 'large'}.png',
          );
          await output.parent.create(recursive: true);
          await output.writeAsBytes(data!.buffer.asUint8List());
          picture.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
