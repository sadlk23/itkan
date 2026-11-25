import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';

enum IntakePhotoUse { receipt, newIngredient, editIngredient, candidate }

/// The parent review must survive a photo selection inside a candidate editor.
class CandidatePhotoContext {
  const CandidatePhotoContext({
    required this.source,
    required this.text,
    required this.batches,
    required this.chosen,
    required this.needsReview,
    required this.evidence,
    required this.createdPhotos,
    this.editIndex,
    this.receiptDigest,
  });
  final String source, text;
  final List<InventoryBatch> batches;
  final Set<String> chosen, needsReview, createdPhotos;
  final Map<String, String> evidence;
  final int? editIndex;
  final String? receiptDigest;

  Map<String, dynamic> toJson() => {
    'source': source,
    'text': text,
    'batches': batches.map((b) => b.toJson()).toList(),
    'chosen': chosen.toList(),
    'needsReview': needsReview.toList(),
    'evidence': evidence,
    'createdPhotos': createdPhotos.toList(),
    'editIndex': editIndex,
    'receiptDigest': receiptDigest,
  };
  factory CandidatePhotoContext.fromJson(Map<String, dynamic> data) =>
      CandidatePhotoContext(
        source: data['source'] as String,
        text: data['text'] as String,
        batches: (data['batches'] as List)
            .map((b) => InventoryBatch.fromJson(b as Map<String, dynamic>))
            .toList(),
        chosen: (data['chosen'] as List).cast<String>().toSet(),
        needsReview: (data['needsReview'] as List).cast<String>().toSet(),
        evidence: Map<String, String>.from(data['evidence'] as Map),
        createdPhotos: (data['createdPhotos'] as List).cast<String>().toSet(),
        editIndex: data['editIndex'] as int?,
        receiptDigest: data['receiptDigest'] as String?,
      );
}

class IntakePhotoRequest {
  const IntakePhotoRequest({
    required this.use,
    required this.demo,
    this.original,
    this.form,
    this.draftPhotos = const {},
    this.candidate,
  });
  final IntakePhotoUse use;
  final bool demo;
  final InventoryBatch? original;
  final Map<String, dynamic>? form;
  final Set<String> draftPhotos;
  final CandidatePhotoContext? candidate;

  Set<String> get temporaryPhotos => {
    ...draftPhotos,
    ...?candidate?.createdPhotos,
  };
  bool get hasValidContext {
    if (use == IntakePhotoUse.receipt) {
      return original == null && candidate == null;
    }
    final fields = form;
    if (fields == null ||
        fields['name'] is! String ||
        fields['quantity'] is! String ||
        fields['unit'] is! String ||
        fields['category'] is! String ||
        fields['photoFile'] != null && fields['photoFile'] is! String ||
        !StorageType.values.any((e) => e.name == fields['storage']) ||
        !ExpiryStatus.values.any((e) => e.name == fields['status']) ||
        !OpenedStatus.values.any((e) => e.name == fields['openedStatus']) ||
        !QuantityMode.values.any((e) => e.name == fields['quantityMode']) ||
        !StockLevel.values.any((e) => e.name == fields['stockLevel']) ||
        fields['date'] != null &&
            (fields['date'] is! String ||
                DateTime.tryParse(fields['date'] as String) == null)) {
      return false;
    }
    if (use == IntakePhotoUse.newIngredient) {
      return original == null && candidate == null;
    }
    if (use == IntakePhotoUse.editIngredient) {
      return original != null && candidate == null;
    }
    final review = candidate;
    if (review == null) return false;
    final index = review.editIndex;
    return index == null
        ? original == null
        : index >= 0 &&
              index < review.batches.length &&
              review.batches[index].id == original?.id;
  }

