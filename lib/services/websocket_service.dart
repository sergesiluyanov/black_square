import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Map<String, dynamic> _parseJsonInIsolate(String s) => jsonDecode(s) as Map<String, dynamic>;

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

  /// Callback при получении call-сигнала (call-offer, call-answer, call-ice, call-hangup, call-reject)
  void Function(Map<String, dynamic> message)? onCallSignal;

  bool get isConnected => _isConnected;

  Completer<bool>? _pendingPong;

  /// Проверка соединения: отправляет ping, ждёт pong. Возвращает true если ответ получен.
  Future<bool> checkConnection() async {
    if (!_isConnected || _channel == null) return false;
    _pendingPong = Completer<bool>();
    _channel!.sink.add(jsonEncode({'type': 'ping'}));
    Future.delayed(const Duration(seconds: 2), () {
      if (_pendingPong != null && !_pendingPong!.isCompleted) {
        _pendingPong!.complete(false);
      }
      _pendingPong = null;
    });
    return _pendingPong!.future;
  }

  void _dispatchMessage(Map<String, dynamic> msg) {
    if (msg['type'] == 'pong' && _pendingPong != null && !_pendingPong!.isCompleted) {
      _pendingPong!.complete(true);
      _pendingPong = null;
      return;
    }
    final type = msg['type'] as String?;
    if (type != null &&
        (type == 'call-offer' ||
            type == 'call-answer' ||
            type == 'call-ice' ||
            type == 'call-hangup' ||
            type == 'call-reject' ||
            type == 'call-offer-ack')) {
      if (kDebugMode) debugPrint('WebSocket: dispatching call signal type=$type to onCallSignal');
      onCallSignal?.call(msg);
    } else {
      onMessage?.call(msg);
    }
  }

  /// Подключение к серверу
  /// [fcmToken] — токен FCM для push-уведомлений (отправляется на сервер)
  Future<void> connect(String url, String userId, {String? fcmToken}) async {
    _url = url;
    _userId = userId;
    _fcmToken = fcmToken;
    _disconnectRequested = false;
    await _doConnect();
  }

  String? _fcmToken;

  Future<void> _doConnect() async {
    if (_disconnectRequested) return;

    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _subscription = null;
    _isConnected = false;

    try {
      if (kDebugMode) debugPrint('WebSocket: connecting to $_url');
      _channel = WebSocketChannel.connect(Uri.parse(_url!));
      _isConnected = true;
      if (kDebugMode) debugPrint('WebSocket: connected, sending auth');

      final auth = {'type': 'auth', 'userId': _userId!};
      if (_fcmToken != null && _fcmToken!.isNotEmpty) {
        auth['fcmToken'] = _fcmToken!;
      }
      _channel!.sink.add(jsonEncode(auth));

      _subscription = _channel!.stream.listen(
        (data) {
          final str = data is String ? data : (data is List<int> ? String.fromCharCodes(data) : null);
          if (str == null) return;
          // Большие сообщения (видео) — парсим в изоляте, чтобы не блокировать UI (ANR)
          final threshold = 50 * 1024;
          if (str.length > threshold) {
            compute(_parseJsonInIsolate, str).then((msg) {
              try {
                _dispatchMessage(msg);
              } catch (_) {}
            }).catchError((_) {});
          } else {
            try {
              final msg = jsonDecode(str) as Map<String, dynamic>;
              final t = msg['type'] as String?;
              if (kDebugMode && t != null && t.startsWith('call-'))
                debugPrint('WebSocket: <<< received type=$t');
              _dispatchMessage(msg);
            } catch (e) {
              if (kDebugMode) debugPrint('WebSocket: parse error $e');
            }
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

  /// Отправка произвольного JSON (для call signaling)
  void send(Map<String, dynamic> data) {
    final t = data['type'] as String?;
    if (!_isConnected || _channel == null) {
      if (kDebugMode && t != null) debugPrint('WebSocket: send BLOCKED (connected=$_isConnected) type=$t');
      return;
    }
    if (kDebugMode && t != null) debugPrint('WebSocket: >>> sending type=$t');
    _channel!.sink.add(jsonEncode(data));
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
