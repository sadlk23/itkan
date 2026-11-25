import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/main.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/household_screen.dart';
import 'package:my_fridge/services/household_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/reminder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SnapshotStore extends InventoryStore {
  _SnapshotStore(this.rows);
  final List<InventoryBatch> rows;
  @override
  bool get isInitialized => true;
  @override
  List<InventoryBatch> get activeBatches => rows;
}

void main() {
  testWidgets('Korean OS uses Korean Material date and time controls', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('ko', 'KR')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    SharedPreferences.setMockInitialValues({});
    final store = _SnapshotStore([]);
    addTearDown(store.dispose);
    await tester.pumpWidget(FridgeApp(store: store));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    final labels = MaterialLocalizations.of(context);
    expect(Localizations.localeOf(context).languageCode, 'ko');
    expect(labels.datePickerHelpText, '날짜 선택');
    expect(labels.timePickerDialHelpText, '시간 선택');
    expect(labels.cancelButtonLabel, '취소');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('member edit survives keyboard closing during dialog dismissal', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    SharedPreferences.setMockInitialValues({'household_demo_enabled': true});
    final store = _SnapshotStore([]);
    addTearDown(store.dispose);
    await tester.pumpWidget(MaterialApp(home: HouseholdScreen(store: store)));
    await tester.pumpAndSettle();
    final edit = find.text('구성원 이름 수정 · 2~3인');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '나, 가족',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 270);
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pump();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(ChoiceChip, '가족'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('household_demo_members'), ['나', '가족']);
  });

  test(
    'a refresh keeps a date’s notification ID when earlier dates fall out',
    () {
      final tofu = InventoryBatch(
        id: 'tofu',
        name: '두부',
        quantity: 1,
        unit: '개',
        expiryStatus: ExpiryStatus.actual,
        expiryDate: DateTime(2026, 12, 5),
      );
      final early = expirySchedule([tofu], DateTime(2026, 12, 1));
      final late = expirySchedule([tofu], DateTime(2026, 12, 4, 10));
      expect(late, isNotEmpty);
      for (final row in late) {
        final previous = early.singleWhere((other) => other['at'] == row['at']);
        expect(row['id'], previous['id']);
        expect(row['mode'], 'personal');
      }
      expect(
        expirySchedule([tofu], DateTime(2026, 12, 1), demo: true).first['mode'],
        'demo',
      );
    },
  );
  test(
    'every intake packaging unit survives own sharing export and preview',
    () {
      final store = _SnapshotStore([
        for (final unit in ['개', '팩', '봉', '병', '캔', 'g', 'kg', 'ml', 'L'])
          InventoryBatch(id: unit, name: '재료 $unit', quantity: 1, unit: unit),
      ]);
      addTearDown(store.dispose);
      final sharing = HouseholdService(store);
      final result = sharing.preview(sharing.exportSnapshot());
      expect(result.batches.map((b) => b.unit), store.rows.map((b) => b.unit));
      expect(result.batches.map((b) => b.quantity), everyElement(1));
    },
  );

  test(
    'export refuses incompatible counts instead of emitting unusable data',
    () {
      final store = _SnapshotStore([
        for (var i = 0; i < 201; i++)
          InventoryBatch(id: '$i', name: '재료 $i', quantity: 1, unit: '개'),
      ]);
      addTearDown(store.dispose);
      final sharing = HouseholdService(store);
      expect(sharing.exportSnapshot, throwsFormatException);
      store.rows.removeLast();
      expect(sharing.preview(sharing.exportSnapshot()).batches, hasLength(200));
    },
  );

  test(
    'snapshot size limit measures UTF8 bytes and export validates payload',
    () {
      final store = _SnapshotStore([
        InventoryBatch(id: 'one', name: '두부', quantity: 1, unit: '개'),
      ]);
      addTearDown(store.dispose);
      final sharing = HouseholdService(store);
      final data = jsonDecode(sharing.exportSnapshot()) as Map<String, dynamic>;
      data['padding'] = List.filled(100001, '한').join();
      final oversized = jsonEncode(data);
      expect(oversized.length, lessThan(300000));
      expect(() => sharing.preview(oversized), throwsFormatException);
    },
  );

  test(
    'future expiry includes its whole reminder interval without app reopen',
    () {
      final now = DateTime(2026, 11, 9, 10);
      final rows = expirySchedule([
        InventoryBatch(
          id: 'future',
          name: '두부',
          quantity: 1,
          unit: '개',
          expiryDate: DateTime(2026, 11, 30),
          expiryStatus: ExpiryStatus.actual,
        ),
      ], now);
      expect(rows, hasLength(5));
      expect(
        DateTime.fromMillisecondsSinceEpoch(rows.first['at'] as int),
        DateTime(2026, 11, 27, 9),
      );
      expect(
        DateTime.fromMillisecondsSinceEpoch(rows.last['at'] as int),
        DateTime(2026, 12, 1, 9),
      );
    },
  );

  test(
    'far dates remain finite and same-day reminders are grouped and ordered',
    () {
      final now = DateTime(2026, 11, 9, 10);
      final rows = expirySchedule(
        [
          for (var i = 0; i < 500; i++)
            InventoryBatch(
              id: '$i',
              name: '재료 $i',
              quantity: 1,
              unit: '개',
              expiryDate: DateTime(2099, 1, 1),
              expiryStatus: ExpiryStatus.actual,
            ),
        ],
        now,
        days: 7,
      );
      expect(rows, hasLength(9));
      expect(rows.first['title'], contains('500개'));
      expect(rows.map((r) => r['id']).toSet(), hasLength(9));
      final times = rows.map((r) => r['at'] as int).toList();
      expect(times, orderedEquals([...times]..sort()));
      expect(rows.first['body'].toString().split(', '), hasLength(5));
    },
  );

  test('consumed and unknown batches never create a future reminder', () {
    final rows = expirySchedule([
      InventoryBatch(
        id: 'zero',
        name: '없음',
        quantity: 0,
        unit: '개',
        expiryDate: DateTime(2027, 1, 1),
        expiryStatus: ExpiryStatus.actual,
      ),
      InventoryBatch(
        id: 'unknown',
        name: '미상',
        quantity: 1,
        unit: '개',
        expiryDate: DateTime(2027, 1, 1),
        expiryStatus: ExpiryStatus.unknown,
      ),
    ], DateTime(2026, 11, 9));
    expect(rows, isEmpty);
  });
}
