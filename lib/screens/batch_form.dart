import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';
import '../design/food_illustration.dart';
import '../services/ingredient_photo_service.dart';
import '../services/inventory_store.dart';
import '../services/pending_image_picker.dart';
import '../widgets/common.dart';

class BatchForm extends StatefulWidget {
  const BatchForm({
    super.key,
    this.initial,
    this.confirmSave = true,
    this.store,
    this.candidate,
    this.restoration,
    this.recoveredPhoto,
    this.photoService,
  });
  final InventoryBatch? initial;
  final bool confirmSave;
  final InventoryStore? store;
  final CandidatePhotoContext? candidate;
  final IntakePhotoRequest? restoration;
  final String? recoveredPhoto;
  final IngredientPhotoService? photoService;
  @override
  State<BatchForm> createState() => _BatchFormState();
}

class _BatchFormState extends State<BatchForm> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.initial?.name ?? '');
  late final quantity = TextEditingController(
    text: '${widget.initial?.quantity ?? 1}',
  );
  late String unit = widget.initial?.unit ?? '개';
  late StorageType storage = widget.initial?.storageType ?? StorageType.fridge;
  late ExpiryStatus status =
      widget.initial?.expiryStatus ?? ExpiryStatus.unknown;
  late DateTime? date = widget.initial?.expiryDate;
  late OpenedStatus openedStatus =
      widget.initial?.openedStatus ?? OpenedStatus.unknown;
  late QuantityMode quantityMode =
      widget.initial?.quantityMode ?? QuantityMode.measured;
  late StockLevel stockLevel = widget.initial?.stockLevel ?? StockLevel.enough;
  late String category = widget.initial?.category ?? '기타';
  bool saving = false;
  bool pickingPhoto = false;
  late String? photoFile = widget.initial?.photoFile;
  late final photos = widget.photoService ?? IngredientPhotoService();
  late final bool? initialMode;
  final draftPhotos = <String>{};

  bool storageEdited = false;
  bool allowExit = false;
  bool askingToLeave = false;
  late Map<String, Object?> initialDraft;
  Map<String, Object?> get draftState => {
    'name': name.text,
    'quantity': quantity.text,
    'unit': unit,
    'storage': storage.name,
    'status': status.name,
    'date': date?.toIso8601String(),
    'openedStatus': openedStatus.name,
    'quantityMode': quantityMode.name,
    'stockLevel': stockLevel.name,
    'category': category,
    'photoFile': photoFile,
  };
  bool get hasChanges => jsonEncode(draftState) != jsonEncode(initialDraft);

  Future<void> requestLeave() async {
    if (saving || pickingPhoto || askingToLeave) return;
    askingToLeave = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('작성 중인 내용을 버릴까요?'),
        content: const Text('아직 저장하지 않은 입력과 선택한 사진이 사라져요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('계속 작성'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('버리고 나가기'),
          ),
        ],
      ),
    );
    askingToLeave = false;
    if (!mounted || discard != true) return;
    setState(() => allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  void initState() {
    super.initState();
    initialMode = widget.restoration?.demo ?? widget.store?.isDemo;
    initialDraft = draftState;
    if (widget.restoration case final restored?) {
      final state = restored.form!;
      name.text = state['name'] as String;
      quantity.text = state['quantity'] as String;
      unit = state['unit'] as String;
      storage = StorageType.values.byName(state['storage'] as String);
      status = ExpiryStatus.values.byName(state['status'] as String);
      date = state['date'] == null
          ? null
          : DateTime.parse(state['date'] as String);
      openedStatus = OpenedStatus.values.byName(
        state['openedStatus'] as String,
      );
      quantityMode = QuantityMode.values.byName(
        state['quantityMode'] as String,
      );
      stockLevel = StockLevel.values.byName(state['stockLevel'] as String);
      category = state['category'] as String;
      photoFile = widget.recoveredPhoto ?? state['photoFile'] as String?;
      draftPhotos.addAll(restored.draftPhotos);
      if (widget.recoveredPhoto case final file?) draftPhotos.add(file);
      storageEdited = true;
    }
    name.addListener(draftChanged);
    quantity.addListener(draftChanged);
    if (widget.initial == null && widget.restoration == null) {
      loadDefaultStorage();
    }
  }

  void draftChanged() {
    if (mounted) setState(() {});
  }

  Future<void> loadDefaultStorage() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final value = preferences.getString('default_storage');
      final preferred = StorageType.values
          .where((item) => item.name == value)
          .firstOrNull;
      if (mounted && !storageEdited && !saving && preferred != null) {
        setState(() {
          storage = preferred;
          initialDraft['storage'] = preferred.name;
        });
      }
    } catch (_) {
      // A preferences failure must never prevent manual registration.
    }
  }

  Future<void> pickPhoto() async {
    if (pickingPhoto || saving) return;
    if (widget.store?.isDemo != initialMode) {
      inform(context, '보관함 모드가 바뀌었어요. 입력 화면을 다시 열어주세요.');
      return;
    }
    setState(() => pickingPhoto = true);
    try {
      final selected = await photos.pickGallery(
        request: initialMode == null
            ? null
            : IntakePhotoRequest(
                use: widget.candidate != null
                    ? IntakePhotoUse.candidate
                    : widget.initial == null
                    ? IntakePhotoUse.newIngredient
                    : IntakePhotoUse.editIngredient,
                demo: initialMode!,
                original: widget.initial,
                form: draftState,
                draftPhotos: Set.of(draftPhotos),
                candidate: widget.candidate,
              ),
      );
      if (selected == null) return;
      if (!mounted || widget.store?.isDemo != initialMode) {
        await photos.deleteDraft(selected);
        return;
      }
      draftPhotos.add(selected);
      setState(() => photoFile = selected);
    } catch (_) {
      if (mounted) inform(context, '사진을 가져오지 못했어요. 갤러리 접근 권한과 파일을 확인해주세요.');
    } finally {
      if (mounted) setState(() => pickingPhoto = false);
    }
  }

  Future<void> discardDraftPhotos() async {
    final files = Set.of(draftPhotos);
    if (widget.store case final store?) {
      await photos.discardUnreferenced(store, files);
      return;
    }
    for (final file in files) {
      try {
        await photos.deleteDraft(file);
      } catch (_) {
        /* best-effort draft cleanup */
      }
    }
  }

  @override
  void dispose() {
    discardDraftPhotos();
    name.dispose();
    quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<InventoryBatch>(
    canPop: allowExit || (!hasChanges && !saving && !pickingPhoto),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) requestLeave();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? '재료 직접 등록' : '재료 정보 수정'),
      ),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              TextFormField(
                controller: name,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '재료 이름',
                  hintText: '예: 두부',
                ),
                maxLength: 40,
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '재료 이름을 입력해주세요.' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<QuantityMode>(
                isExpanded: true,
                key: const ValueKey('batch-quantity-mode'),
                initialValue: quantityMode,
                decoration: const InputDecoration(
                  labelText: '남은 양을 어떻게 기록할까요?',
                ),
                items: const [
                  DropdownMenuItem(
                    value: QuantityMode.measured,
                    child: Text(
                      '수량형 · 수량과 단위',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: QuantityMode.status,
                    child: Text(
                      '상태형 · 충분 / 부족 / 없음',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => quantityMode = v!),
              ),
              const SizedBox(height: 16),
              if (quantityMode == QuantityMode.status) ...[
                const InfoBox(
                  '조미료·소스는 상태로 관리할 수 있어요. 소량을 쓸 때마다 무게를 입력하거나 자동 차감하지 않습니다.',
                ),
                DropdownButtonFormField<StockLevel>(
                  isExpanded: true,
                  key: const ValueKey('batch-stock-level'),
                  initialValue: stockLevel,
                  decoration: const InputDecoration(labelText: '남은 상태'),
                  items: StockLevel.values
                      .map(
                        (s) => DropdownMenuItem(
                          value: s,
                          child: Text(
                            s.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => stockLevel = v!),
                ),
                if (stockLevel == StockLevel.none)
                  const InfoBox('없음으로 저장하면 보유 목록에서 숨기고 변경 이력에 남깁니다.'),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: const ValueKey('batch-quantity'),
                        controller: quantity,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: '수량'),
                        validator: (v) {
                          final n = double.tryParse(v ?? '');
                          return n == null ||
                                  !n.isFinite ||
                                  n < 0 ||
                                  (widget.initial == null && n == 0)
                              ? widget.initial == null
                                    ? '0보다 큰 수량을 입력하세요.'
                                    : '0 이상의 수량을 입력하세요.'
                              : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: unit,
                        decoration: const InputDecoration(labelText: '단위'),
                        items: {'개', '팩', 'g', 'kg', 'ml', 'L', unit}
                            .map(
                              (u) => DropdownMenuItem(
                                value: u,
                                child: Text(
                                  u,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => unit = v!),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 20),
              DropdownButtonFormField<StorageType>(
                key: ValueKey('storage-${storage.name}'),
                isExpanded: true,
                initialValue: storage,
                decoration: const InputDecoration(labelText: '보관 위치'),
                items: StorageType.values
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(
                          storageLabel(s),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() {
                  storageEdited = true;
                  storage = v!;
                }),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<ExpiryStatus>(
                isExpanded: true,
                key: const ValueKey('batch-expiry-status'),
                initialValue: status,
                decoration: const InputDecoration(labelText: '날짜 기준'),
                items: ExpiryStatus.values
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(
                          expiryLabel(s),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() {
                  status = v!;
                  if (status == ExpiryStatus.unknown) date = null;
                }),
              ),
              if (status != ExpiryStatus.unknown)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_month_outlined),
                  title: Text(date == null ? '소비기한 선택' : dateText(date!)),
                  subtitle: const Text('제품에 표시된 날짜 또는 추정 날짜'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final result = await showDatePicker(
                      context: context,
                      initialDate: date ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (mounted && result != null) {
                      setState(() => date = result);
                    }
                  },
                ),
              if (widget.initial != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    '기존 날짜 출처: ${dateSourceLabel(widget.initial!.expirySource)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              ExpansionTile(
                key: const ValueKey('batch-extra-details'),
                initiallyExpanded: widget.initial != null,
                maintainState: true,
                tilePadding: EdgeInsets.zero,
                title: const Text('사진과 추가 정보'),
                subtitle: const Text('분류 · 개봉 상태 · 내 사진'),
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    key: const ValueKey('batch-category'),
                    initialValue: category,
                    decoration: const InputDecoration(labelText: '재료 분류'),
                    items:
                        {
                              '채소',
                              '과일',
                              '육류',
                              '해산물',
                              '달걀',
                              '유제품',
                              '반찬',
                              '가공식품',
                              '냉동식품',
                              '조미료',
                              '소스',
                              '기타',
                              category,
                            }
                            .map(
                              (c) => DropdownMenuItem(
                                value: c,
                                child: Text(
                                  c,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                    onChanged: (v) => setState(() => category = v!),
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<OpenedStatus>(
                    isExpanded: true,
                    key: const ValueKey('batch-opened-status'),
                    initialValue: openedStatus,
                    decoration: const InputDecoration(labelText: '개봉 상태'),
                    items: OpenedStatus.values
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(
                              s.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => openedStatus = v!),
                  ),
                  const SizedBox(height: 20),
                  const InfoBox('같은 재료도 구매일과 소비기한이 다르면 별도 묶음으로 보관해요.'),
                  Center(
                    child: FoodIllustration(
                      name: name.text,
                      category: category,
                      photoFile: photoFile,
                      artKey: name.text.trim() == widget.initial?.name
                          ? (widget.initial?.artKey ?? 'generic')
                          : 'generic',
                      size: 96,
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('batch-photo-pick'),
                        onPressed: saving || pickingPhoto ? null : pickPhoto,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(pickingPhoto ? '사진 가져오는 중' : '내 사진 선택'),
                      ),
                      if (photoFile != null)
                        TextButton(
                          key: const ValueKey('batch-photo-reset'),
                          onPressed: saving || pickingPhoto
                              ? null
                              : () => setState(() => photoFile = null),
                          child: const Text('기본 이미지로'),
                        ),
                    ],
                  ),
                ],
              ),
              const InfoBox('모르는 날짜를 임의로 정하지 않아요. 추정은 실제 날짜와 구분해서 표시합니다.'),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('batch-save'),
                onPressed: saving || pickingPhoto ? null : save,
                child: Text(widget.confirmSave ? '입력 내용 확인' : '후보 수정 완료'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Future<void> save() async {
    if (saving || pickingPhoto) return;
    if (widget.store?.isDemo != initialMode) {
      inform(context, '보관함 모드가 바뀌었어요. 입력 화면을 다시 열어주세요.');
      return;
    }
    if (!form.currentState!.validate()) return;
    if (status != ExpiryStatus.unknown && date == null) {
      inform(context, '날짜를 선택하거나 미상으로 변경해주세요.');
      return;
    }
    final savedQuantity = quantityMode == QuantityMode.status
        ? (stockLevel == StockLevel.none ? 0.0 : 1.0)
        : double.parse(quantity.text);
    final original = widget.initial;
    final unchangedDate =
        original != null &&
        original.expiryDate == date &&
        original.expiryStatus == status;
    final source = unchangedDate ? original.expirySource : 'manual';
    final now = DateTime.now();
    final draft =
        widget.initial?.copyWith(
          name: name.text.trim(),
          quantity: savedQuantity,
          unit: unit,
          storageType: storage,
          expiryDate: date,
          expiryStatus: status,
          expirySource: source,
          openedStatus: openedStatus,
          quantityMode: quantityMode,
          stockLevel: stockLevel,
          category: category,
          photoFile: photoFile,
          artKey: name.text.trim() == widget.initial?.name
              ? (widget.initial?.artKey ?? 'generic')
              : 'generic',
        ) ??
        InventoryBatch(
          id: now.microsecondsSinceEpoch.toString(),
          name: name.text.trim(),
          quantity: savedQuantity,
          unit: unit,
          storageType: storage,
          expiryDate: date,
          expiryStatus: status,
          expirySource: source,
          openedStatus: openedStatus,
          quantityMode: quantityMode,
          stockLevel: stockLevel,
          category: category,
          photoFile: photoFile,
          artKey: name.text.trim() == widget.initial?.name
              ? (widget.initial?.artKey ?? 'generic')
              : 'generic',
          createdAt: now,
          updatedAt: now,
        );
    setState(() => saving = true);
    if (widget.confirmSave &&
        !await confirm(
          context,
          '이대로 저장할까요?',
          '${draft.name} · ${quantityText(draft)}\n$category · ${openedStatus.label}\n${storageLabel(storage)} · ${date == null ? '날짜 미상' : '${dateText(date!)} (${expiryLabel(status)})'}',
        )) {
      if (mounted) setState(() => saving = false);
      return;
    }
    if (mounted) {
      draftPhotos.remove(photoFile);
      setState(() => allowExit = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, draft);
      });
    }
  }
}

String storageLabel(StorageType s) => switch (s) {
  StorageType.fridge => '냉장',
  StorageType.freezer => '냉동',
  StorageType.pantry => '팬트리',
};
String expiryLabel(ExpiryStatus s) => switch (s) {
  ExpiryStatus.actual => '실제 · 제품 표시',
  ExpiryStatus.estimated => '추정',
  ExpiryStatus.unknown => '미상',
};
String dateText(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
String quantityText(InventoryBatch b) => b.quantityMode == QuantityMode.status
    ? b.stockLevel.label
    : '${formatQuantity(b.quantity)}${b.unit}';
String dateSourceLabel(String source) => switch (source) {
  'manual' => '직접 입력',
  'ocr' => '영수증 인식',
  'ai' => 'AI 추정',
  'sample' => '샘플 데이터',
  _ => source,
};
String expiryText(InventoryBatch b) {
  if (b.expiryStatus == ExpiryStatus.unknown || b.expiryDate == null) {
    return '날짜 미상';
  }
  final n = DateTime.now();
  final d = b.expiryDate!;
  final days = DateTime(
    d.year,
    d.month,
    d.day,
  ).difference(DateTime(n.year, n.month, n.day)).inDays;
  return '${b.expiryStatus == ExpiryStatus.estimated ? '추정 ' : ''}${days < 0
      ? '기한 지남'
      : days == 0
      ? 'D-day'
      : 'D-$days'}';
}
