import 'package:shared_preferences/shared_preferences.dart';

import '../models/inventory.dart';

Future<StorageType> preferredStorage() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('default_storage');
    return StorageType.values.where((s) => s.name == name).firstOrNull ??
        StorageType.fridge;
  } catch (_) {
    return StorageType.fridge;
  }
}
