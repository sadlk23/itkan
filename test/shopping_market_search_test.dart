import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/shopping_screen.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/shopping_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const ingredient = '새송이 버섯 & 두부+#';
  const device = MethodChannel('eatkan/device');
  const googleAction = 'Google에서 쿠팡 상품 찾기';
  const copyAction = '재료 이름 복사';
  const installAction = '쿠팡 앱 설치 페이지';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late InventoryStore inventory;
  late ShoppingStore shopping;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    inventory = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await inventory.initialize();
    await inventory.setDemoMode(false);
    await inventory.add(
      InventoryBatch(id: 'sample-onion', name: '양파', quantity: 2, unit: '개'),
    );
    shopping = ShoppingStore(inventory: inventory);
    await shopping.initialize();
    await shopping.addManual(ingredient, quantity: 275, unit: 'g');
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(device, null);
    shopping.dispose();
    await inventory.close();
    inventory.dispose();
  });

  List<Object?> mockCoupangApp(bool Function() open) {
    final queries = <Object?>[];
    messenger.setMockMethodCallHandler(device, (call) async {
      if (call.method != 'openCoupangSearch') return null;
      queries.add(call.arguments);
      return open();
    });
    return queries;
  }

  List<Object?> recordClipboardWrites() {
    final copied = <Object?>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add(call.arguments);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return copied;
  }

  Future<void> mount(
    WidgetTester tester,
    Future<bool> Function(Uri) open,
  ) async {
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShoppingScreen(
            store: inventory,
            onIntake: () => fail('A marketplace search must not start intake'),
            openShoppingUrl: open,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chooseStore(WidgetTester tester) async {
    final button = find.text('쇼핑몰에서 찾기');
    await tester.scrollUntilVisible(
      button,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('쿠팡'), findsOneWidget);
    expect(find.text('네이버쇼핑'), findsOneWidget);
    expect(find.text('컬리'), findsOneWidget);
    expect(
      find
          .textContaining(ingredient)
          .evaluate()
          .any((element) => ModalRoute.of(element)?.isCurrent == true),
      isTrue,
      reason: 'Show which ingredient will be sent before opening the shop',
    );
  }

  Future<void> expectSameData({bool purchased = false}) async {
    await shopping.reload();
    final item = shopping.items.single;
    expect(item.name, ingredient);
    expect(item.quantity, 275);
    expect(item.purchased, purchased);
    expect(item.intakeLinked, isFalse);
    expect(inventory.batches.single.id, 'sample-onion');
    expect(inventory.batches.single.quantity, 2);
    expect(inventory.history, hasLength(1));
  }

  Future<void> chooseCoupang(WidgetTester tester) async {
    await chooseStore(tester);
    await tester.tap(find.text('쿠팡'));
    await tester.pumpAndSettle();
  }

  const destinations = [
    ('쿠팡', 'www.coupang.com', '/np/search', 'q'),
    ('네이버쇼핑', 'search.shopping.naver.com', '/ns/search', 'query'),
    ('컬리', 'www.kurly.com', '/search', 'sword'),
  ];
  for (final (name, host, path, queryKey) in destinations) {
    testWidgets(
      'opens $name with just the selected ingredient',
      (tester) async {
        final nativeQueries = mockCoupangApp(() => true);
        final opened = <Uri>[];
        await mount(tester, (uri) async {
          opened.add(uri);
          return true;
        });
        await chooseStore(tester);
        expect(opened, isEmpty);
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();

        final url = Uri.parse(opened.single.toString());
        expect(url.origin, 'https://$host');
        expect(url.path, path);
        expect(url.queryParametersAll, {
          queryKey: [ingredient],
        });
        expect(url.fragment, isEmpty);
        expect(nativeQueries, isEmpty);
        await expectSameData();
      },
      variant: TargetPlatformVariant.only(
        name == '쿠팡' ? TargetPlatform.iOS : TargetPlatform.android,
      ),
    );
  }

  testWidgets('opens the installed Coupang app with only the ingredient', (
    tester,
  ) async {
    final queries = mockCoupangApp(() => true);
    final opened = <Uri>[];
    await mount(tester, (uri) async {
      opened.add(uri);
      return true;
    });
    await chooseCoupang(tester);
    expect(queries, [ingredient]);
    expect(opened, isEmpty);
    expect(find.text(googleAction), findsNothing);
    await expectSameData();
  });

  testWidgets('an explicit choice opens Coupang results or its Play listing', (
    tester,
  ) async {
    final queries = mockCoupangApp(() => false);
    final opened = <Uri>[];
    await mount(tester, (uri) async {
      opened.add(uri);
      return true;
    });
    await chooseCoupang(tester);
    expect(queries, [ingredient]);
    expect(opened, isEmpty);
    expect(find.text(copyAction), findsOneWidget);
    expect(find.text(installAction), findsOneWidget);

    await tester.tap(find.text(googleAction));
    await tester.pumpAndSettle();
    final search = Uri.parse(opened.single.toString());
    expect(search.origin, 'https://www.google.com');
    expect(search.path, '/search');
    expect(search.queryParametersAll, {
      'q': ['site:coupang.com/vp/products $ingredient'],
    });
    expect(search.fragment, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(copyAction), findsOneWidget);

    await tester.tap(find.text(installAction));
    await tester.pumpAndSettle();
    expect(opened, [
      search,
      Uri.parse(
        'https://play.google.com/store/apps/details?id=com.coupang.mobile',
      ),
    ]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(googleAction), findsNothing);
    expect(queries, [ingredient]);
    await expectSameData();
  });

  testWidgets('copies the Coupang ingredient link without opening a browser', (
    tester,
  ) async {
    final queries = mockCoupangApp(() => false);
    final opened = <Uri>[];
    await mount(tester, (uri) async {
      opened.add(uri);
      return true;
    });
    await chooseCoupang(tester);
    final copied = recordClipboardWrites();
    await tester.tap(find.text('쿠팡 검색 링크 복사'));
    await tester.pumpAndSettle();

    final clipboardData = copied.single as Map<Object?, Object?>;
    final link = Uri.parse(clipboardData['text'] as String);
    expect(link.origin, 'https://www.coupang.com');
    expect(link.path, '/np/search');
    expect(link.queryParametersAll, {
      'q': [ingredient],
    });
    expect(link.fragment, isEmpty);
    expect(find.text('쿠팡 검색 링크를 복사했어요.'), findsOneWidget);
    expect(queries, [ingredient]);
    expect(opened, isEmpty);
    await expectSameData();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final throws in [false, true]) {
    final failure = throws ? 'exception' : 'false result';
    testWidgets('Coupang $failure leaves an inline error and usable copy', (
      tester,
    ) async {
      final queries = mockCoupangApp(() {
        if (throws) throw PlatformException(code: 'app_unavailable');
        return false;
      });
      final opened = <Uri>[];
      await shopping.setPurchased(shopping.items.single.id, true);
      await mount(tester, (uri) async {
        opened.add(uri);
        if (throws) throw StateError('test browser unavailable');
        return false;
      });
      await chooseCoupang(tester);
      expect(queries, [ingredient]);
      expect(opened, isEmpty);
      await tester.tap(find.text(googleAction));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.textContaining('열지 못했어요'),
        ),
        findsOneWidget,
      );

      final copied = recordClipboardWrites();
      await tester.tap(find.text(copyAction));
      await tester.pumpAndSettle();
      expect(copied, [
        {'text': ingredient},
      ]);
      expect(find.text('재료 이름을 복사했어요.'), findsOneWidget);
      expect(opened, hasLength(1));
      expect(tester.takeException(), isNull);
      await expectSameData(purchased: true);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  const carts = {
    '쿠팡': 'https://cart.coupang.com/cartView.pang',
    '네이버쇼핑': 'https://shopping.naver.com/cart',
    '컬리': 'https://www.kurly.com/cart',
  };
  for (final cart in carts.entries) {
    testWidgets('opens the ${cart.key} cart without sending shopping items', (
      tester,
    ) async {
      await shopping.setPurchased(shopping.items.single.id, true);
      final nativeQueries = mockCoupangApp(() => true);
      final opened = <Uri>[];
      await mount(tester, (uri) async {
        opened.add(uri);
        return true;
      });
      await tester.tap(find.text('쇼핑몰 장바구니 열기'));
      await tester.pumpAndSettle();
      final picker = find.byType(BottomSheet);
      expect(
        find.descendant(of: picker, matching: find.text('쇼핑몰 장바구니 열기')),
        findsOneWidget,
      );
      expect(opened, isEmpty);
      await tester.tap(
        find.descendant(of: picker, matching: find.text(cart.key)),
      );
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse(cart.value)]);
      expect(nativeQueries, isEmpty);
      await expectSameData(purchased: true);
    });
  }

  testWidgets('cancelling keeps the existing purchase check', (tester) async {
    await shopping.setPurchased(shopping.items.single.id, true);
    final opened = <Uri>[];
    await mount(tester, (uri) async {
      opened.add(uri);
      return true;
    });
    await chooseStore(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('컬리'), findsNothing);
    expect(opened, isEmpty);
    await expectSameData(purchased: true);
  });

  for (final throws in [false, true]) {
    final failure = throws ? 'exception' : 'false result';
    testWidgets('reports a launcher $failure without changing purchases', (
      tester,
    ) async {
      final opened = <Uri>[];
      await mount(tester, (uri) async {
        opened.add(uri);
        if (throws) throw StateError('test launcher unavailable');
        return false;
      });
      await chooseStore(tester);
      await tester.tap(find.text('컬리'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining(RegExp('열 수 없|열지 못|열리지 않|실패')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await expectSameData();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