  Map<String, dynamic> toJson() => {
    'use': use.name,
    'demo': demo,
    'original': original?.toJson(),
    'form': form,
    'draftPhotos': draftPhotos.toList(),
    'candidate': candidate?.toJson(),
  };
  factory IntakePhotoRequest.fromJson(Map<String, dynamic> data) =>
      IntakePhotoRequest(
        use: IntakePhotoUse.values.byName(data['use'] as String),
        demo: data['demo'] as bool,
        original: data['original'] == null
            ? null
            : InventoryBatch.fromJson(data['original'] as Map<String, dynamic>),
        form: data['form'] as Map<String, dynamic>?,
        draftPhotos: (data['draftPhotos'] as List).cast<String>().toSet(),
        candidate: data['candidate'] == null
            ? null
            : CandidatePhotoContext.fromJson(
                data['candidate'] as Map<String, dynamic>,
              ),
      );
}

class PendingImagePicker {
  PendingImagePicker({
    ImagePicker? picker,
    this.cacheDirectory = getTemporaryDirectory,
    this.isForeground = _appIsResumed,
    bool? android,
  }) : _picker = picker ?? ImagePicker(),
       _android =
           android ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static final instance = PendingImagePicker();
  static const preferenceKey = 'intake_pending_image_v1';
  final ImagePicker _picker;
  final bool _android;
  final Future<Directory> Function() cacheDirectory;
  final bool Function() isForeground;
  bool _active = false;
  static bool _appIsResumed() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  static const _device = MethodChannel('eatkan/device');

  Future<LostDataResponse> _lostResult() async {
    try {
      return await _picker.retrieveLostData();
    } on MissingPluginException {
      return LostDataResponse.empty();
    } on PlatformException {
      return LostDataResponse.empty();
    }
  }

  // The Android plugin copies gallery media to a fresh UUID directory and
  // camera media to a UUID-prefixed filename in the private cache root.
  static const _uuid =
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
  static final _galleryFolder = RegExp('^$_uuid\$');
  static final _cameraFile = RegExp(
    '^$_uuid[0-9]+\\.(?:jpg|jpeg|png|heic|webp)\$',
    caseSensitive: false,
  );

  Future<File?> _ownedPickerFile(String path) async {
    if (!p.isAbsolute(path) || p.split(path).contains('..')) return null;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final root = await cacheDirectory();
    final physicalRoot = await root.resolveSymbolicLinks();
    final normalized = p.normalize(path);
    final String relative;
    if (p.isWithin(root.path, normalized)) {
      relative = p.relative(normalized, from: root.path);
    } else if (p.isWithin(physicalRoot, normalized)) {
      relative = p.relative(normalized, from: physicalRoot);
    } else {
      return null;
    }
    final parts = p.split(relative);
    final gallery = parts.length == 2 && _galleryFolder.hasMatch(parts.first);
    final camera = parts.length == 1 && _cameraFile.hasMatch(parts.single);
    // Also clean resized files returned for a selection started by older code.
    final resized = parts.length == 1 && parts.single.startsWith('scaled_');
    if (!gallery && !camera && !resized) return null;
    final actual = await File(path).resolveSymbolicLinks();
    return actual == p.join(physicalRoot, relative) ? File(actual) : null;
  }

  Future<void> _deleteReturnedFile(String path) async {
    // A desktop file chooser can return the user's original.
    if (!_android) {
      return;
    }
    try {
      final file = await _ownedPickerFile(path);
      if (file == null) return;
      await file.delete();
      if (_galleryFolder.hasMatch(p.basename(file.parent.path))) {
        // Nonrecursive: a second file in that directory belongs to its owner.
        await file.parent.delete();
      }
    } on FileSystemException {
      // The OS may already have reclaimed the cached file.
    }
  }

