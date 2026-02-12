import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Сервис WebSocket для подключения к серверу Black Square
class WebSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;

  /// Callback при получении сообщения от сервера
  void Function(Map<String, dynamic> message)? onMessage;

  bool get isConnected => _isConnected;

  /// Подключение к серверу
  Future<void> connect(String url, String userId) async {
    if (_isConnected) return;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _isConnected = true;

      _channel!.sink.add(jsonEncode({
        'type': 'auth',
        'userId': userId,
      }));

      _subscription = _channel!.stream.listen(
        (data) {
          try {
            final msg = jsonDecode(data as String) as Map<String, dynamic>;
            onMessage?.call(msg);
          } catch (_) {}
        },
        onError: (e) {
          _isConnected = false;
        },
        onDone: () {
          _isConnected = false;
        },
        cancelOnError: false,
      );
    } catch (e) {
      _isConnected = false;
      rethrow;
    }
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
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _subscription = null;
    _isConnected = false;
  }
}
