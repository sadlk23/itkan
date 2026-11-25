import 'dart:io';
import 'dart:async';

import '../services/storage_preferences.dart';

import '../services/receipt_privacy.dart';
import '../services/ai_service.dart';
import '../services/intake_ai_service.dart';
import '../services/ingredient_photo_service.dart';
import '../services/pending_image_picker.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/inventory.dart';
import '../services/inventory_store.dart';
import '../widgets/common.dart';
import 'batch_form.dart';

/// Only newly created local copies belong to this intake. Existing inventory
/// and undo snapshots in either mode protect a file even after leaving a form.
Future<void> cleanupIntakePhotos(
  InventoryStore store,
  Set<String> createdFiles, {
  IngredientPhotoService? photos,
}) => (photos ?? IngredientPhotoService()).discardUnreferenced(
  store,
  createdFiles,
);

typedef _ReceiptText = ({String masked, String digest});

Future<_ReceiptText> _readReceipt(
  XFile image, [
  Future<String> Function(String)? read,
]) async {
  Future<String> recognize(String path) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.korean);
    try {
      return (await recognizer.processImage(InputImage.fromFilePath(path)))
          .text;
    } finally {
      await recognizer.close();
    }
  }

  final text = await (read ?? recognize)(image.path);
  if (text.trim().isEmpty) {
    throw const FormatException('글자를 찾지 못했어요. 밝고 선명한 사진으로 다시 시도하거나 직접 입력해주세요.');
  }
  return (masked: redactReceipt(text), digest: receiptFingerprint(text));
}

Future<void> _reviewReceipt(
  BuildContext context,
  InventoryStore store,
  bool demo,
  _ReceiptText text,
) async {
  final storage = await preferredStorage();
  if (!context.mounted || demo != store.isDemo) return;
  await Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => CandidateScreen(
        store: store,
        rawText: text.masked,
        receiptDigest: text.digest,
        source: 'ocr',
        drafts: receiptCandidates(text.masked)
            .map((b) => b.copyWith(storageType: storage))
            .toList(),
      ),
    ),
  );
}

