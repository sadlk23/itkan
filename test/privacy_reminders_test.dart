import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/receipt_privacy.dart';
import 'package:my_fridge/services/reminder_service.dart';
import 'package:my_fridge/screens/intake_screen.dart';

void main() {
  test(
    'receipt hides contact and payment data before candidate extraction',
    () {
      final result = redactReceipt(
        '두부 3000\n전화 010-1234-5678\n주소 서울시 어느길\n1234567890123456\nabc@example.com\n우유 2000',
      );
      expect(result, isNot(contains('010-1234')));
      expect(result, isNot(contains('서울시')));
      expect(result, isNot(contains('1234567890123456')));
      expect(receiptCandidates(result).map((b) => b.name), ['두부', '우유']);
    },
  );
  test(
    'schedule excludes unknown and empty, labels estimated dates and sample',
    () {
      final now = DateTime(2026, 11, 6, 10);
      final rows = expirySchedule(
        [
          InventoryBatch(
            id: 'a',
            name: '두부',
            quantity: 1,
            unit: '개',
            expiryDate: DateTime(2026, 11, 8),
            expiryStatus: ExpiryStatus.estimated,
          ),
          InventoryBatch(id: 'b', name: '우유', quantity: 1, unit: '개'),
          InventoryBatch(
            id: 'c',
            name: '없음',
            quantity: 0,
            unit: '개',
            expiryDate: DateTime(2026, 11, 8),
            expiryStatus: ExpiryStatus.actual,
          ),
        ],
        now,
        demo: true,
      );
      expect(rows, isNotEmpty);
      expect(
        DateTime.fromMillisecondsSinceEpoch(rows.first['at'] as int),
        DateTime(2026, 11, 7, 9),
      );
      expect(rows.first['body'], '두부(추정)');
      expect(rows.first['title'], contains('[샘플]'));
      expect(rows.length, 3);
    },
  );
}
