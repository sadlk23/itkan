import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/screens/batch_form.dart';
import 'package:my_fridge/screens/intake_screen.dart';
import 'package:my_fridge/services/ingredient_photo_service.dart';
import 'package:my_fridge/services/inventory_store.dart';
import 'package:my_fridge/services/pending_image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NativePicker extends ImagePicker {
  _NativePicker({this.pick, this.lost, this.retrieve});
  final Future<XFile?> Function()? pick;
  final XFile? lost;
  final Future<LostDataResponse> Function()? retrieve;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => pick?.call();

  @override
  Future<LostDataResponse> retrieveLostData() async {
    if (retrieve case final callback?) return callback();
    return lost == null
        ? LostDataResponse.empty()
        : LostDataResponse(files: [lost!]);
  }
}

class _RecoveredReceipt extends PendingImagePicker {
  @override
  Future<T?> recover<T>(
    Future<T?> Function(IntakePhotoRequest, XFile?) prepare,
  ) => prepare(_receipt, XFile('fixture.jpg'));
}

class _MemoryInventory extends InventoryStore {
  final rows = <InventoryBatch>[];
  final sources = <String>[];
  bool demo = false;
  @override
  bool get isDemo => demo;
  @override
  List<InventoryBatch> get batches => rows;
  @override
  Future<Set<String>> referencedPhotoFiles() async =>
      rows.map((b) => b.photoFile).whereType<String>().toSet();
  @override
  Future<void> add(
    InventoryBatch batch, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) async {
    expect(expectedDemo, demo);
    rows.add(batch);
  }

  @override
  Future<void> update(
    InventoryBatch batch, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) async {
    expect(expectedDemo, demo);
    rows[rows.indexWhere((b) => b.id == batch.id)] = batch;
  }

  @override
  Future<void> addMany(
    List<InventoryBatch> items, {
    String source = 'manual',
    String? requestId,
    bool? expectedDemo,
  }) async {
    expect(expectedDemo, demo);
    rows.addAll(items);
    sources.add(source);
  }
}

const _uuid = 'c817ba55-8021-4c7d-a40c-a87b25246ccf';
const _receipt = IntakePhotoRequest(use: IntakePhotoUse.receipt, demo: false);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);

Map<String, dynamic> _fields(String name, String quantity) => {
  'name': name,
  'quantity': quantity,
  'unit': '팩',
  'storage': 'freezer',
  'status': 'estimated',
  'date': '2030-02-12T00:00:00.000',
  'openedStatus': 'opened',
  'quantityMode': 'measured',
  'stockLevel': 'low',
  'category': '가공식품',
  'photoFile': null,
};