/// Resume an Android selection in its original inventory and confirmation flow.
Future<void> recoverPendingIntake(
  BuildContext context,
  InventoryStore store, {
  PendingImagePicker? picker,
  IngredientPhotoService? photos,
  Future<String> Function(String)? readReceipt,
}) async {
  final photoService = photos ?? IngredientPhotoService();
  final created = <String>{};
  try {
    final restored = await (picker ?? PendingImagePicker.instance)
        .recover<
          ({IntakePhotoRequest request, String? photo, _ReceiptText? receipt})
        >((request, image) async {
          created.addAll(request.temporaryPhotos);
          if (!context.mounted) return null;
          if (request.demo != store.isDemo) {
            inform(context, '사진 선택을 시작한 보관함 모드가 달라서 입력을 닫았어요.');
            return null;
          }
          if (request.use == IntakePhotoUse.editIngredient &&
              !store.batches.any(
                (b) => request.original?.hasSameSnapshot(b) ?? false,
              )) {
            inform(context, '재고 내용이 바뀌었어요. 최신 재료에서 다시 수정해주세요.');
            return null;
          }
          if (request.use == IntakePhotoUse.receipt && image == null) {
            inform(context, '영수증 사진을 다시 선택해주세요.');
            return null;
          }
          final purpose = switch (request.use) {
            IntakePhotoUse.receipt => '영수증 품목 확인',
            IntakePhotoUse.newIngredient => '새 재료 등록',
            IntakePhotoUse.editIngredient => '재고 정보 수정',
            IntakePhotoUse.candidate => '입고 후보 수정',
          };
          if (!await confirm(
                context,
                '사진 선택을 이어갈까요?',
                '${request.demo ? '체험' : '내'} 보관함의 $purpose 화면으로 돌아갑니다.'
                    '${image == null ? ' 사진은 다시 선택해주세요.' : ''}',
                action: '이어서 확인',
              ) ||
              !context.mounted ||
              request.demo != store.isDemo) {
            return null;
          }
          if (request.use == IntakePhotoUse.receipt) {
            final text = await _readReceipt(image!, readReceipt);
            return (request: request, photo: null, receipt: text);
          }
          String? imported;
          if (image != null) {
            try {
              imported = await photoService.importPickedFile(File(image.path));
              created.add(imported);
            } on Exception {
              if (context.mounted) {
                inform(context, '사진을 읽지 못했어요. 입력 화면에서 다시 선택해주세요.');
              }
            }
          }
          return (request: request, photo: imported, receipt: null);
        });
    if (restored == null ||
        !context.mounted ||
        store.isDemo != restored.request.demo) {
      return;
    }
    final request = restored.request;
    if (restored.receipt case final receipt?) {
      await _reviewReceipt(context, store, request.demo, receipt);
    } else if (request.candidate case final candidate?) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => CandidateScreen(
            store: store,
            source: candidate.source,
            rawText: candidate.text,
            receiptDigest: candidate.receiptDigest,
            restoration: request,
            recoveredPhoto: restored.photo,
            photoService: photoService,
          ),
        ),
      );
    } else {
      final result = await Navigator.push<InventoryBatch>(
        context,
        MaterialPageRoute(
          builder: (_) => BatchForm(
            store: store,
            initial: request.original,
            restoration: request,
            recoveredPhoto: restored.photo,
            photoService: photoService,
          ),
        ),
      );
      if (result == null) return;
      if (result.photoFile case final file?
          when file != request.original?.photoFile) {
        created.add(file);
      }
      if (!context.mounted || store.isDemo != request.demo) return;
      if (request.use == IntakePhotoUse.editIngredient) {
        await store.update(result, expectedDemo: request.demo);
      } else {
        await store.add(result, expectedDemo: request.demo);
      }
      if (context.mounted) informUndo(context, store, '확인한 재료를 저장했어요.');
    }
  } catch (error) {
    if (context.mounted) {
      inform(
        context,
        error is FormatException
            ? error.message
            : '중단된 입력을 마치지 못했어요. 보관함에서 다시 확인해주세요.',
      );
    }
  } finally {
    await cleanupIntakePhotos(store, created, photos: photoService);
  }
}

class IntakeScreen extends StatefulWidget {
  const IntakeScreen({super.key, required this.store});
  final InventoryStore store;
  @override
  State<IntakeScreen> createState() => _IntakeScreenState();
}

class _IntakeScreenState extends State<IntakeScreen> {
  bool busy = false;
  String error = '';
  final createdPhotos = <String>{};

  @override
  void dispose() {
    unawaited(cleanupIntakePhotos(widget.store, Set.of(createdPhotos)));
    super.dispose();
  }

