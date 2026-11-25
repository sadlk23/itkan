import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/ingredient_photo_service.dart';

void main() {
  test(
    'photo references round trip, preserve, clear and support old records',
    () {
      final batch = InventoryBatch(
        id: 'a',
        name: '두부',
        quantity: 1,
        unit: '개',
        photoFile: 'local.png',
      );
      expect(InventoryBatch.fromJson(batch.toJson()).photoFile, 'local.png');
      expect(batch.copyWith(name: '연두부').photoFile, 'local.png');
      expect(batch.copyWith(photoFile: null).photoFile, isNull);
      final old = batch.toJson()..remove('photoFile');
      expect(InventoryBatch.fromJson(old).photoFile, isNull);
    },
  );

  test(
    'imports local copy, rejects traversal and removes only named draft',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'ingredient_photo_test_',
      );
      try {
        final service = IngredientPhotoService(
          directory: Directory('${folder.path}/photos'),
        );
        final source = File('${folder.path}/source.png');
        await source.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
          ),
        );
        final name = await service.importFile(source);
        expect(name, startsWith('ingredient_'));
        final path = await service.resolvePath(name);
        expect(path, isNotNull);
        expect(await File(path!).readAsBytes(), await source.readAsBytes());
        expect(await service.resolvePath('../source.png'), isNull);
        expect(await service.resolvePath(source.path), isNull);
        final another = await service.importFile(source);
        await service.deleteDraft(name);
        expect(await service.resolvePath(name), isNull);
        expect(await service.resolvePath(another), isNotNull);
        expect(await source.exists(), isTrue);
        await source.writeAsString('not an image');
        await expectLater(service.importFile(source), throwsFormatException);
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );
}
