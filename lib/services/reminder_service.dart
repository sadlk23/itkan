import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';
import 'inventory_store.dart';

List<Map<String, Object>> expirySchedule(
  List<InventoryBatch> batches,
  DateTime now, {
  int days = 3,
  int hour = 9,
  int minute = 0,
  bool demo = false,
}) {
  if (days < 0 ||
      days > 365 ||
      hour < 0 ||
      hour > 23 ||
      minute < 0 ||
      minute > 59) {
    throw ArgumentError('알림 시각과 기한 범위를 확인해주세요.');
  }
  // Derive finite event dates from inventory, not a rolling calendar window.
  // A batch expiring months from now is scheduled without reopening the app.
  final grouped = <int, List<InventoryBatch>>{};
  for (final batch in batches) {
    if (!batch.active ||
        batch.expiryDate == null ||
        batch.expiryStatus == ExpiryStatus.unknown) {
      continue;
    }
    final expiry = batch.expiryDate!;
    for (var offset = -days; offset <= 1; offset++) {
      final date = DateTime(
        expiry.year,
        expiry.month,
        expiry.day + offset,
        hour,
        minute,
      );
      if (!date.isAfter(now)) continue;
      grouped.putIfAbsent(date.millisecondsSinceEpoch, () => []).add(batch);
    }
  }
  final times = grouped.keys.toList()..sort();
  final result = <Map<String, Object>>[];
  for (final at in times) {
    final due = grouped[at]!;
    final date = DateTime.fromMillisecondsSinceEpoch(at);
    final day =
        DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    result.add({
      'id': 100000 + day,
      'at': at,
      'mode': demo ? 'demo' : 'personal',
      'title': '${demo ? '[샘플] ' : ''}소비기한 확인 · ${due.length}개',
      'body': due
          .take(5)
          .map(
            (b) =>
                '${b.name}${b.expiryStatus == ExpiryStatus.estimated ? '(추정)' : ''}',
          )
          .join(', '),
    });
  }
  return result;
}

class ReminderService {
  static const channel = MethodChannel('eatkan/device');

  static Future<void> clearPostedNotifications(String dataMode) async {
    try {
      await channel.invokeMethod<void>('clearPostedNotifications', dataMode);
    } on MissingPluginException {
      // Desktop and widget-test hosts do not have Android notifications.
    }
  }

  final InventoryStore store;
  ReminderService(this.store);
  Timer? _timer;
  Future<void> _queue = Future.value();
  bool _disposed = false;
  void attach() {
    store.addListener(refresh);
    refresh();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    store.removeListener(refresh);
  }

  void refresh() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), () => sync());
  }

  Future<void> sync({bool reportErrors = false}) {
    final operation = _queue.then((_) async {
      if (_disposed) return;
      final p = await SharedPreferences.getInstance();
      final enabled = p.getBool('reminders_enabled') ?? false;
      final rows = enabled
          ? expirySchedule(
              store.batches,
              DateTime.now(),
              days: p.getInt('reminders_days') ?? 3,
              hour: p.getInt('reminders_hour') ?? 9,
              minute: p.getInt('reminders_minute') ?? 0,
              demo: store.isDemo,
            )
          : <Map<String, Object>>[];
      try {
        await channel.invokeMethod<void>('scheduleNotifications', rows);
      } on PlatformException {
        if (reportErrors) rethrow;
        /* Settings can retry. */
      } on MissingPluginException {
        if (reportErrors) rethrow;
        /* Unsupported test/desktop host. */
      }
    });
    // A failed preferences read or platform request must not poison later syncs.
    _queue = operation.catchError((Object _) {});
    return reportErrors ? operation : _queue;
  }
}
