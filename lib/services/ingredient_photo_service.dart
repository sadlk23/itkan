import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'inventory_store.dart';
import 'pending_image_picker.dart';

/// Local-only gallery copies. Persist only the generated basename, never a
/// picker path. Committed files are retained because undo may reference them.
class IngredientPhotoService {
  IngredientPhotoService({this.directory, this.picker});
  final Directory? directory;
  final PendingImagePicker? picker;
  static final _validName = RegExp(
    r'^ingredient_[0-9]+_[a-f0-9]{16}\.(jpg|png|webp|gif)$',
  );

  Future<Directory> _folder() async {
    final folder =
        directory ??
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'ingredient_photos',
          ),
        );
    await folder.create(recursive: true);
    return folder;
  }

  Future<String?> pickGallery({IntakePhotoRequest? request}) =>
      (picker ?? PendingImagePicker.instance).select(
        request,
        ImageSource.gallery,
        (image) => importPickedFile(File(image.path)),
      );

  /// Resize large photos in memory to retain the 1600-pixel ingredient image
  /// limit without making a second, untracked gallery cache file.
  Future<String> importPickedFile(File source) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final longest = max(descriptor.width, descriptor.height);
      if (longest <= 1600 && buffer.length <= 15 * 1024 * 1024) {
        try {
          return await importFile(source);
        } on FormatException {
          // A platform-decodable format such as HEIF needs a portable copy.
        }
      }
      final scale = min(1.0, 1600 / longest);
      codec = await descriptor.instantiateCodec(
        targetWidth: max(1, (descriptor.width * scale).round()),
        targetHeight: max(1, (descriptor.height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw const FormatException('사진을 읽지 못했어요.');
      return await _writePhoto(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        'png',
      );
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<String> importFile(File source) async {
    if (await source.length() > 15 * 1024 * 1024) {
      throw const FormatException('사진은 15MB 이하로 선택해주세요.');
    }
    final bytes = await source.readAsBytes();
    String? extension;
    if (bytes.length >= 12) {
      if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
        extension = 'jpg';
      }
      if (bytes[0] == 137 &&
          bytes[1] == 80 &&
          bytes[2] == 78 &&
          bytes[3] == 71) {
        extension = 'png';
      }
      if (String.fromCharCodes(bytes.take(6)) == 'GIF89a' ||
          String.fromCharCodes(bytes.take(6)) == 'GIF87a') {
        extension = 'gif';
      }
      if (String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
          String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
        extension = 'webp';
      }
    }
    if (extension == null) throw const FormatException('지원하는 사진 파일을 선택해주세요.');
    return _writePhoto(bytes, extension);
  }

  Future<String> _writePhoto(Uint8List bytes, String extension) async {
    final random = Random.secure();
    final nonce = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final basename =
        'ingredient_${DateTime.now().microsecondsSinceEpoch}_$nonce.$extension';
    final folder = await _folder();
    final output = File(p.join(folder.path, basename));
    try {
      await output.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      if (await output.exists()) await output.delete();
      rethrow;
    }
    return basename;
  }

  Future<String?> resolvePath(String basename) async {
    if (!_validName.hasMatch(basename)) return null;
    final folder = await _folder();
    final candidate = p.join(folder.path, basename);
    // Do not follow symbolic links, even if an imported record names one.
    if (await FileSystemEntity.type(candidate, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    return candidate;
  }

  Future<void> deleteDraft(String basename) async {
    final path = await resolvePath(basename);
    if (path != null) await File(path).delete();
  }

  /// Check both inventories and their undo snapshots before removing copies
  /// left behind by a discarded form or an interrupted photo selection.
  Future<void> discardUnreferenced(
    InventoryStore store,
    Set<String> created,
  ) async {
    if (created.isEmpty) return;
    try {
      final referenced = await store.referencedPhotoFiles();
      for (final name in created.difference(referenced)) {
        try {
          await deleteDraft(name);
        } on FileSystemException {
          // Other cleanup or the OS may already have removed this draft.
        }
      }
    } catch (_) {
      // Keep files if either inventory or its undo history cannot be checked.
    }
  }
}
