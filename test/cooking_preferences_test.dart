import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_fridge/services/cooking_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('explicit cooking preferences persist and demo does not leak', () async {
    await const CookingPreferences(
      preferences: '맵지 않게',
      equipment: '전자레인지',
    ).save(isDemo: false);
    final personal = await CookingPreferences.load(isDemo: false);
    expect(personal.preferences, '맵지 않게');
    expect(personal.equipment, '전자레인지');
    expect((await CookingPreferences.load(isDemo: true)).preferences, isEmpty);
    await const CookingPreferences(preferences: '샘플').save(isDemo: true);
    await CookingPreferences.clear(isDemo: false);
    expect((await CookingPreferences.load(isDemo: false)).preferences, isEmpty);
    expect((await CookingPreferences.load(isDemo: true)).preferences, '샘플');
  });
}
