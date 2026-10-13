import 'package:shared_preferences/shared_preferences.dart';
import 'guards.dart';

/// [AdStorage] backed by shared_preferences (counters survive app restarts).
class SharedPrefsAdStorage implements AdStorage {
  SharedPrefsAdStorage._(this._prefs);

  final SharedPreferences _prefs;

  static Future<SharedPrefsAdStorage> create() async =>
      SharedPrefsAdStorage._(await SharedPreferences.getInstance());

  @override
  int getInt(String key) => _prefs.getInt(key) ?? 0;

  @override
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);
}
