import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/models/recipe.dart';
import 'package:my_fridge/screens/batch_form.dart';
import 'package:my_fridge/screens/recipe_screen.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _recipe = Recipe(
  id: 'status-recipe',
  title: '소금 요리',
  source: 'ai',
  servings: 1,
  minutes: 5,
  ingredients: [RecipeIngredient(name: '소금', quantity: 1, unit: 'g')],
  steps: ['조리해요'],
  generatedAt: DateTime(2026),
);

class _Store extends InventoryStore {
  _Store(this.status);
  final bool status;
  final Map<String, dynamic> saved = {
    'id': 'session',
    'recipeId': _recipe.id,
    'recipe': _recipe.toJson(),
    'step': 0,
    'status': 'awaitingUsage',
    'usageApplied': false,
  };
  Map<String, double>? applied;
  @override
  List<InventoryBatch> get batches => [
    InventoryBatch(
      id: 'salt',
      name: '소금',
      quantity: 10,
      unit: 'g',
      quantityMode: status ? QuantityMode.status : QuantityMode.measured,
    ),
  ];
  @override
  List<InventoryBatch> get activeBatches => batches;
  @override
  Map<String, dynamic>? get cookingSession => saved;
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
    saved.clear();
    saved.addAll(session!);
  }

  @override
  Future<void> applyCookingUsage(
    String sessionId,
    Map<String, double> usage, {
    Map<String, int>? expectedRevisions,
  }) async {
    applied = usage;
    saved['status'] = 'completed';
  }
}

Future<void> _openForm(WidgetTester tester, {InventoryBatch? initial}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<InventoryBatch>(
                builder: (_) => BatchForm(initial: initial),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => true,
        );
  });
  testWidgets('clean registration exits without asking', (tester) async {
    await _openForm(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BatchForm), findsNothing);
    expect(find.text('작성 중인 내용을 버릴까요?'), findsNothing);
  });
  testWidgets('quantity-only edit is protected and cancel preserves draft', (
    tester,
  ) async {
    await _openForm(
      tester,
      initial: InventoryBatch(id: 'x', name: '두부', quantity: 1, unit: '개'),
    );
    await tester.enterText(find.byType(TextFormField).at(1), '3');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('작성 중인 내용을 버릴까요?'), findsOneWidget);
    await tester.tap(find.text('계속 작성'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).at(1))
          .controller!
          .text,
      '3',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('버리고 나가기'));
    await tester.pumpAndSettle();
    expect(find.byType(BatchForm), findsNothing);
  });
  for (final status in [true, false]) {
    testWidgets(
      'zero deduction completion status=$status requires explicit confirmation',
      (tester) async {
        final store = _Store(status);
        addTearDown(store.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: RecipeScreen(recipe: _recipe, store: store, autoResume: true),
          ),
        );
        await tester.pumpAndSettle();
        if (!status) {
          await tester.enterText(find.byType(TextField), '0');
          await tester.pump();
        } else {
          expect(find.textContaining('상태로 관리 중'), findsOneWidget);
        }
        await tester.ensureVisible(find.text('재고 차감 없이 조리 완료'));
        await tester.tap(find.text('재고 차감 없이 조리 완료'));
        await tester.pumpAndSettle();
        expect(store.applied, isNull);
        await tester.tap(find.text('사용량 다시 확인'));
        await tester.pumpAndSettle();
        expect(store.applied, isNull);
        await tester.tap(find.text('재고 차감 없이 조리 완료'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('차감 없이 완료'));
        await tester.pumpAndSettle();
        expect(store.applied, isEmpty);
        expect(store.saved['status'], 'completed');
      },
    );
  }
  test(
    'empty usage really completes SQLite session without changing stock',
    () async {
      final store = InventoryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      await store.initialize();
      final before = store.batches.map((b) => b.toJson()).toList();
      await store.saveCookingSession({
        'id': 'empty',
        'status': 'awaitingUsage',
        'recipe': _recipe.toJson(),
      });
      await store.applyCookingUsage('empty', {});
      expect(store.cookingSession!['status'], 'completed');
      expect(store.batches.map((b) => b.toJson()).toList(), before);
      await store.close();
      store.dispose();
    },
  );
}
