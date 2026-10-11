import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models.dart';
import 'api_client.dart';

/// Owns the logged-in [Session]: login, persistence of the JWT, logout.
class SessionStore extends ChangeNotifier {
  SessionStore(this.api, {FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage() {
    api.onUnauthorized = () => logout();
  }

  final ApiClient api;
  final FlutterSecureStorage _storage;

  static const _kToken = 'jwt';
  static const _kUser = 'user_id';
  static const _kAdmin = 'is_admin';
  static const _kExp = 'expires_at';

  Session? _session;
  bool _ready = false;

  Session? get session => _session;
  bool get isReady => _ready;
  bool get isLoggedIn => _session != null;

  /// Restores a saved, non-expired session on app start.
  Future<void> restore() async {
    try {
      final token = await _storage.read(key: _kToken);
      final user = await _storage.read(key: _kUser);
      final exp = DateTime.tryParse(await _storage.read(key: _kExp) ?? '');
      final admin = (await _storage.read(key: _kAdmin)) == 'true';
      if (token != null && user != null && exp != null) {
        final s = Session(
          token: token,
          userId: user,
          isAdmin: admin,
          expiresAt: exp,
        );
        if (!s.isExpired) {
          _apply(s);
        } else {
          await _clearStorage();
        }
      }
    } catch (_) {
      // Storage unavailable: start logged out.
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> login(String phoneNumber) async {
    final s = await api.login(phoneNumber.trim());
    _apply(s);
    try {
      await _storage.write(key: _kToken, value: s.token);
      await _storage.write(key: _kUser, value: s.userId);
      await _storage.write(key: _kAdmin, value: s.isAdmin.toString());
      await _storage.write(key: _kExp, value: s.expiresAt.toIso8601String());
    } catch (_) {
      // Still logged in for this run even if persistence fails.
    }
    notifyListeners();
  }

  Future<void> logout() async {
    if (_session == null) return;
    _session = null;
    api.token = null;
    await _clearStorage();
    notifyListeners();
  }

  void _apply(Session s) {
    _session = s;
    api.token = s.token;
  }

  Future<void> _clearStorage() async {
    try {
      await _storage.deleteAll();
    } catch (_) {}
  }
}
