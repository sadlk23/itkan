import 'package:flutter_test/flutter_test.dart';
import 'package:my_fridge/design/ingredient_art_catalog.dart';

void main() {
  test('normalizes brands, spacing, descriptors and sizes conservatively', () {
    for (final name in ['두 부', '연두부', '풀무원 부침용 두부 300g', '국산 두부']) {
      expect(IngredientArtCatalog.resolve(name).key, 'tofu', reason: name);
    }
    expect(IngredientArtCatalog.resolve('서울우유 저지방').key, 'milk');
    expect(IngredientArtCatalog.resolve('계란').key, 'egg');
    expect(IngredientArtCatalog.resolve('달걀').key, 'egg');
  });
  test('overlapping ingredient names do not match processed foods', () {
    expect(IngredientArtCatalog.resolve('양파').key, 'onion');
    expect(IngredientArtCatalog.resolve('대파').key, 'leek');
    expect(IngredientArtCatalog.resolve('김치만두').key, 'dumpling');
    for (final name in [
      '초코파이',
      '우유초콜릿',
      '두부과자',
      '당근케이크',
      '토마토소스',
      'chocolate milk',
      'eggplant',
    ]) {
      expect(
        IngredientArtCatalog.resolve(name).isRepresentative,
        false,
        reason: name,
      );
    }
  });
  test(
    'unsupported ingredients use categories rather than another food drawing',
    () {
      expect(IngredientArtCatalog.resolve('사과').key, 'category:과일');
      expect(IngredientArtCatalog.resolve('간장').isRepresentative, false);
      expect(
        IngredientArtCatalog.resolve('알수없는 제품', category: '해산물').category,
        '해산물',
      );
      expect(
        IngredientArtCatalog.resolve('알수없는 제품', category: '잘못된 분류').category,
        '기타',
      );
      expect(IngredientArtCatalog.resolve('').representativeName, isNull);
    },
  );
  test(
    'explicit supported art selection wins; unknown keys do not invent art',
    () {
      expect(
        IngredientArtCatalog.resolve('우리집 재료', artKey: 'tofu').key,
        'tofu',
      );
      expect(
        IngredientArtCatalog.resolve('우유', artKey: 'removed-key').key,
        'milk',
      );
      expect(
        IngredientArtCatalog.resolve(
          '미상',
          artKey: 'removed-key',
        ).isRepresentative,
        false,
      );
      expect(
        IngredientArtCatalog.resolve('만두', category: '가공식품').category,
        '가공식품',
      );
    },
  );
}
