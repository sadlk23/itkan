import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CoupangSearchOptions extends StatefulWidget {
  const CoupangSearchOptions({
    super.key,
    required this.ingredient,
    required this.searchLink,
    required this.openPage,
  });

  final String ingredient;
  final Uri searchLink;
  final Future<bool> Function(Uri) openPage;

  @override
  State<CoupangSearchOptions> createState() => _CoupangSearchOptionsState();
}

class _CoupangSearchOptionsState extends State<CoupangSearchOptions> {
  bool opening = false;
  String? feedback;

  Future<void> open(Uri uri) async {
    if (opening) return;
    setState(() {
      opening = true;
      feedback = null;
    });
    final opened = await widget.openPage(uri);
    if (!mounted) return;
    setState(() {
      opening = false;
      if (!opened) feedback = '페이지를 열지 못했어요. 검색 링크를 복사해 사용할 수 있어요.';
    });
  }

  Future<void> copy(String text, String message) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on Exception {
      message = '복사하지 못했어요. 다시 시도해주세요.';
    }
    if (mounted) setState(() => feedback = message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${widget.ingredient} · 쿠팡 검색', style: theme.titleLarge),
            const SizedBox(height: 8),
            const Text('쿠팡 앱을 열 수 없어요. 웹 검색 결과에서 상품을 누르면 쿠팡이 접속을 제한할 수 있어요.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.search),
              label: const Text('Google에서 쿠팡 상품 찾기'),
              onPressed: opening
                  ? null
                  : () => open(
                      Uri.https('www.google.com', '/search', {
                        'q':
                            'site:coupang.com/vp/products ${widget.ingredient}',
                      }),
                    ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: const Text('쿠팡 검색 링크 복사'),
              subtitle: const Text('다른 기기에서 검색을 이어갈 수 있어요.'),
              onTap: () =>
                  copy(widget.searchLink.toString(), '쿠팡 검색 링크를 복사했어요.'),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.content_copy, size: 18),
                  label: const Text('재료 이름 복사'),
                  onPressed: () => copy(widget.ingredient, '재료 이름을 복사했어요.'),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('쿠팡 앱 설치 페이지'),
                  onPressed: opening
                      ? null
                      : () => open(
                          Uri.https('play.google.com', '/store/apps/details', {
                            'id': 'com.coupang.mobile',
                          }),
                        ),
                ),
              ],
            ),
            if (feedback != null)
              Semantics(liveRegion: true, child: Text(feedback!)),
          ],
        ),
      ),
    );
  }
}
