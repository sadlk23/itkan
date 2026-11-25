import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';
import '../services/household_service.dart';
import '../services/inventory_store.dart';

class HouseholdScreen extends StatefulWidget {
  const HouseholdScreen({super.key, required this.store});
  final InventoryStore store;
  @override
  State<HouseholdScreen> createState() => _HouseholdScreenState();
}

class _HouseholdScreenState extends State<HouseholdScreen> {
  late final service = HouseholdService(widget.store);
  List<String> members = ['나', '구성원 2'];
  int selected = 0;
  bool enabled = false, busy = false;
  String? error, result;
  final input = TextEditingController();
  HouseholdSnapshot? preview;
  String get key => 'household_${widget.store.isDemo ? 'demo' : 'real'}';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          final saved = prefs.getStringList('${key}_members');
          members =
              saved != null &&
                  saved.length >= 2 &&
                  saved.length <= 3 &&
                  saved.every((s) => s.trim().isNotEmpty && s.length <= 15)
              ? saved
              : ['나', '구성원 2'];
          enabled = prefs.getBool('${key}_enabled') ?? false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '프로필 설정을 읽지 못했어요.');
    }
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() fn) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e
              .toString()
              .replaceFirst('FormatException: ', '')
              .replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> toggle() async {
    if (!enabled) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('공동 사용 시연으로 전환할까요?'),
          content: const Text(
            '이 기기에서 2~3인 프로필이 같은 재고를 보고 편집하는 시연입니다. 실제 계정 초대나 다른 기기로의 실시간 동기화는 연결하지 않습니다. 기존 재고는 유지됩니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('시연 시작'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await run(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('${key}_enabled', !enabled);
      if (mounted) setState(() => enabled = !enabled);
    });
  }

  Future<void> editMembers() async {
    var draft = members.join(', ');
    final names = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('시연 구성원 이름'),
        content: TextFormField(
          initialValue: draft,
          onChanged: (value) => draft = value,
          maxLength: 60,
          decoration: const InputDecoration(hintText: '예: 나, 민수, 지연'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, draft),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (names == null || !mounted) return;
    final parsed = names
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
    if (parsed.length < 2 ||
        parsed.length > 3 ||
        parsed.any((n) => n.length > 15)) {
      setState(() => error = '서로 다른 이름 2~3개를 쉼표로 나눠 적어주세요. 이름은 15자 이내입니다.');
      return;
    }
    await run(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('${key}_members', parsed);
      if (mounted) {
        setState(() {
          members = parsed;
          selected = 0;
        });
      }
    });
  }

  Future<void> exportSnapshot() async {
    if (widget.store.activeBatches.isEmpty) {
      setState(() => error = '공유할 보유 재료가 없어요.');
      return;
    }
    final text = service.exportSnapshot();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('재고 스냅샷 내보내기'),
        content: SizedBox(
          width: 400,
          height: 300,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    content: Text('복사했어요. 선택한 대상에게 직접 전달할 수 있습니다.'),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('직접 복사'),
          ),
        ],
      ),
    );
  }

  Future<void> importSnapshot() async {
    final snapshot = preview;
    if (snapshot == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 묶음으로 입고할까요?'),
        content: Text(
          '${snapshot.batches.length}개 재료 묶음을 ${widget.store.isDemo ? '샘플' : '내'} 재고에 추가합니다. 기존 재고를 덮어쓰거나 자동 합산하지 않습니다. 내용을 확인해주세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('확인하고 입고'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await run(() async {
      final added = await service.importApproved(snapshot, approved: true);
      if (mounted) {
        setState(() {
          result = added
              ? '${snapshot.batches.length}개 묶음을 입고했어요. 변경 이력에서 확인할 수 있습니다.'
              : '이미 가져온 스냅샷이에요. 중복 입고하지 않았습니다.';
          preview = null;
          input.clear();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('함께 쓰는 냉장고 · 시연')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const Chip(label: Text('준비 사례 제한 구현 · 클라우드 미연결')),
          const Text(
            '같은 기기에서 가족이 재고를 함께 보는 경험을 시연합니다. 프로필은 로그인 계정이나 접근 권한이 아닙니다. 실제 다른 기기와의 동시 편집·동기화는 구현하지 않았습니다.',
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (result != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(result!),
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(enabled ? '공동 사용 시연 중' : '개인 사용'),
            subtitle: const Text('전환해도 재고를 삭제하거나 다른 기기에 전송하지 않습니다.'),
            value: enabled,
            onChanged: busy ? null : (_) => toggle(),
          ),
          if (enabled) ...[
            const SizedBox(height: 16),
            Text('현재 시연 구성원', style: Theme.of(context).textTheme.titleLarge),
            Wrap(
              spacing: 8,
              children: members
                  .asMap()
                  .entries
                  .map(
                    (e) => ChoiceChip(
                      label: Text(e.value),
                      selected: selected == e.key,
                      onSelected: (_) => setState(() => selected = e.key),
                    ),
                  )
                  .toList(),
            ),
            TextButton(
              onPressed: busy ? null : editMembers,
              child: const Text('구성원 이름 수정 · 2~3인'),
            ),
            Text(
              '${members[selected]}님도 같은 ${widget.store.activeBatches.length}개 재고 묶음을 보고 편집할 수 있습니다. 구성원 전환은 실제 사용자 인증을 수행하지 않습니다.',
            ),
            ...widget.store.activeBatches
                .take(6)
                .map(
                  (b) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(b.name),
                    subtitle: Text(
                      '${b.quantityLabel} · ${b.storageType.label}',
                    ),
                  ),
                ),
            const Text(
              '재고 편집은 냉장고 화면의 공통 등록·수정 기능을 사용합니다. 구성원 모두 같은 편집 권한을 갖는 사례입니다.',
            ),
          ],
          const Divider(height: 36),
          Text('수동 스냅샷 전달', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            '재고 이름·수량·날짜·위치만 JSON으로 복사합니다. 별도 공유 메시지를 자동 전송하지 않습니다. 가져오기는 수정 동기화가 아니라 새 재료 묶음 입고입니다.',
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : exportSnapshot,
            icon: const Icon(Icons.ios_share),
            label: const Text('현재 재고 스냅샷 복사'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: input,
            maxLines: 5,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: '가져올 스냅샷 JSON 붙여넣기',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => setState(() => preview = null),
          ),
          OutlinedButton(
            onPressed: busy
                ? null
                : () => run(() async {
                    final parsed = service.preview(input.text);
                    if (mounted) setState(() => preview = parsed);
                  }),
            child: const Text('내용 검증 · 미리보기'),
          ),
          if (preview != null) ...[
            Text(
              '${preview!.batches.length}개 묶음 · 아직 저장되지 않았어요.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ...preview!.batches.map(
              (b) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(b.name),
                subtitle: Text(
                  '${b.quantityLabel} · ${b.storageType.label} · ${b.expiryLabel()}',
                ),
              ),
            ),
            FilledButton(
              onPressed: busy ? null : importSnapshot,
              child: const Text('미리본 재고 가져오기'),
            ),
          ],
        ],
      ),
    ),
  );
}