  Future<void> manual() async {
    if (busy) return;
    final store = widget.store;
    final mode = store.isDemo;
    final draft = await Navigator.push<InventoryBatch>(
      context,
      MaterialPageRoute(builder: (_) => BatchForm(store: store)),
    );
    if (draft == null) return;
    if (draft.photoFile != null) createdPhotos.add(draft.photoFile!);
    if (!mounted) {
      unawaited(cleanupIntakePhotos(store, Set.of(createdPhotos)));
      return;
    }
    if (mode != store.isDemo) {
      inform(context, '보관함 모드가 바뀌었어요. 다시 등록해주세요.');
      return;
    }
    setState(() => busy = true);
    try {
      await store.add(draft, expectedDemo: mode);
      if (mounted) {
        inform(context, '재료를 추가했어요.');
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) setState(() => error = '재료를 저장하지 못했어요. 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> scan(ImageSource source) async {
    if (busy) return;
    final mode = widget.store.isDemo;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final text = await PendingImagePicker.instance.select(
        IntakePhotoRequest(use: IntakePhotoUse.receipt, demo: mode),
        source,
        _readReceipt,
      );
      if (!mounted || text == null) return;
      await _reviewReceipt(context, widget.store, mode, text);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : '사진을 읽지 못했어요. 사진 접근 권한을 확인하거나 직접 입력해주세요.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('재료 채우기')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Text(
            '편한 방법으로 알려주세요.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text('저장하기 전 한 번 더 확인할 수 있어요.'),
          const SizedBox(height: 24),
          if (busy) const LinearProgressIndicator(),
          if (error.isNotEmpty) InfoBox(error, icon: Icons.error_outline),
          choice(Icons.edit_outlined, '직접 입력', '이름·수량·날짜를 직접 적어요', manual),
          choice(
            Icons.photo_library_outlined,
            '영수증 사진 선택',
            '사진 속 재료를 한 번에 가져와요',
            () => scan(ImageSource.gallery),
          ),
          choice(
            Icons.camera_alt_outlined,
            '영수증 촬영',
            '촬영 후 인식 결과를 수정해요',
            () => scan(ImageSource.camera),
          ),
          choice(
            Icons.mic_none,
            '말 또는 글로 등록',
            '이해한 품목과 수량을 확인해요',
            () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => VoiceScreen(store: widget.store),
              ),
            ),
          ),
          const InfoBox(
            '영수증에는 소비기한이 없는 경우가 많아요. 인식되지 않은 날짜는 미상으로 두고, 품목과 수량을 확인한 뒤 입고합니다.',
          ),
        ],
      ),
    ),
  );
  Widget choice(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.all(14),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF0DF),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, size: 24),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: busy ? null : onTap,
    ),
  );
}

/// Conservative candidate extraction. Quantities/prices on receipts are not
/// treated as package quantities. Every candidate is editable and unselected.
List<InventoryBatch> receiptCandidates(String text) {
  final now = DateTime.now();
  final results = <InventoryBatch>[];
  for (final line in text.split('\n')) {
    final cleaned = line.trim();
    if (cleaned == '[개인정보 가림]' ||
        cleaned.isEmpty ||
        !RegExp(r'[가-힣A-Za-z]').hasMatch(cleaned) ||
        RegExp(r'합계|결제|카드|부가세|사업자|영수증|전화|주소|승인|과세|면세|할인|현금|거스름')
            .hasMatch(cleaned)) {
      continue;
    }
    final name = cleaned
        .replaceAll(RegExp(r'\s+[\d,]+(?:\.\d+)?(?:\s|$).*'), '')
        .replaceAll(RegExp(r'^\d+\s+'), '')
        .trim();
    if (name.length < 2) continue;
    results.add(
      InventoryBatch(
        id: 'ocr_${now.microsecondsSinceEpoch}_${results.length}',
        name: name.length > 40 ? name.substring(0, 40) : name,
        quantity: 1,
        unit: '개',
        storageType: StorageType.fridge,
        expiryStatus: ExpiryStatus.unknown,
      ),
    );
    if (results.length >= 30) break;
  }
  return results;
}

class CandidateScreen extends StatefulWidget {
  const CandidateScreen({
    super.key,
    required this.store,
    required this.rawText,
    required this.source,
    this.drafts,
    this.candidates,
    this.returnChangeId = false,
    this.receiptDigest,
    this.aiService,
    this.restoration,
    this.recoveredPhoto,
    this.photoService,
  });
  final InventoryStore store;
  final String rawText, source;
  final List<InventoryBatch>? drafts;
  final List<IntakeCandidate>? candidates;
  final bool returnChangeId;
  final String? receiptDigest;
  final AiService? aiService;
  final IntakePhotoRequest? restoration;
  final String? recoveredPhoto;
  final IngredientPhotoService? photoService;
  @override
  State<CandidateScreen> createState() => _CandidateScreenState();
}

