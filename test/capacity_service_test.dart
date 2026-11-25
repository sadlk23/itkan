import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/models/inventory.dart';
import 'package:my_fridge/services/capacity_service.dart';

void main() {
  final now = DateTime(2026, 11, 6);
  InventoryBatch item(
    String id, {
    double qty = 500,
    StorageType storage = StorageType.fridge,
  }) => InventoryBatch(
    id: id,
    name: id,
    quantity: qty,
    unit: 'g',
    storageType: storage,
    createdAt: now,
    updatedAt: now,
  );
  PackageMeasurement measured(
    String id, {
    double qty = 500,
    int packages = 1,
  }) => PackageMeasurement(
    batchId: id,
    box: const BoxDimensions(widthCm: 10, heightCm: 10, depthCm: 10),
    packages: packages,
    quantityAtMeasurement: qty,
    unitAtMeasurement: 'g',
    source: 'manual',
  );
  const space = BoxDimensions(widthCm: 20, heightCm: 20, depthCm: 20);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('uses measured outer package geometry and leaves mass-only inventory unknown', () {
    final e = estimateCapacity(
      batches: [item('a'), item('b', qty: 9000)],
      storage: StorageType.fridge,
      space: space,
      measurements: {'a': measured('a', packages: 2)},
    );
    expect(e.capacityLitres, 8);
    expect(e.knownLitres, 2);
    expect(e.measuredCount, 1);
    expect(e.unknownCount, 1);
    expect(e.coverage, .5);
    expect(e.ratio, .25);
  });
  test(
    'changed quantities are excluded until package dimensions are reconfirmed',
    () {
      final e = estimateCapacity(
        batches: [item('a', qty: 250)],
        storage: StorageType.fridge,
        space: space,
        measurements: {'a': measured('a')},
      );
      expect(e.staleCount, 1);
      expect(e.knownLitres, 0);
      expect(e.measuredCount, 0);
    },
  );
  test(
    'only active items in selected storage count, overcapacity is not hidden',
    () {
      final e = estimateCapacity(
        batches: [
          item('a'),
          item('b', qty: 0),
          item('c', storage: StorageType.freezer),
        ],
        storage: StorageType.fridge,
        space: space,
        measurements: {'a': measured('a', packages: 10), 'c': measured('c')},
      );
      expect(e.totalCount, 1);
      expect(e.ratio, 1.25);
      expect(e.arithmeticRemaining, -2);
    },
  );
  test('invalid or nonfinite dimensions cannot be saved', () async {
    expect(
      () => estimateCapacity(
        batches: [],
        storage: StorageType.fridge,
        space: const BoxDimensions(widthCm: 0, heightCm: 2, depthCm: 2),
        measurements: {},
      ),
      throwsArgumentError,
    );
    final data = CapacityData(
      spaces: {
        StorageType.fridge: const BoxDimensions(
          widthCm: double.infinity,
          heightCm: 2,
          depthCm: 2,
        ),
      },
    );
    await expectLater(
      CapacityService().save(data, demo: false),
      throwsArgumentError,
    );
  });
  test('geometry persists with source and stays isolated between demo and personal', () async {
    final service = CapacityService();
    final data = CapacityData(
      spaces: {StorageType.fridge: space},
      spaceSources: {StorageType.fridge: 'manual'},
      measurements: {'a': measured('a')},
    );
    await service.save(data, demo: false);
    final loaded = await CapacityService().load(demo: false);
    expect(loaded.spaces[StorageType.fridge]!.litres, 8);
    expect(loaded.measurements['a']!.litres, 1);
    expect(loaded.spaceSources[StorageType.fridge], 'manual');
    expect((await service.load(demo: true)).measurements, isEmpty);
  });
}