  Future<T?> select<T>(
    IntakePhotoRequest? request,
    ImageSource source,
    Future<T> Function(XFile) read,
  ) async {
    if (_active) throw StateError('다른 사진을 확인하는 중이에요.');
    _active = true;
    SharedPreferences? prefs;
    XFile? image;
    try {
      if (_android && request != null) {
        prefs = await SharedPreferences.getInstance();
        if (!await prefs.setString(
          preferenceKey,
          jsonEncode({'request': request.toJson()}),
        )) {
          throw StateError('작성 중인 내용을 보관하지 못했어요.');
        }
        await _device.invokeMethod<void>('beginImagePick');
      }
      // On Android resizing inside the picker can leave a second, unreturned
      // gallery copy in the cache. Read the single original copy instead.
      image = await _picker.pickImage(
        source: source,
        requestFullMetadata: false,
      );
      if (image == null) return null;
      if (prefs != null && request != null) {
        final owned = await _ownedPickerFile(image.path);
        if (owned != null) {
          await prefs.setString(
            preferenceKey,
            jsonEncode({'request': request.toJson(), 'cacheFile': owned.path}),
          );
        }
      }
      return await read(image);
    } finally {
      try {
        if (image != null) await _deleteReturnedFile(image.path);
        if (prefs != null) await prefs.remove(preferenceKey);
      } finally {
        _active = false;
      }
    }
  }

  /// Consume the plugin's one-shot response even for abandoned or legacy picks.
  /// Release the picker and remove the cache before opening the next editor.
  Future<T?> recover<T>(
    Future<T?> Function(IntakePhotoRequest request, XFile? image) prepare,
  ) async {
    if (!_android || _active || !isForeground()) return null;
    _active = true;
    SharedPreferences? prefs;
    final paths = <String>{};
    bool retainPending = false;
    try {
      prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(preferenceKey);
      final saved = raw == null
          ? null
          : jsonDecode(raw) as Map<String, dynamic>;
      final cached = saved?['cacheFile'] as String?;
      var result = await _lostResult();
      if (saved != null && cached == null && result.isEmpty) {
        // Android may recreate Flutter underneath the picker. Even after
        // onActivityResult the plugin copies the selected URI on a worker.
        // An empty plugin response alone never proves a selection was cancelled.
        retainPending = true;
        var outcome = await _device.invokeMethod<String>('imagePickerResult');
        for (
          var attempt = 0;
          attempt < 3 && outcome == null && isForeground();
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          if (isForeground()) {
            outcome = await _device.invokeMethod<String>('imagePickerResult');
          }
        }
        if (outcome == 'selected') {
          for (
            var attempt = 0;
            attempt < 120 && isForeground() && result.isEmpty;
            attempt++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            if (isForeground()) result = await _lostResult();
          }
        }
        if (result.isEmpty && outcome != 'cancelled') return null;
        retainPending = false;
      }
      final files =
          result.files ?? (result.file == null ? <XFile>[] : [result.file!]);
      paths.addAll(files.map((f) => f.path));
      if (saved == null) return null;
      XFile? selected = result.exception == null ? files.firstOrNull : null;
      if (cached != null) {
        final owned = await _ownedPickerFile(cached);
        if (owned != null) {
          paths.add(owned.path);
          selected ??= XFile(owned.path);
        }
      }
      if (selected != null && selected.path != cached) {
        final owned = await _ownedPickerFile(selected.path);
        if (owned != null) {
          saved['cacheFile'] = owned.path;
          await prefs.setString(preferenceKey, jsonEncode(saved));
        }
      }
      if (!isForeground()) {
        retainPending = true;
        return null;
      }
      final request = IntakePhotoRequest.fromJson(
        saved['request'] as Map<String, dynamic>,
      );
      if (!request.hasValidContext) {
        throw const FormatException('중단된 사진 입력을 확인할 수 없어요. 다시 선택해주세요.');
      }
      return await prepare(request, selected);
    } finally {
      try {
        if (!retainPending) {
          for (final path in paths) {
            await _deleteReturnedFile(path);
          }
          if (prefs != null) await prefs.remove(preferenceKey);
        }
      } finally {
        _active = false;
      }
    }
  }
}
