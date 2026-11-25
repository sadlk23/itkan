import 'package:shared_preferences/shared_preferences.dart';

/// Explicitly saved cooking choices, kept separate from allergy exclusions.
class CookingPreferences {
  const CookingPreferences({this.preferences = '', this.equipment = ''});
  final String preferences;
  final String equipment;

  static String _key(bool isDemo, String field) =>
      'cooking_${isDemo ? 'demo' : 'personal'}_$field';

  static Future<CookingPreferences> load({required bool isDemo}) async {
    final storage = await SharedPreferences.getInstance();
    return CookingPreferences(
      preferences: storage.getString(_key(isDemo, 'preferences')) ?? '',
      equipment: storage.getString(_key(isDemo, 'equipment')) ?? '',
    );
  }

  Future<void> save({required bool isDemo}) async {
    if (preferences.length > 500 || equipment.length > 500) {
      throw const FormatException('저장할 취향과 조리도구는 각각 500자 이내로 입력해주세요.');
    }
    final storage = await SharedPreferences.getInstance();
    final preferenceSaved = await storage.setString(
      _key(isDemo, 'preferences'),
      preferences.trim(),
    );
    final equipmentSaved = await storage.setString(
      _key(isDemo, 'equipment'),
      equipment.trim(),
    );
    if (!preferenceSaved || !equipmentSaved) {
      throw StateError('요리 취향을 저장하지 못했어요. 다시 시도해주세요.');
    }
  }

  static Future<void> clear({required bool isDemo}) async {
    final storage = await SharedPreferences.getInstance();
    await storage.remove(_key(isDemo, 'preferences'));
    await storage.remove(_key(isDemo, 'equipment'));
  }
}
