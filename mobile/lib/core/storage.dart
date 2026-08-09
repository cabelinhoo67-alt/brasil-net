import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Token e senha ficam no secure storage (Keystore).
/// Preferencias sem valor sensivel ficam no SharedPreferences.
class Storage {
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kToken = 'auth_token';
  static const _kUsername = 'saved_username';
  static const _kPassword = 'saved_password';
  static const _kRemember = 'remember_me';
  static const _kDeviceId = 'device_id';
  static const _kOverlay = 'overlay_enabled';

  static Future<void> saveToken(String token) => _secure.write(key: _kToken, value: token);
  static Future<String?> readToken() => _secure.read(key: _kToken);
  static Future<void> clearToken() => _secure.delete(key: _kToken);

  static Future<void> saveCredentials(String username, String password) async {
    await _secure.write(key: _kUsername, value: username);
    await _secure.write(key: _kPassword, value: password);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRemember, true);
  }

  static Future<({String username, String password})?> readCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_kRemember) ?? false)) return null;

    final username = await _secure.read(key: _kUsername);
    final password = await _secure.read(key: _kPassword);
    if (username == null || password == null) return null;
    return (username: username, password: password);
  }

  static Future<void> clearCredentials() async {
    await _secure.delete(key: _kUsername);
    await _secure.delete(key: _kPassword);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRemember, false);
  }

  /// Id estavel do aparelho: e o que o backend usa para contar conexoes
  /// simultaneas sem punir quem apenas reabre o app.
  static Future<String> deviceId(String fallback) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kDeviceId);
    if (saved != null && saved.isNotEmpty) return saved;

    await prefs.setString(_kDeviceId, fallback);
    return fallback;
  }

  /// Preferencia do usuario pela janela flutuante de status (overlay).
  static Future<bool> readOverlayPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kOverlay) ?? false;
  }

  static Future<void> saveOverlayPreference(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOverlay, enabled);
  }
}
