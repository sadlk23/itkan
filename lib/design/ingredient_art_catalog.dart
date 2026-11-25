/// One representative drawing per supported ingredient; unknown foods keep a
/// category symbol instead of borrowing a misleading product illustration.
class IngredientArt {
  const IngredientArt({
    required this.key,
    this.representativeName,
    required this.category,
    required this.isRepresentative,
  });
  final String key;
  final String? representativeName;
  final String category;
  final bool isRepresentative;
}

abstract final class IngredientArtCatalog {
  static const categories = {
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
  };
  static const _art = <String, (String, String)>{
    'tofu': ('두부', '가공식품'),
    'milk': ('우유', '유제품'),
    'onion': ('양파', '채소'),
    'leek': ('대파', '채소'),
    'kimchi': ('김치', '반찬'),
    'egg': ('달걀', '달걀'),
    'carrot': ('당근', '채소'),
    'dumpling': ('만두', '냉동식품'),
    'tomato': ('토마토', '채소'),
    'oil': ('기름', '조미료'),
    'meat': ('고기', '육류'),
  };
  static const _aliases = <String, List<String>>{
    'tofu': ['두부', '연두부', '순두부', 'tofu', 'softtofu', 'firmtofu'],
    'milk': ['우유', '흰우유', 'milk', 'wholemilk', 'skimmilk'],
    'onion': ['양파', '적양파', '자색양파', 'onion', 'onions', 'redonion'],
    'leek': [
      '파',
      '대파',
      '쪽파',
      '실파',
      'leek',
      'leeks',
      'greenonion',
      'springonion',
      'scallion',
    ],
    'kimchi': ['김치', '배추김치', '포기김치', '묵은지', 'kimchi'],
    'egg': ['계란', '달걀', 'egg', 'eggs'],
    'carrot': ['당근', 'carrot', 'carrots'],
    'dumpling': [
      '만두',
      '교자만두',
      '고기만두',
      '김치만두',
      '물만두',
      '군만두',
      '왕만두',
      'dumpling',
      'dumplings',
      'gyoza',
    ],
    'tomato': ['토마토', '방울토마토', '대추방울토마토', 'tomato', 'tomatoes', 'cherrytomato'],
    'oil': [
      '식용유',
      '기름',
      '올리브유',
      '참기름',
      '들기름',
      '해바라기유',
      '카놀라유',
      '포도씨유',
      '콩기름',
      'oil',
      'oliveoil',
      'sesameoil',
    ],
    'meat': [
      '고기',
      '돼지고기',
      '소고기',
      '쇠고기',
      '닭고기',
      '삼겹살',
      '목살',
      '등심',
      '안심',
      '앞다리살',
      '뒷다리살',
      'pork',
      'beef',
      'chicken',
      'meat',
    ],
  };
  static const _genericNames = <String, List<String>>{
    '과일': ['사과', '배', '바나나', '포도', '딸기', '오렌지', '수박', 'apple', 'banana'],
    '채소': ['오이', '감자', '고구마', '배추', '양배추', '시금치', '버섯', '상추', '브로콜리'],
    '해산물': ['연어', '고등어', '새우', '오징어', '참치', 'salmon', 'shrimp'],
    '유제품': ['치즈', '요거트', '요구르트', '버터', 'cheese', 'yogurt', 'butter'],
    '소스': ['간장', '고추장', '된장', '케첩', '마요네즈', '토마토소스'],
    '조미료': ['소금', '설탕', '후추', '식초'],
    '가공식품': ['초코파이', '두부과자', '우유초콜릿', '과자', '초콜릿', '빵', '라면'],
  };

  /// Formatting only. Never remove arbitrary words that might denote a dish.
  static String normalizeAlias(String name) => name
      .toLowerCase()
      .trim()
      .replaceAll(RegExp(r'[\s_·ㆍ()\[\]{}-]+'), '')
      .replaceAll(RegExp(r'\d+(?:\.\d+)?(?:kg|ml|g|l|개|입|팩|봉)$'), '');

  static String _unbranded(String name) {
    var value = normalizeAlias(name);
    const brands = [
      '서울우유',
      '매일유업',
      '풀무원',
      '청정원',
      '오뚜기',
      '동원',
      '비비고',
      '남양',
      '매일',
      '서울',
    ];
    for (final brand in brands) {
      if (value.startsWith(brand)) {
        // 서울우유 is both a brand and a complete product name.
        value = brand == '서울우유'
            ? '우유${value.substring(brand.length)}'
            : value.substring(brand.length);
        break;
      }
    }
    const modifiers = [
      '국내산',
      '국산',
      '유기농',
      '무농약',
      '친환경',
      '저지방',
      '무지방',
      '락토프리',
      '멸균',
      '부침용',
      '찌개용',
      '조림용',
      '냉장',
      '냉동',
      '신선한',
      '신선',
      '특란',
      '대란',
      '중란',
      '소란',
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final modifier in modifiers) {
        if (value.startsWith(modifier)) {
          value = value.substring(modifier.length);
          changed = true;
        }
        if (value.endsWith(modifier)) {
          value = value.substring(0, value.length - modifier.length);
          changed = true;
        }
      }
    }
    return value;
  }

  static IngredientArt resolve(
    String name, {
    String category = '기타',
    String artKey = 'generic',
  }) {
    final explicitCategory = categories.contains(category) && category != '기타'
        ? category
        : null;
    String? key = _art.containsKey(artKey) ? artKey : null;
    final normalized = _unbranded(name);
    if (key == null) {
      for (final entry in _aliases.entries) {
        if (entry.value.contains(normalized)) {
          key = entry.key;
          break;
        }
      }
    }
    if (key != null) {
      final item = _art[key]!;
      return IngredientArt(
        key: key,
        representativeName: item.$1,
        category: explicitCategory ?? item.$2,
        isRepresentative: true,
      );
    }
    var fallback = explicitCategory ?? '기타';
    if (explicitCategory == null) {
      for (final entry in _genericNames.entries) {
        if (entry.value.contains(normalized)) {
          fallback = entry.key;
          break;
        }
      }
    }
    return IngredientArt(
      key: 'category:$fallback',
      category: fallback,
      isRepresentative: false,
    );
  }
}
