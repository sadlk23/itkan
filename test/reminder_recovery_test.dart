import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/screens/reminder_settings_screen.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/reminder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late InventoryStore store;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = InventoryStore();
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(ReminderService.channel, null);
    store.dispose();
  });

  test('failed schedule is reported and next sync can recover', () async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(ReminderService.channel, (call) async {
      if (call.method == 'scheduleNotifications' && ++attempts == 1) {
        throw PlatformException(code: 'schedule');
      }
      return null;
    });
    final service = ReminderService(store);
    await expectLater(
      service.sync(reportErrors: true),
      throwsA(isA<PlatformException>()),
    );
    await service.sync(reportErrors: true);
    expect(attempts, 2);
    service.dispose();
  });

  testWidgets('return from settings refreshes permission and saved days', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reminders_days': 7});
    var allowed = false;
    messenger.setMockMethodCallHandler(ReminderService.channel, (call) async {
      return call.method == 'notificationPermission' ? allowed : null;
    });
    await tester.pumpWidget(
      MaterialApp(home: ReminderSettingsScreen(store: store)),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byType(DropdownButtonFormField<int>),
          )
          .initialValue,
      7,
    );
    expect(find.text('기기 알림 허용됨'), findsNothing);
    allowed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('기기 알림 허용됨'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed enable offers retry and retries platform schedule', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var attempts = 0;
    messenger.setMockMethodCallHandler(ReminderService.channel, (call) async {
      if (call.method == 'scheduleNotifications') {
        if (++attempts == 1) throw PlatformException(code: 'schedule');
        return null;
      }
      return true;
    });
    await tester.pumpWidget(
      MaterialApp(home: ReminderSettingsScreen(store: store)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('알림 예약 다시 시도'), findsOneWidget);
    await tester.ensureVisible(find.text('알림 예약 다시 시도'));
    await tester.tap(find.text('알림 예약 다시 시도'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('알림 예약 다시 시도'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
