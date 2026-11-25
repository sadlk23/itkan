import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'design/app_theme.dart';
import 'screens/assistant_screen.dart' show OpenShoppingListIntent;
import 'screens/home_screen.dart';
import 'services/inventory_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FridgeApp());
}

class FridgeApp extends StatefulWidget {
  const FridgeApp({super.key, this.store});
  final InventoryStore? store;
  @override
  State<FridgeApp> createState() => _FridgeAppState();
}

class _FridgeAppState extends State<FridgeApp> {
  final homeKey = GlobalKey<HomeScreenState>();
  late final store = widget.store ?? InventoryStore();
  late Future<void> ready = store.isInitialized
      ? Future.value()
      : store.initialize();
  @override
  void dispose() {
    if (widget.store == null) store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '잇칸 · AI 주방 관리',
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('ko', 'KR'), Locale('en', 'US')],
    debugShowCheckedModeBanner: false,
    theme: FridgeTheme.light,
    builder: (context, child) => Actions(
      actions: {
        OpenShoppingListIntent: CallbackAction<OpenShoppingListIntent>(
          onInvoke: (_) {
            homeKey.currentState?.openShoppingList();
            return null;
          },
        ),
      },
      child: child!,
    ),
    home: FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.storage_rounded, size: 48),
                      const Text('저장 공간을 열지 못했어요.'),
                      const Text('기존 데이터를 지우지 않았습니다. 다시 시도해주세요.'),
                      FilledButton(
                        onPressed: () =>
                            setState(() => ready = store.initialize()),
                        child: const Text('다시 시도'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return HomeScreen(key: homeKey, store: store);
      },
    ),
  );
}
