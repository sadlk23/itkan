import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/app_theme.dart';
import 'package:my_fridge/screens/guide_screen.dart';
import 'package:my_fridge/services/inventory_store.dart';

void main() {
  testWidgets(
    'guide without selected ingredient supports large text and local rules',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = InventoryStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: FridgeTheme.light,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: GuideScreen(store: store),
          ),
        ),
      );
      expect(find.text('재료 보관·배출 안내'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(DropdownButtonFormField<String>),
        250,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('서울특별시').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.textContaining('실제 배출 전에는'), 250);
      expect(find.textContaining('실제 배출 전에는'), findsOneWidget);
      expect(store.history, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
