// Optional visual review: flutter test test/design_capture_test.dart
// --dart-define=CAPTURE_DESIGN=true. Renders real production widgets.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/home_screen.dart';
import 'package:my_fridge/screens/batch_form.dart';
import 'package:my_fridge/screens/recipe_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';

import 'capture_fonts.dart';

class _CaptureStore extends InventoryStore {
  final rows = const bool.fromEnvironment('CAPTURE_MIXED')
      ? [
          ...demoInventory(DateTime.now())
              .where((b) => b.id == 'tofu' || b.id == 'milk'),
          InventoryBatch(
            id: 'homemade',
            name: '엄마가 준 반찬',
            quantity: 1,
            unit: '통',
            category: '반찬',
          ),
          InventoryBatch(
            id: 'pizza',
            name: '먹다 남은 피자',
            quantity: 2,
            unit: '조각',
            category: '가공식품',
          ),
          InventoryBatch(
            id: 'unknown',
            name: '처음 보는 재료',
            quantity: 1,
            unit: '',
            quantityMode: QuantityMode.status,
          ),
          InventoryBatch(
            id: 'broken-photo',
            name: '사진 없는 긴 이름의 직접 만든 음식',
            quantity: 1,
            unit: '통',
            photoFile: 'missing.png',
          ),
        ]
      : demoInventory(DateTime.now());
  @override
  List<InventoryBatch> get batches => rows;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  testWidgets('capture redesigned production screens', (tester) async {
    await tester.runAsync(loadCaptureFonts);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = _CaptureStore();
    final boundary = GlobalKey();
    Future<void> mount(Widget screen) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: FridgeTheme.light.copyWith(
              appBarTheme: FridgeTheme.light.appBarTheme.copyWith(
                titleTextStyle: FridgeTheme.light.appBarTheme.titleTextStyle
                    ?.copyWith(fontFamily: 'ReviewKorean'),
              ),
              textTheme: FridgeTheme.light.textTheme.apply(
                fontFamily: 'ReviewKorean',
              ),
            ),
            home: screen,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await render.toImage(pixelRatio: 2);
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        const prefix = String.fromEnvironment(
          'CAPTURE_PREFIX',
          defaultValue: 'reform',
        );
        final target = File('docs/screenshots/$prefix-$name.png');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(data!.buffer.asUint8List());
        picture.dispose();
      });
    }

    await mount(HomeScreen(store: store));
    await capture('welcome');
    await tester.ensureVisible(find.bySemanticsLabel('냉장고 문 열기'));
    await tester.tap(find.bySemanticsLabel('냉장고 문 열기'));
    await tester.pumpAndSettle();
    await capture('inventory');
    if (const bool.fromEnvironment('CAPTURE_MIXED')) {
      await tester.drag(
        find.byKey(const PageStorageKey('inventory-browser')),
        const Offset(0, -350),
      );
      await tester.pumpAndSettle();
      await capture('inventory-scrolled');
      await tester.drag(
        find.byKey(const PageStorageKey('inventory-browser')),
        const Offset(0, 1000),
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('inventory-selection-toggle')));
    await tester.pumpAndSettle();
    for (final id in ['tofu', 'milk']) {
      await tester.tap(find.byKey(ValueKey('item-$id')));
      await tester.pumpAndSettle();
    }
    await capture('selection');
    await tester.tap(find.text('선택한 2개 재료로 요리 찾기'));
    await tester.pumpAndSettle();
    await capture('recipes');
    await tester.tap(find.text('장보기').last);
    await tester.pumpAndSettle();
    await capture('shopping');
    await mount(DetailScreen(store: store, batchId: 'tofu', onRecipes: () {}));
    await capture('detail');
    await mount(const BatchForm());
    await capture('registration');
    await mount(
      RecipeScreen(recipe: AiService.demoRecipes.first, store: store),
    );
    await capture('recipe-detail');
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  }, skip: !const bool.fromEnvironment('CAPTURE_DESIGN'));
}
