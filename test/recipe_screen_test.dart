import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/screens/recipe_screen.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/shopping_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CookingStore extends InventoryStore {
  _CookingStore(this.saved, {this.rows});
  final List<InventoryBatch>? rows;
  Map<String, dynamic> saved;
  @override
  Map<String, dynamic>? get cookingSession => saved;
  @override
  List<InventoryBatch> get batches => rows ?? demoInventory(DateTime.now());
  @override
  Future<void> saveCookingSessionIfCurrent(
    Map<String, dynamic> next, {
    required String? expectedSessionId,
  }) async {
    if (cookingSession?['id'] != expectedSessionId) {
      throw StateError('다른 조리 세션');
    }
    await saveCookingSession(next);
  }

  @override
  Future<void> saveCookingSession(Map<String, dynamic>? session) async {
    saved = Map<String, dynamic>.from(session!);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => call.method == 'getDefaultEngine' ? 'test-engine' : 1,
        );
  });
  sqfliteFfiInit();
  for (final autoResume in [false, true]) {
    testWidgets(
      'resume $autoResume restores awaiting usage and saved recipe snapshot',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final original = AiService.demoRecipes.first;
        final changed = Recipe.fromJson({
          ...original.toJson(),
          'title': '나중에 바뀐 추천',
          'steps': ['새로운 단계'],
        });
        final store = _CookingStore({
          'id': 'session',
          'recipeId': original.id,
          'recipe': original.toJson(),
          'step': original.steps.length - 1,
          'status': 'awaitingUsage',
          'usageApplied': false,
        });
        addTearDown(store.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: RecipeScreen(
              recipe: changed,
              store: store,
              autoResume: autoResume,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (!autoResume) {
          await tester.ensureVisible(find.text('저장된 조리 이어하기'));
          await tester.tap(find.text('저장된 조리 이어하기'));
          await tester.pumpAndSettle();
        }
        expect(find.text('사용량 확인'), findsOneWidget);
        expect(find.text(original.title), findsOneWidget);
        expect(store.saved['status'], 'awaitingUsage');
        expect((store.saved['recipe'] as Map)['title'], original.title);
        expect(store.saved['usageApplied'], false);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'selected purchase batch is allocated before earlier expiry stock',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = Recipe.fromJson({
        ...AiService.demoRecipes.first.toJson(),
        'preferredBatchIds': ['chosen-tofu'],
      });
      final now = DateTime.now();
      final store = _CookingStore(
        {
          'id': 'chosen-session',
          'recipeId': original.id,
          'recipe': original.toJson(),
          'step': 3,
          'status': 'awaitingUsage',
          'usageApplied': false,
        },
        rows: [
          InventoryBatch(
            id: 'old-tofu',
            name: '두부',
            quantity: 300,
            unit: 'g',
            expiryDate: now,
            expiryStatus: ExpiryStatus.actual,
          ),
          InventoryBatch(
            id: 'chosen-tofu',
            name: '두부',
            quantity: 200,
            unit: 'g',
            expiryDate: now.add(const Duration(days: 3)),
            expiryStatus: ExpiryStatus.actual,
          ),
        ],
      );
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RecipeScreen(recipe: original, store: store, autoResume: true),
        ),
      );
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields.first.controller!.text, '150');
      expect(fields.last.controller!.text, '0');
      expect(find.textContaining('선택한 묶음'), findsOneWidget);
      expect(Recipe.fromJson(original.toJson()).preferredBatchIds, [
        'chosen-tofu',
      ]);
    },
  );

  testWidgets('sending same recipe shortage twice replaces its contribution', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory dir;
    late InventoryStore store;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('recipe_ui_');
      store = InventoryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${dir.path}/test.db',
      );
      await store.initialize();
      await store.applyUsage({'tofu': 250});
    });
    addTearDown(() async {
      await store.close();
      store.dispose();
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: RecipeScreen(recipe: AiService.demoRecipes.first, store: store),
      ),
    );
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('부족한 재료 장보기에 보내기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인하고 반영'));
      await tester.pumpAndSettle();
    }
    final shopping = ShoppingStore(inventory: store);
    await shopping.initialize();
    final items = shopping.items;
    expect(items.length, 1);
    expect(items.single.name, '두부');
    expect(items.single.quantity, 100.0);
    expect(items.single.purchased, false);
    shopping.dispose();
    expect(store.batches.firstWhere((b) => b.id == 'tofu').quantity, 50);
  });
}
