import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/inventory_store.dart';
import '../widgets/common.dart';

class GuideScreen extends StatefulWidget {
  const GuideScreen({
    super.key,
    required this.store,
    this.batchId,
    this.itemName,
    this.onRecipes,
  });
  final InventoryStore store;
  final String? batchId, itemName;
  final VoidCallback? onRecipes;
  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  String region = '지역 선택', part = '양파 껍질';
  Future<void> open(String url) async {
    try {
      if (!await launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          ) &&
          mounted) {
        inform(context, '원문을 열지 못했어요. 연결 상태를 확인해주세요.');
      }
    } catch (_) {
      if (mounted) inform(context, '원문을 열지 못했어요.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${widget.itemName ?? '재료'} 보관·배출 안내')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('제품 표시부터 확인해요', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        const InfoBox(
          '냉장·냉동 제품은 구입 후 빠르게 옮기고 제품에 적힌 보관 조건을 지켜주세요. 개봉 제품은 밀폐 보관하고 기한 내 빨리 사용하세요.',
        ),
        const Text(
          '제품마다 조건이 달라 다른 제품의 소비기한을 그대로 적용하지 않습니다. 날짜나 사진만으로 섭취 안전을 판단하지 않아요.',
        ),
        source(
          '식품의약품안전처 · 전국',
          'Q&A로 알아보는 소비기한 표시제 ②',
          'https://www.korea.kr/news/policyNewsView.do?newsId=148911130',
        ),
        if (widget.onRecipes != null)
          OutlinedButton.icon(
            onPressed: widget.onRecipes,
            icon: const Icon(Icons.restaurant),
            label: const Text('이 재료로 요리 찾기'),
          ),
        const Divider(height: 36),
        Text('버리는 부분을 구분해요', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: region,
          decoration: const InputDecoration(labelText: '배출 지역'),
          items: [
            '지역 선택',
            '서울특별시',
            '다른 지역',
          ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
          onChanged: (v) => setState(() => region = v!),
        ),
        const SizedBox(height: 12),
        if (region == '서울특별시') ...[
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: part,
            decoration: const InputDecoration(labelText: '확인할 부분'),
            items: [
              '양파 껍질',
              '달걀 껍데기',
              '대파 뿌리',
              '닭 뼈',
              '그 외',
            ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
            onChanged: (v) => setState(() => part = v!),
          ),
          const SizedBox(height: 12),
          InfoBox(
            part == '그 외'
                ? '이 부분에 대한 분류는 준비되지 않았어요. 거주지 자치구 안내를 확인해주세요.'
                : '$part: 아래 서울시 표준안 자료에서는 일반쓰레기로 분류합니다. 식재료 전체가 아니라 선택한 부분에 대한 안내예요. 실제 배출 전에는 거주지 자치구의 최신 안내를 확인해주세요.',
          ),
          source(
            '서울특별시 · 서울 지역 표준안',
            '양파껍질·고추씨=일반쓰레기, 서울 분리배출 기준 통일',
            'https://mediahub.seoul.go.kr/archives/2004122',
          ),
        ] else
          const InfoBox(
            '지역별로 배출 기준이 다를 수 있어요. 현재 준비된 공식 요약은 서울 지역입니다. 다른 지역은 거주지 지자체 안내를 확인해주세요.',
          ),
        const Text('안내를 읽는 것만으로 재고가 바뀌지 않습니다. 사용·폐기는 재료 상세에서 양을 확인한 뒤 기록해주세요.'),
      ],
    ),
  );
  Widget source(String institution, String title, String url) => Card(
    child: ListTile(
      title: Text(title),
      subtitle: Text('$institution\n자료 확인: 2026-11-06 · 원문 보기'),
      trailing: const Icon(Icons.open_in_new),
      onTap: () => open(url),
    ),
  );
}
