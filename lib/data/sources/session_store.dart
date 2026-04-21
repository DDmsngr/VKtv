import 'package:shared_preferences/shared_preferences.dart';

/// Простой KV-стор для cookie VK-сессии.
/// На TV-устройствах secure-storage часто отсутствует/нестабилен,
/// а remixsid не настолько критичен чтобы городить keystore —
/// выкручиваемся shared_preferences.
class SessionStore {
  static const _keyCookie = 'vk_session_cookie';
  static const _keyUserId = 'vk_user_id';

  final SharedPreferences _prefs;
  SessionStore._(this._prefs);

  static Future<SessionStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SessionStore._(prefs);
  }

  String? get cookie => _prefs.getString(_keyCookie);
  String? get userId => _prefs.getString(_keyUserId);

  Future<void> saveCookie(String cookie) =>
      _prefs.setString(_keyCookie, cookie);

  Future<void> saveUserId(String userId) =>
      _prefs.setString(_keyUserId, userId);

  Future<void> clear() async {
    await _prefs.remove(_keyCookie);
    await _prefs.remove(_keyUserId);
  }
}
