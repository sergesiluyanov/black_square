import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Сервис WebSocket для подключения к серверу Black Square
class WebSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  String? _url;
  String? _userId;
  Timer? _reconnectTimer;
  bool _disconnectRequested = false;

  /// Callback при получении сообщения от сервера
  void Function(Map<String, dynamic> message)? onMessage;

  bool get isConnected => _isConnected;

  /// Подключение к серверу
  Future<void> connect(String url, String userId) async {
    _url = url;
    _userId = userId;
    _disconnectRequested = false;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_disconnectRequested) return;

    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _subscription = null;
    _isConnected = false;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_url!));
      _isConnected = true;

      _channel!.sink.add(jsonEncode({
        'type': 'auth',
        'userId': _userId!,
      }));

      _subscription = _channel!.stream.listen(
        (data) {
          try {
            final str = data is String ? data : (data is List<int> ? String.fromCharCodes(data) : null);
            if (str == null) return;
            final msg = jsonDecode(str) as Map<String, dynamic>;
            try {
              onMessage?.call(msg);
            } catch (_) {}
          } catch (_) {
            // Игнорируем ping/pong и прочие не-JSON фреймы
          }
        },
        onError: (e) {
          _isConnected = false;
          _scheduleReconnect();
        },
        onDone: () {
          _isConnected = false;
          _scheduleReconnect();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _isConnected = false;
      _scheduleReconnect();
      rethrow;
    }
  }

  void _scheduleReconnect() {
    if (_disconnectRequested || _url == null || _userId == null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      _doConnect();
    });
  }

  /// Отправка сообщения получателю
  void sendMessage({
    required String to,
    required String chatId,
    required String payload,
  }) {
    if (!_isConnected || _channel == null) return;

    _channel!.sink.add(jsonEncode({
      'type': 'message',
      'to': to,
      'chatId': chatId,
      'payload': payload,
    }));
  }

  /// Отключение
  Future<void> disconnect() async {
    _disconnectRequested = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _subscription = null;
    _isConnected = false;
  }
}
