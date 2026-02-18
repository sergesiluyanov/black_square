import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Обработчик фоновых push — должен быть top-level функцией
/// Показывает полноэкранный экран звонка (CallKit) без уведомления в трее
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  if (kDebugMode) {
    debugPrint('FCM background: ${message.messageId} type=${message.data['type']}');
  }
  final type = message.data['type'] ?? '';
  if (type == 'call') {
    final data = message.data;
    final callId = data['callId'] ?? message.messageId ?? 'call-${message.hashCode}';
    final raw = data['fromName'] ?? '';
    final fromName = raw.toString().trim().isNotEmpty ? raw.toString().trim() : 'Кто-то звонит';
    final sender = data['sender'] ?? data['from'] ?? '';
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(
        CallKitParams(
          id: callId,
          nameCaller: fromName,
          appName: 'Black Square',
          handle: sender,
          type: 1, // video
          duration: 45000,
          textAccept: 'Принять',
          textDecline: 'Отклонить',
          callingNotification: const NotificationParams(
            showNotification: false,
            isShowCallback: false,
          ),
          missedCallNotification: const NotificationParams(
            showNotification: true,
            isShowCallback: true,
            subtitle: 'Пропущенный звонок',
            callbackText: 'Перезвонить',
          ),
          extra: data,
          android: const AndroidParams(
            isCustomNotification: true,
            isShowFullLockedScreen: true,
            ringtonePath: 'ringtone_positive',
            backgroundColor: '#0A0A0A',
            actionColor: '#6B8AFF',
            textColor: '#ffffff',
            incomingCallNotificationChannelName: 'Входящие звонки',
            missedCallNotificationChannelName: 'Пропущенные',
          ),
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('CallKit background error: $e');
    }
  }
}

/// Сервис push-уведомлений (FCM + локальные для foreground)
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;

  NotificationService._();

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  void Function(String? type, Map<String, String> data)? _onNotificationTap;

  /// Callback при получении push (для навигации при тапе)
  set onNotificationTap(void Function(String? type, Map<String, String> data)? value) {
    _onNotificationTap = value;
    if (_pendingTap != null && value != null) {
      value(_pendingTap!.type, _pendingTap!.data);
      _pendingTap = null;
    }
  }

  ({String? type, Map<String, String> data})? _pendingTap;

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;

    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    const androidChannel = AndroidNotificationChannel(
      'black_square_messages',
      'Сообщения и звонки',
      description: 'Уведомления о новых сообщениях и входящих звонках',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    _fcmToken = await FirebaseMessaging.instance.getToken();
    if (kDebugMode) debugPrint('FCM token: ${_fcmToken?.substring(0, 20)}...');

    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      _fcmToken = token;
      if (kDebugMode) debugPrint('FCM token refreshed');
    });

    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      _handleMessageOpenedApp(initialMessage);
    }
  }

  void _onNotificationResponse(NotificationResponse? response) {
    if (response?.payload == null) return;
    try {
      final parts = response!.payload!.split('|');
      if (parts.length >= 2) {
        final type = parts[0];
        final data = <String, String>{};
        for (var i = 1; i < parts.length; i += 2) {
          if (i + 1 < parts.length) data[parts[i]] = parts[i + 1];
        }
        _onNotificationTap?.call(type, data);
      }
    } catch (_) {}
  }

  void _handleForegroundMessage(RemoteMessage message) {
    if (kDebugMode) {
      debugPrint('FCM foreground: ${message.messageId} type=${message.data['type']}');
    }
    // Звонки не показываем как push — CallService сразу показывает экран и играет мелодию
    if (message.data['type'] == 'call') return;
    _showLocalNotification(message);
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    final data = Map<String, String>.from(message.data);
    final type = data['type'] ?? '';
    if (_onNotificationTap != null) {
      _onNotificationTap!(type, data);
    } else {
      _pendingTap = (type: type, data: data);
    }
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final data = message.data;
    final type = data['type'] ?? 'message';
    String title;
    String body;

    if (type == 'call') {
      title = 'Входящий звонок';
      body = data['fromName'] ?? 'Кто-то звонит';
    } else {
      title = data['title'] ?? 'Новое сообщение';
      body = data['body'] ?? 'У вас новое сообщение';
    }

    final payloadParts = [type];
    for (final e in data.entries) {
      payloadParts.addAll([e.key, e.value]);
    }
    final payload = payloadParts.join('|');

    const androidDetails = AndroidNotificationDetails(
      'black_square_messages',
      'Сообщения и звонки',
      channelDescription: 'Уведомления о новых сообщениях и входящих звонках',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const details = NotificationDetails(android: androidDetails);
    await _localNotifications.show(
      message.hashCode.abs() % 0x7FFFFFFF,
      title,
      body,
      details,
      payload: payload,
    );
  }
}
