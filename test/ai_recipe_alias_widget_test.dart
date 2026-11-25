import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/recipe_screen.dart';
import 'package:my_fridge/services/ai_service.dart';
import 'package:my_fridge/services/inventory_store.dart';

class _EggInventory extends InventoryStore {
  @override
  List<InventoryBatch> get batches => [
    InventoryBatch(id: 'egg', name: '달걀', quantity: 1, unit: '개'),
  ];
  @override
  List<InventoryBatch> get activeBatches => batches;
}

void main() {
  testWidgets(
    'canonicalized AI egg ingredient uses actual stock for shortage',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter_tts'),
            (_) async => 1,
          );
      final store = _EggInventory();
      final ai = AiService(
        baseUrl: 'https://example.invalid/ai',
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'recipes': [
                  {
                    ...AiService.demoRecipes.first.toJson(),
                    'ingredients': [
                      {'name': '계란', 'quantity': 2, 'unit': '개'},
                    ],
                  },
                ],
              }),
            ),
            200,
          ),
        ),
      );
      final recipes = await ai.recommend(
        store.activeBatches,
        selectedBatchIds: {'egg'},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RecipeScreen(recipe: recipes.single, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('달걀'), findsOneWidget);
      expect(find.text('1개 부족'), findsOneWidget);
      expect(find.text('보유 재료 없음'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      ai.dispose();
      store.dispose();
    },
  );
}
