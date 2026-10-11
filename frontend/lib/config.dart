/// Backend location.
///
/// Override at build/run time:
///   flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080
///   flutter run            --dart-define=API_BASE_URL=http://10.0.2.2:8080   (Android emulator)
///   flutter build web      --dart-define=API_BASE_URL=origin                 (Docker: same origin via nginx)
class AppConfig {
  static const String _raw = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// HTTP base URL without a trailing slash.
  static String get apiBase {
    final v = _raw == 'origin' ? Uri.base.origin : _raw;
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  /// WebSocket endpoint (ws:// or wss:// matching the API scheme).
  static Uri get wsUri {
    final base = Uri.parse(apiBase);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws',
    );
  }
}