class _CandidateScreenState extends State<CandidateScreen> {
  late final ai = widget.aiService ?? AiService();
  late final sourceText = TextEditingController(text: widget.rawText);
  bool allowExit = false;
  bool exitPrompt = false;
  late final List<InventoryBatch> drafts =
      widget.restoration?.candidate?.batches.toList() ??
      widget.candidates?.map((c) => c.batch).toList() ??
      (widget.drafts == null ? null : List.of(widget.drafts!)) ??
      receiptCandidates(widget.rawText);
  final Set<String> chosen = {};
  late final bool initialMode;
  @override
  void initState() {
    super.initState();
    initialMode = widget.restoration?.demo ?? widget.store.isDemo;
    for (final candidate in widget.candidates ?? <IntakeCandidate>[]) {
      evidence[candidate.batch.id] = candidate.evidence;
      if (candidate.needsQuantityReview) needsReview.add(candidate.batch.id);
    }
    if (widget.restoration?.candidate case final restored?) {
      chosen.addAll(restored.chosen);
      needsReview.addAll(restored.needsReview);
      evidence.addAll(restored.evidence);
      createdPhotos.addAll(restored.createdPhotos);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          editCandidate(restored.editIndex, restoration: widget.restoration);
        }
      });
    }
  }

  final createdPhotos = <String>{};

  @override
  void dispose() {
    sourceText.dispose();
    if (widget.source == 'ocr' && widget.aiService == null) ai.dispose();
    unawaited(
      cleanupIntakePhotos(
        widget.store,
        Set.of(createdPhotos),
        photos: widget.photoService,
      ),
    );
    super.dispose();
  }

  bool busy = false;
  final evidence = <String, String>{};
  final needsReview = <String>{};
  String aiMessage = '';
  bool aiParsing = false;

  Future<void> editCandidate(
    int? index, {
    IntakePhotoRequest? restoration,
  }) async {
    final store = widget.store;
    final photos = widget.photoService;
    if (initialMode != store.isDemo) {
      inform(context, '보관함 모드가 바뀌었어요. 후보 화면을 다시 열어주세요.');
      return;
    }
    final previous = index == null ? null : drafts[index];
    final candidate = CandidatePhotoContext(
      source: widget.source,
      text: widget.source == 'ocr'
          ? redactReceipt(sourceText.text)
          : sourceText.text,
      batches: List.of(drafts),
      chosen: Set.of(chosen),
      needsReview: Set.of(needsReview),
      evidence: Map.of(evidence),
      createdPhotos: Set.of(createdPhotos),
      editIndex: index,
      receiptDigest:
          widget.receiptDigest ??
          (widget.source == 'ocr' ? receiptFingerprint(widget.rawText) : null),
    );
    final result = await Navigator.push<InventoryBatch>(
      context,
      MaterialPageRoute(
        builder: (_) => BatchForm(
          store: store,
          initial: previous,
          confirmSave: false,
          candidate: candidate,
          restoration: restoration,
          recoveredPhoto: restoration == null ? null : widget.recoveredPhoto,
          photoService: photos,
        ),
      ),
    );
    if (result == null) return;
    if (result.photoFile case final file? when file != previous?.photoFile) {
      createdPhotos.add(file);
    }
    if (!mounted || initialMode != store.isDemo) {
      await cleanupIntakePhotos(store, Set.of(createdPhotos), photos: photos);
      return;
    }
    setState(() {
      if (index == null) {
        drafts.add(result);
      } else {
        drafts[index] = result;
        needsReview.remove(previous!.id);
      }
    });
  }

  Future<void> structureReceipt() async {
    if (busy || !ai.isConfigured || initialMode != widget.store.isDemo) return;
    setState(() {
      busy = true;
      aiParsing = true;
    });
    try {
      final candidates = await IntakeAiService(ai).parse(
        sourceText.text,
        receipt: true,
        storage: drafts.firstOrNull?.storageType ?? await preferredStorage(),
      );
      if (!mounted || initialMode != widget.store.isDemo) return;
      setState(() {
        drafts
          ..clear()
          ..addAll(candidates.map((c) => c.batch));
        chosen.clear();
        evidence.clear();
        needsReview.clear();
        for (final c in candidates) {
          evidence[c.batch.id] = c.evidence;
          if (c.needsQuantityReview) needsReview.add(c.batch.id);
        }
        aiMessage = 'AI가 정리한 초안입니다. 원문과 비교한 뒤 선택해주세요.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => aiMessage = 'AI 정리를 완료하지 못했어요. 기존 후보를 직접 수정하거나 다시 시도해주세요.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          aiParsing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowExit || (!busy && drafts.isEmpty && sourceText.text.isEmpty),
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || exitPrompt || busy) return;
      exitPrompt = true;
      final discard = await confirm(
        context,
        '입고 확인을 나갈까요?',
        '아직 저장하지 않은 후보와 수정 내용이 사라져요.',
        action: '나가기',
      );
      exitPrompt = false;
      if (!mounted || !discard) return;
      setState(() => allowExit = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('후보 수정 · 입고 확인')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const InfoBox(
                    '아직 저장되지 않았어요. 이름·수량·단위를 수정한 뒤 입고할 항목을 선택해주세요. 초기 1개는 확인용 값이며 실제 구매 수량이 아닐 수 있습니다.',
                  ),
                  if (widget.source == 'ocr' && ai.isConfigured) ...[
                    const Text(
                      'AI 정리를 누르면 아래 마스킹 원문이 AI 서비스로 전송됩니다. 개인정보가 남았는지 먼저 확인해주세요.',
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : structureReceipt,
                      child: const Text('AI로 품목 정리하기'),
                    ),
                  ],
                  if (widget.source == 'ocr' && !ai.isConfigured)
                    const InfoBox('AI 연결 없이도 이 기기에서 영수증 후보를 수정하고 입고할 수 있어요.'),
                  if (aiParsing) const LinearProgressIndicator(),
                  if (aiMessage.isNotEmpty) InfoBox(aiMessage),
                  ExpansionTile(
                    title: Text(
                      widget.source == 'ocr' && ai.isConfigured
                          ? '전송할 원문 확인 · 수정'
                          : '입력 원문 보기',
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: widget.source == 'ocr' && ai.isConfigured
                            ? TextField(
                                key: const ValueKey('receipt-source-editor'),
                                controller: sourceText,
                                enabled: !busy,
                                minLines: 3,
                                maxLines: 8,
                                decoration: const InputDecoration(
                                  labelText: 'AI에 보낼 내용',
                                  helperText: '이름·주소·회원정보 등 남은 개인정보를 지울 수 있어요.',
                                ),
                              )
                            : SelectableText(widget.rawText),
                      ),
                    ],
                  ),
                  if (drafts.isEmpty)
                    const InfoBox('품목 후보를 찾지 못했어요. 원문을 참고해 직접 추가해주세요.'),
                  ...drafts.asMap().entries.map(
                    (e) => Card(
                      child: Column(
                        children: [
                          CheckboxListTile(
                            value: chosen.contains(e.value.id),
                            onChanged: busy || needsReview.contains(e.value.id)
                                ? null
                                : (v) => setState(() {
                                    v == true
                                        ? chosen.add(e.value.id)
                                        : chosen.remove(e.value.id);
                                  }),
                            title: Text(e.value.name),
                            subtitle: Text(
                              '${quantityText(e.value)} · ${storageLabel(e.value.storageType)} · ${expiryText(e.value)}',
                            ),
                          ),
                          if (evidence[e.value.id] case final String original)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Text('원문 근거: $original'),
                            ),
                          if (needsReview.contains(e.value.id))
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                '수량·단위 미확인 · 항목 수정에서 확인해야 선택할 수 있어요.',
                              ),
                            ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => editCandidate(e.key),
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('항목 수정'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => editCandidate(null),
                    child: const Text('빠진 재료 추가'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy || chosen.isEmpty ? null : save,
                  child: Text(busy ? '저장 중…' : '선택한 ${chosen.length}개 항목 입고'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Future<void> save() async {
    if (busy || chosen.isEmpty) return;
    setState(() => busy = true);
    try {
      final selected = drafts.where((b) => chosen.contains(b.id)).toList();
      if (!await confirm(
            context,
            '입고 내용을 확인해주세요',
            selected
                .map(
                  (b) =>
                      '${b.name} ${quantityText(b)} · ${storageLabel(b.storageType)}',
                )
                .join('\n'),
            action: '확인하고 입고',
          ) ||
          !mounted) {
        return;
      }
      if (initialMode != widget.store.isDemo) {
        inform(context, '보관함 모드가 바뀌었어요. 현재 모드에서 후보를 다시 확인해주세요.');
        return;
      }
      final requestId = 'intake_${selected.map((b) => b.id).join('_')}';
      if (widget.source == 'ocr') {
        final digest =
            widget.receiptDigest ?? receiptFingerprint(widget.rawText);
        Future<void> register([String? confirmedPrevious]) =>
            widget.store.addReceipt(
              selected,
              digest: digest,
              expectedDemo: initialMode,
              requestId: requestId,
              confirmedPreviousChangeId: confirmedPrevious,
            );
        try {
          await register();
        } on DuplicateReceipt catch (duplicate) {
          if (!mounted) return;
          final oldItems = duplicate.previousChange.after
              .map((b) => '${b.name} ${quantityText(b)}')
              .join(', ');
          if (!await confirm(
                context,
                '이미 입고한 영수증과 내용이 같아요',
                '이전 입고: $oldItems\n별도 구매 또는 누락된 품목이 맞을 때만 추가해주세요.',
                action: '별도 입고로 추가',
              ) ||
              !mounted) {
            return;
          }
          await register(duplicate.previousChange.id);
        }
      } else {
        await widget.store.addMany(
          selected,
          source: widget.source,
          requestId: requestId,
          expectedDemo: initialMode,
        );
      }
      if (mounted) {
        if (!widget.returnChangeId) {
          informUndo(context, widget.store, '선택한 재료를 입고했어요.');
        }
        allowExit = true;
        if (widget.returnChangeId) {
          final change = widget.store.history
              .where((c) => c.requestId == requestId && !c.undone)
              .firstOrNull;
          Navigator.pop(context, change?.id);
        } else {
          Navigator.pop(context);
        }
      }
    } catch (_) {
      if (mounted) inform(context, '저장하지 못했어요. 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

List<InventoryBatch> localIntakeCandidates(String raw, StorageType storage) {
  final text = raw.replaceAllMapped(
    RegExp(r'(\d),(?=\d{3}(?:\D|$))'),
    (m) => m[1]!,
  );
  final parts = text.split(RegExp(r'\s*[,，;\n]\s*|\s+(?:그리고|및)\s+'));
  if (parts.length > 30) return [];
  final item = RegExp(
    r'^(.+?)\s*(\d+(?:\.\d+)?)\s*(kg|ml|g|L|개|팩|봉|병|캔)\s*(?:추가해\s*줘|추가|등록해\s*줘|등록)?[.!]?$',
  );
  final embeddedQuantity = RegExp(
    r'\d\s*(?:kg|ml|g|L|개|팩|봉|병|캔)(?:\s|와|과|하고|랑|$)',
  );
  final result = <InventoryBatch>[];
  final stamp = DateTime.now().microsecondsSinceEpoch;
  for (final part in parts) {
    final match = item.firstMatch(part.trim());
    if (match == null) return [];
    final name = match[1]!.trim();
    final qty = double.tryParse(match[2]!);
    if (!RegExp(r'[가-힣A-Za-z]').hasMatch(name) ||
        name.length > 40 ||
        embeddedQuantity.hasMatch(name) ||
        qty == null ||
        !qty.isFinite ||
        qty <= 0 ||
        qty > 100000) {
      return [];
    }
    result.add(
      InventoryBatch(
        id: 'voice_${stamp}_${result.length}',
        name: name,
        quantity: qty,
        unit: match[3]!,
        storageType: storage,
      ),
    );
  }
  return result;
}

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.store, this.initialText = ''});
  final InventoryStore store;
  final String initialText;
  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final speech = SpeechToText();
  final ai = AiService();
  late final text = TextEditingController(text: widget.initialText);
  bool busy = false;
  bool listening = false;
  String message = '마이크 버튼을 누르고 말해주세요. 글로 입력해도 됩니다.';
  @override
  void dispose() {
    speech.cancel();
    ai.dispose();
    text.dispose();
    super.dispose();
  }

  Future<void> listen() async {
    if (listening) {
      await speech.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    try {
      final available = await speech.initialize(
        onError: (_) {
          if (mounted) {
            setState(() {
              listening = false;
              message = '음성을 사용할 수 없어요. 아래에 글로 입력해주세요.';
            });
          }
        },
        onStatus: (s) {
          if (mounted && s != 'listening') setState(() => listening = false);
        },
      );
      if (!mounted) return;
      if (!available) {
        setState(() => message = '마이크 권한 또는 음성 서비스를 사용할 수 없어요. 글로 입력할 수 있습니다.');
        return;
      }
      setState(() => listening = true);
      await speech.listen(
        listenOptions: SpeechListenOptions(localeId: 'ko_KR'),
        onResult: (r) {
          if (mounted) setState(() => text.text = r.recognizedWords);
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          listening = false;
          message = '음성 연결에 실패했어요. 글로 입력해주세요.';
        });
      }
    }
  }

  Future<void> previewLocal() async {
    if (busy) return;
    final raw = text.text.trim();
    final mode = widget.store.isDemo;
    final storage = await preferredStorage();
    if (!mounted || mode != widget.store.isDemo) return;
    final batches = localIntakeCandidates(raw, storage);
    if (batches.isEmpty) {
      inform(context, '“두부 1개, 우유 2팩”처럼 품목마다 이름·수량·단위를 입력해주세요.');
      return;
    }
    await speech.stop();
    if (!mounted || mode != widget.store.isDemo) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CandidateScreen(
          store: widget.store,
          rawText: raw,
          source: 'voice_or_text',
          drafts: batches,
        ),
      ),
    );
  }

  Future<void> previewAi() async {
    if (busy || !ai.isConfigured || text.text.trim().isEmpty) return;
    await speech.stop();
    if (!mounted) return;
    final mode = widget.store.isDemo;
    final raw = redactReceipt(text.text.trim());
    setState(() {
      busy = true;
      listening = false;
    });
    try {
      final storage = await preferredStorage();
      if (!mounted || mode != widget.store.isDemo) return;
      final candidates = await IntakeAiService(ai).parse(raw, storage: storage);
      if (!mounted || mode != widget.store.isDemo) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => CandidateScreen(
            store: widget.store,
            rawText: raw,
            source: 'ai_text',
            candidates: candidates,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'AI로 정리하지 못했어요. 다시 시도하거나 간단 입력 확인을 이용해주세요. 입력은 그대로 남아 있어요.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('말 또는 글로 등록')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 30),
          Icon(
            listening ? Icons.graphic_eq : Icons.mic_none,
            size: 80,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: busy ? null : listen,
            icon: Icon(listening ? Icons.stop : Icons.mic),
            label: Text(listening ? '듣기 종료' : '마이크로 말하기'),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: text,
            enabled: !busy,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '음성 결과 또는 텍스트 명령',
              hintText: '우유 2개, 달걀 6개, 두부 1팩 샀어',
            ),
          ),
          InfoBox(
            ai.isConfigured
                ? 'AI로 정리를 누르면 입력이 AI 서비스로 전송됩니다. 여러 품목을 적고 다음 화면에서 수정·선택해주세요. 소비기한은 추정하지 않습니다.'
                : '쉼표로 구분해 재료 이름과 수량을 입력하면 이 기기에서 여러 품목을 확인할 수 있어요.',
          ),
          if (busy) const LinearProgressIndicator(),
          if (ai.isConfigured)
            FilledButton(
              onPressed: busy ? null : previewAi,
              child: const Text('AI로 여러 품목 정리'),
            ),
          OutlinedButton(
            onPressed: busy ? null : previewLocal,
            child: const Text('간단 입력 확인 · AI 없이'),
          ),
          const Text('간단 입력 예: 두부 1개 추가'),
        ],
      ),
    ),
  );
}