Future<void> _startRecovery(
  WidgetTester tester,
  InventoryStore store,
  PendingImagePicker picker, {
  Future<String> Function(String)? readReceipt,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => recoverPendingIntake(
              context,
              store,
              picker: picker,
              readReceipt: readReceipt,
            ),
            child: const Text('보관함 열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('보관함 열기'));
  await tester.pumpAndSettle();
}

void _largeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(820, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  String? nativeOutcome;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    nativeOutcome = 'cancelled';
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('eatkan/device'),
      (call) async => call.method == 'imagePickerResult' ? nativeOutcome : null,
    );
  });

  test('background startup and early empty responses preserve the pending marker until Android returns the image', () async {
    var foreground = false;
    var reads = 0;
    nativeOutcome = null;
    final root = await Directory.systemTemp.createTemp('itkan_recovery_race_');
    addTearDown(() => root.delete(recursive: true));
    final file = await File(p.join(root.path, '${_uuid}4821.jpg'))
        .writeAsBytes(_png);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PendingImagePicker.preferenceKey,
      jsonEncode({'request': _receipt.toJson()}),
    );
    final picker = PendingImagePicker(
      android: true,
      isForeground: () => foreground,
      cacheDirectory: () async => root,
      picker: _NativePicker(
        retrieve: () async {
          reads++;
          return reads >= 3
              ? LostDataResponse(files: [XFile(file.path)])
              : LostDataResponse.empty();
        },
      ),
    );
    await picker.recover<void>((_, _) async => fail('in background'));
    expect(reads, 0);
    foreground = true;
    await picker.recover<void>((_, _) async => fail('picker has not returned'));
    expect(prefs.containsKey(PendingImagePicker.preferenceKey), isTrue);
    nativeOutcome = 'selected';
    expect(
      await picker.recover<bool>(
        (_, image) async => await File(image!.path).exists(),
      ),
      isTrue,
    );
    expect(reads, 3);
    expect(await file.exists(), isFalse);
    expect(prefs.containsKey(PendingImagePicker.preferenceKey), isFalse);
  });

  test('only the exact picker-returned private copy is removed after reading, including failure', () async {
    final root = await Directory.systemTemp.createTemp('itkan_picker_');
    addTearDown(() => root.delete(recursive: true));
    final cache = await Directory(p.join(root.path, 'cache')).create();
    final folder = await Directory(p.join(cache.path, _uuid)).create();
    final receipt = await File(p.join(folder.path, '영수증.jpg'))
        .writeAsString('sample');
    final sibling = await File(p.join(folder.path, 'retained'))
        .writeAsString('other');
    final external = await File(p.join(root.path, 'gallery.jpg'))
        .writeAsString('gallery');
    final unrelated = await File(p.join(cache.path, 'settings.dat'))
        .writeAsString('app');
    final symlink = await Link(p.join(folder.path, 'alias.jpg'))
        .create(external.path);
    final prefs = await SharedPreferences.getInstance();
    for (final path in [
      receipt.path,
      external.path,
      unrelated.path,
      symlink.path,
    ]) {
      final picker = PendingImagePicker(
        android: true,
        cacheDirectory: () async => cache,
        picker: _NativePicker(
          pick: () async {
            final saved = jsonDecode(
              prefs.getString(PendingImagePicker.preferenceKey)!,
            )['request'];
            expect(saved['use'], 'receipt');
            expect(saved['demo'], false);
            return XFile(path);
          },
        ),
      );
      await expectLater(
        picker.select<void>(_receipt, ImageSource.gallery, (image) async {
          expect(await File(image.path).exists(), isTrue);
          throw const FormatException('인식 실패');
        }),
        throwsFormatException,
      );
      expect(prefs.containsKey(PendingImagePicker.preferenceKey), isFalse);
    }
    expect(await receipt.exists(), isFalse);
    expect(await sibling.exists(), isTrue);
    expect(await external.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(await symlink.exists(), isTrue);
    final desktopFile = await File(p.join(folder.path, 'user-photo.png'))
        .writeAsBytes(_png);
    final desktop = PendingImagePicker(
      android: false,
      cacheDirectory: () async => cache,
      picker: _NativePicker(pick: () async => XFile(desktopFile.path)),
    );
    await desktop.select<void>(null, ImageSource.gallery, (_) async {});
    expect(await desktopFile.exists(), isTrue);
  });

  test('losing foreground before the restore dialog keeps the one-shot file for the next resume', () async {
    final folder = await Directory.systemTemp.createTemp('itkan_picker_pause_');
    addTearDown(() => folder.delete(recursive: true));
    final file = await File(p.join(folder.path, '${_uuid}713.jpg'))
        .writeAsBytes(_png);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PendingImagePicker.preferenceKey,
      jsonEncode({'request': _receipt.toJson()}),
    );
    var foreground = true;
    final first = PendingImagePicker(
      android: true,
      isForeground: () => foreground,
      picker: _NativePicker(lost: XFile(file.path)),
      cacheDirectory: () async {
        foreground = false;
        return folder;
      },
    );
    await first.recover<void>(
      (_, _) async => fail('dialog opened while backgrounded'),
    );
    expect(prefs.containsKey(PendingImagePicker.preferenceKey), isTrue);
    expect(await file.exists(), isTrue);
    final resumed = PendingImagePicker(
      android: true,
      isForeground: () => true,
      picker: _NativePicker(),
      cacheDirectory: () async => folder,
    );
    expect(
      await resumed.recover<bool>((_, image) async => image != null),
      isTrue,
    );
    expect(await file.exists(), isFalse);
    expect(prefs.containsKey(PendingImagePicker.preferenceKey), isFalse);
  });

  test('lost data and an interrupted read reclaim only the private camera or gallery copy', () async {
    final root = await Directory.systemTemp.createTemp('itkan_recover_');
    addTearDown(() => root.delete(recursive: true));
    final prefs = await SharedPreferences.getInstance();
    final camera = await File(p.join(root.path, '${_uuid}4859.jpg'))
        .writeAsBytes(_png);
    final photos = IngredientPhotoService(
      directory: Directory(p.join(root.path, 'ingredient_photos')),
    );
    final native = _NativePicker(lost: XFile(camera.path));
    final picker = PendingImagePicker(
      android: true,
      picker: native,
      cacheDirectory: () async => root,
    );
    await prefs.setString(
      PendingImagePicker.preferenceKey,
      jsonEncode({'request': _receipt.toJson()}),
    );
    final name = await picker.recover<String>((request, image) async {
      final during = jsonDecode(
        prefs.getString(PendingImagePicker.preferenceKey)!,
      );
      expect(during['cacheFile'], await camera.resolveSymbolicLinks());
      return photos.importFile(File(image!.path));
    });
    expect(await camera.exists(), isFalse);
    expect(await photos.resolvePath(name!), isNotNull);
    final folder = await Directory(p.join(root.path, _uuid)).create();
    final cacheFile = await File(p.join(folder.path, 'original.jpg'))
        .writeAsBytes(_png);
    await prefs.setString(
      PendingImagePicker.preferenceKey,
      jsonEncode({'request': _receipt.toJson(), 'cacheFile': cacheFile.path}),
    );
    final second = PendingImagePicker(
      android: true,
      picker: _NativePicker(),
      cacheDirectory: () async => root,
    );
    expect(
      await second.recover<bool>(
        (_, file) async => file!.path.endsWith('original.jpg'),
      ),
      isTrue,
    );
    expect(await cacheFile.exists(), isFalse);
    final orphan = await File(p.join(root.path, '${_uuid}5001.jpg'))
        .writeAsBytes(_png);
    final unclaimed = PendingImagePicker(
      android: true,
      picker: _NativePicker(lost: XFile(orphan.path)),
      cacheDirectory: () async => root,
    );
    await unclaimed.recover<void>(
      (_, image) async => fail('unclaimed image reached a form'),
    );
    expect(await orphan.exists(), isFalse);
  });

  testWidgets(
    'receipt recovery asks before reading, masks text and allows offline editing',
    (tester) async {
      _largeView(tester);
      final store = _MemoryInventory();
      var reads = 0;
      await _startRecovery(
        tester,
        store,
        _RecoveredReceipt(),
        readReceipt: (path) async {
          expect(path, 'fixture.jpg');
          reads++;
          return '두부 1팩\n주문번호 927382';
        },
      );
      expect(reads, 0);
      await tester.tap(find.text('이어서 확인'));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(store.rows, isEmpty);
      expect(find.text('AI로 품목 정리하기'), findsNothing);
      expect(find.textContaining('이 기기에서 영수증 후보를 수정'), findsOneWidget);
      await tester.tap(find.text('입력 원문 보기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('[개인정보 가림]'), findsOneWidget);
      expect(find.textContaining('927382'), findsNothing);
      expect(find.text('항목 수정'), findsWidgets);
    },
  );

  test('discard keeps an image used by undo in the other inventory', () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('itkan_photo_undo_');
    addTearDown(() => root.delete(recursive: true));
    final store = InventoryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: p.join(root.path, 'inventory.db'),
    );
    await store.initialize();
    addTearDown(store.close);
    await store.setDemoMode(false);
    final photos = IngredientPhotoService(
      directory: Directory(p.join(root.path, 'photos')),
    );
    final original = await File(p.join(root.path, 'gallery.png'))
        .writeAsBytes(_png);
    final kept = await photos.importFile(original);
    final abandoned = await photos.importFile(original);
    await store.add(
      InventoryBatch(
        id: 'tofu',
        name: '두부',
        quantity: 1,
        unit: '개',
        photoFile: kept,
      ),
    );
    await store.update(store.batches.single.copyWith(photoFile: null));
    final editId = store.history.first.id;
    await store.setDemoMode(true);
    await photos.discardUnreferenced(store, {kept, abandoned});
    expect(await photos.resolvePath(abandoned), isNull);
    expect(await photos.resolvePath(kept), isNotNull);
    await store.setDemoMode(false);
    await store.undo(editId);
    expect(store.batches.single.photoFile, kept);
    expect(await original.exists(), isTrue);
  });

  test('large ingredient images are resized after selection without touching the original', () async {
    final root = await Directory.systemTemp.createTemp('itkan_photo_resize_');
    addTearDown(() => root.delete(recursive: true));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff00ff00), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final sourceImage = await picture.toImage(1800, 180);
    final encoded = await sourceImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    picture.dispose();
    sourceImage.dispose();
    final file = await File(p.join(root.path, 'gallery.png'))
        .writeAsBytes(encoded!.buffer.asUint8List());
    final photos = IngredientPhotoService(
      directory: Directory(p.join(root.path, 'photos')),
    );
    final name = await photos.importPickedFile(file);
    final buffer = await ui.ImmutableBuffer.fromFilePath(
      (await photos.resolvePath(name))!,
    );
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    expect((descriptor.width, descriptor.height), (1600, 160));
    expect(await file.readAsBytes(), encoded.buffer.asUint8List());
    descriptor.dispose();
    buffer.dispose();
  });

  testWidgets(
    'an interrupted purchase photo restores its editor, chosen rows and final approval',
    (tester) async {
      _largeView(tester);
      final store = _MemoryInventory();
      final suspended = Completer<XFile?>();
      final picker = PendingImagePicker(
        picker: _NativePicker(pick: () => suspended.future),
        android: true,
      );
      final photoService = IngredientPhotoService(picker: picker);
      final tofu = InventoryBatch(
        id: 'purchase-1',
        ingredientId: 'linked-tofu',
        name: '두부',
        quantity: 2,
        unit: '팩',
      );
      final milk = InventoryBatch(
        id: 'purchase-2',
        ingredientId: 'linked-milk',
        name: '우유',
        quantity: 1,
        unit: '팩',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CandidateScreen(
            store: store,
            source: 'shopping',
            rawText: '두부 2팩, 우유 1팩',
            drafts: [tofu, milk],
            photoService: photoService,
          ),
        ),
      );
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.tap(find.text('항목 수정').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '저지방 우유');
      await tester.enterText(
        find.byKey(const ValueKey('batch-quantity')),
        '2.50',
      );
      final select = find.byKey(const ValueKey('batch-photo-pick'));
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      final pending = jsonDecode(
        prefs.getString(PendingImagePicker.preferenceKey)!,
      ) as Map<String, dynamic>;
      final request = IntakePhotoRequest.fromJson(
        pending['request'] as Map<String, dynamic>,
      );
      expect(request.use, IntakePhotoUse.candidate);
      expect(request.demo, isFalse);
      expect(request.candidate!.chosen, {'purchase-1'});
      expect(request.candidate!.editIndex, 1);
      expect(request.form!['quantity'], '2.50');
      await tester.pumpWidget(const SizedBox.shrink());
      await _startRecovery(
        tester,
        store,
        PendingImagePicker(android: true, picker: _NativePicker()),
      );
      await tester.tap(find.text('이어서 확인'));
      await tester.pumpAndSettle();
      expect(find.byType(BatchForm), findsOneWidget);
      expect(find.text('저지방 우유'), findsOneWidget);
      expect(find.text('2.50'), findsOneWidget);
      expect(store.rows, isEmpty);
      final done = find.text('후보 수정 완료');
      await tester.ensureVisible(done);
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(find.text('선택한 1개 항목 입고'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pump();
      await tester.tap(find.text('선택한 2개 항목 입고'));
      await tester.pumpAndSettle();
      expect(store.rows, isEmpty);
      await tester.tap(find.text('확인하고 입고'));
      await tester.pumpAndSettle();
      expect(store.rows.map((b) => b.ingredientId), [
        'linked-tofu',
        'linked-milk',
      ]);
      expect(store.rows.last.quantity, 2.5);
      expect(store.sources, ['shopping']);
      suspended.complete(null);
      await tester.pump();
    },
  );

  testWidgets(
    'new and existing forms recover only after mode and original revision match',
    (tester) async {
      _largeView(tester);
      final store = _MemoryInventory();
      final picker = PendingImagePicker(android: true, picker: _NativePicker());
      final prefs = await SharedPreferences.getInstance();
      final create = IntakePhotoRequest(
        use: IntakePhotoUse.newIngredient,
        demo: false,
        form: _fields('버섯', '3.75'),
      );
      Future<void> start(IntakePhotoRequest request) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await prefs.setString(
          PendingImagePicker.preferenceKey,
          jsonEncode({'request': request.toJson()}),
        );
        await _startRecovery(tester, store, picker);
      }

      await start(create);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(store.rows, isEmpty);
      await start(create);
      await tester.tap(find.text('이어서 확인'));
      await tester.pumpAndSettle();
      expect(find.text('3.75'), findsOneWidget);
      final button = find.text('입력 내용 확인');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(store.rows, isEmpty);
      await tester.tap(find.text('확인하고 저장'));
      await tester.pumpAndSettle();
      final original = store.rows.single;
      expect(original.storageType, StorageType.freezer);
      expect(original.openedStatus, OpenedStatus.opened);
      expect(original.expiryStatus, ExpiryStatus.estimated);
      expect(original.expiryDate, DateTime(2030, 2, 12));
      final edit = IntakePhotoRequest(
        use: IntakePhotoUse.editIngredient,
        demo: false,
        original: original,
        form: _fields('새송이버섯', '4.50'),
      );
      store.demo = true;
      await start(edit);
      expect(find.text('이어서 확인'), findsNothing);
      expect(store.rows.single.name, '버섯');
      store.demo = false;
      store.rows[0] = original.copyWith(revision: original.revision + 1);
      await start(edit);
      expect(find.text('이어서 확인'), findsNothing);
      expect(store.rows.single.quantity, 3.75);
      store.rows[0] = original;
      await start(edit);
      await tester.tap(find.text('이어서 확인'));
      await tester.pumpAndSettle();
      expect(find.text('새송이버섯'), findsOneWidget);
      expect(store.rows.single.name, '버섯');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인하고 저장'));
      await tester.pumpAndSettle();
      expect(store.rows.single.id, original.id);
      expect(store.rows.single.name, '새송이버섯');
    },
  );
}
