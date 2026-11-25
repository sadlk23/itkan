import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Only this digest is kept for duplicate detection. Layout whitespace is ignored.
String receiptFingerprint(String text) => sha256
    .convert(utf8.encode(text.replaceAll(RegExp(r'\s+'), '').toLowerCase()))
    .toString();

/// Redact sensitive receipt lines before displaying candidate text.
/// OCR stays on device; this function does not send text to a server.
String redactReceipt(String raw) => raw
    .split('\n')
    .map((line) {
      if (RegExp(
            r'주소|배송지|수령인|전화|연락처|주문번호|승인번호|카드번호|고객명|[가-힣]+(?:로|길)\s*\d+|[가-힣]+동\s*\d+',
          ).hasMatch(line) ||
          RegExp(
            r'\b\d{2,4}[- ]\d{3,4}[- ]\d{4}\b|\b\d{12,19}\b|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}',
          ).hasMatch(line)) {
        return '[개인정보 가림]';
      }
      return line;
    })
    .join('\n');
