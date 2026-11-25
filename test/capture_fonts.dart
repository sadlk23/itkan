import 'dart:io';

import 'package:flutter/services.dart';

/// Load test-only fonts from the current platform and Flutter's asset bundle.
Future<void> loadCaptureFonts() async {
  final fonts = [
    ?Platform.environment['ITKAN_TEST_KOREAN_FONT'],
    if (Platform.isWindows)
      "${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/malgun.ttf",
    if (Platform.isMacOS) '/System/Library/Fonts/AppleSDGothicNeo.ttc',
    if (Platform.isLinux)
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  ].map(File.new);
  final font = fonts.where((file) => file.existsSync()).firstOrNull;
  if (font == null) {
    throw StateError('Set ITKAN_TEST_KOREAN_FONT to a Korean font file.');
  }
  final data = ByteData.sublistView(await font.readAsBytes());
  for (final family in ['ReviewKorean', 'Ahem']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}
