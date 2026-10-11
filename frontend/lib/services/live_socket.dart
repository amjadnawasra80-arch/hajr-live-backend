import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../models.dart';

enum SocketStatus { connecting, connected, disconnected }

/// Authenticated live-room WebSocket with automatic reconnect (exponential back-off).
///
/// The JWT is sent via the subprotocol list ["bearer", "<jwt>"], which works in
/// browsers (they cannot set an Authorization header) and on mobile alike, and
/// keeps the token out of the URL.
class LiveSocket {
  LiveSocket({required this.tokenProvider, Uri? uri})
    : _uri = uri ?? AppConfig.wsUri;

  final String? Function() tokenProvider;
  final Uri _uri;

  final _events = StreamController<LiveEvent>.broadcast();
  final _status = StreamController<SocketStatus>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _closed = false;
  SocketStatus _current = SocketStatus.disconnected;

  Stream<LiveEvent> get events => _events.stream;
  Stream<SocketStatus> get status => _status.stream;
  SocketStatus get currentStatus => _current;

  void _setStatus(SocketStatus s) {
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  Future<void> connect() async {
    if (_closed) return;
    final token = tokenProvider();
    if (token == null) return;

    _retry?.cancel();
    await _sub?.cancel();
    _setStatus(SocketStatus.connecting);

    try {
      final channel = WebSocketChannel.connect(
        _uri,
        protocols: ['bearer', token],
      );
      _channel = channel;
      await channel.ready;
      if (_closed) {
        await channel.sink.close();
        return;
      }
      _attempt = 0;
      _setStatus(SocketStatus.connected);
      _sub = channel.stream.listen(
        _onFrame,
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onFrame(dynamic frame) {
    if (frame is! String) return;
    try {
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, dynamic>) return;
      final ev = LiveEvent.parse(decoded);
      if (ev != null && !_events.isClosed) _events.add(ev);
    } catch (_) {
      // Ignore malformed frames.
    }
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _setStatus(SocketStatus.disconnected);
    _retry?.cancel();
    final secs = (1 << (_attempt < 4 ? _attempt : 4)).clamp(1, 15);
    _attempt++;
    _retry = Timer(Duration(seconds: secs), connect);
  }

  /// Sends a chat message. Returns false when not connected.
  bool sendChat(String text) {
    final t = text.trim();
    if (t.isEmpty || _current != SocketStatus.connected) return false;
    _channel?.sink.add(
      jsonEncode({
        'type': 'chat',
        'data': {'text': t},
      }),
    );
    return true;
  }

  Future<void> dispose() async {
    _closed = true;
    _retry?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _events.close();
    await _status.close();
  }
}
