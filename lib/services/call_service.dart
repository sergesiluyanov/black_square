import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:black_square/app_lifecycle.dart';
import 'package:black_square/config.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:black_square/services/websocket_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

/// STUN/TURN для WebRTC (NAT traversal).
/// Несколько STUN + TURN нужны для 4G/мобильного интернета.
/// sdpSemantics: 'unified-plan' — требуется addTrack вместо addStream
Map<String, dynamic> get _iceServers {
  final servers = <Map<String, dynamic>>[
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun2.l.google.com:19302'},
    {'urls': 'stun:stun3.l.google.com:19302'},
    {'urls': 'stun:stun4.l.google.com:19302'},
  ];
  if (Config.turnUrl != null &&
      Config.turnUrl!.isNotEmpty &&
      Config.turnUsername != null &&
      Config.turnCredential != null &&
      Config.turnCredential != 'CHANGE_ME') {
    servers.add({
      'urls': Config.turnUrl!,
      'username': Config.turnUsername!,
      'credential': Config.turnCredential!,
    });
    servers.add({
      'urls': '${Config.turnUrl!}?transport=tcp',
      'username': Config.turnUsername!,
      'credential': Config.turnCredential!,
    });
  } else {
    servers.add({
      'urls': 'turn:freeturn.net:3478',
      'username': 'free',
      'credential': 'free',
    });
  }
  final config = <String, dynamic>{
    'iceServers': servers,
    'sdpSemantics': 'unified-plan',
  };
  if (Config.turnRelayOnly) {
    config['iceTransportPolicy'] = 'relay';
  }
  return config;
}

enum CallState {
  idle,
  calling,
  incoming,
  connecting,
  connected,
  ended,
}

class CallInfo {
  final String callId;
  final String remoteUserId;
  final String remoteName;
  final bool isIncoming;

  CallInfo({
    required this.callId,
    required this.remoteUserId,
    required this.remoteName,
    required this.isIncoming,
  });
}

class CallService extends ChangeNotifier {
  CallService(this._chatService);

  final ChatService _chatService;
  WebSocketService get _ws => _chatService.ws;

  final _uuid = const Uuid();

  CallState _state = CallState.idle;
  CallState get state => _state;

  /// Можно ли инициировать звонок (WebSocket подключён)
  bool get canCall => _ws.isConnected;

  CallInfo? _currentCall;
  CallInfo? get currentCall => _currentCall;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  /// Ожидающий offer (для входящего звонка — обрабатываем при accept)
  Map<String, dynamic>? _pendingOffer;

  /// Очередь ICE-кандидатов, пришедших до готовности peer connection
  final List<Map<String, dynamic>> _pendingIceCandidates = [];

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _isSpeakerOn = false;
  bool get isSpeakerOn => _isSpeakerOn;

  bool _isVideoOn = false;
  bool get isVideoOn => _isVideoOn;

  /// Последняя ошибка (очищается при новом звонке)
  String? _lastError;
  String? get lastError => _lastError;

  /// Пропущенный звонок из push — показываем экран «Перезвонить»
  ({String senderId, String senderName})? missedCallFromPush;

  /// Принятие звонка при запуске из killed state (данные из launch intent)
  ({String callId, String from, String? fromName})? _pendingAcceptFromLaunch;
  bool _acceptedFromBackground = false;

  /// Звонок был сделан офлайн-получателю (нужен re-negotiate после получения answer)
  bool _calledOfflineRecipient = false;

  /// Отклонение звонка из killed state — отправляется при следующем подключении WS
  ({String callId, String to})? _pendingReject;

  void setPendingAcceptFromLaunch(String callId, String from, {String? fromName}) {
    _pendingAcceptFromLaunch = (callId: callId, from: from, fromName: fromName);
    if (kDebugMode) debugPrint('CallService: pending accept from launch callId=$callId from=$from fromName=$fromName');
  }

  /// Показать экран «Подключение» при тапе «Принять» из killed state (до получения call-offer)
  void showPendingAcceptScreen(String callId, String from, String? fromName) {
    _currentCall = CallInfo(
      callId: callId,
      remoteUserId: from,
      remoteName: (fromName != null && fromName.isNotEmpty) ? fromName : from,
      isIncoming: true,
    );
    _setState(CallState.connecting);
    if (kDebugMode) debugPrint('CallService: show pending accept screen callId=$callId from=$from');
  }
  /// При открытии приложения — сбрасываем пропущенный звонок.
  /// ВАЖНО: не трогаем peer connection в состояниях calling/incoming/connecting/connected —
  /// иначе убиваем соединение, принятое через CallKit из background.
  void dismissMissedCallFromPush() {
    missedCallFromPush = null;
    if (_state == CallState.ended) {
      _cleanup();
      _setState(CallState.idle);
    } else {
      notifyListeners();
    }
  }

  void _setState(CallState s) {
    _state = s;
    if (s == CallState.incoming) {
      FlutterRingtonePlayer().playRingtone(looping: true, asAlarm: false);
    } else {
      FlutterRingtonePlayer().stop();
    }
    if (s == CallState.ended) {
      Future.delayed(const Duration(seconds: 3), () {
        if (_state == CallState.ended) {
          _cleanup();
          _state = CallState.idle;
          notifyListeners();
        }
      });
    }
    notifyListeners();
  }

  void _cleanupConnection() {
    _pendingOffer = null;
    _pendingIceCandidates.clear();
    _peerConnection?.close();
    _peerConnection = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    _remoteStream = null;
  }

  void _cleanup() {
    FlutterRingtonePlayer().stop();
    _cleanupConnection();
    _currentCall = null;
    _calledOfflineRecipient = false;
    _acceptedFromBackground = false;
  }

  void _setError(String msg) {
    _lastError = msg;
    if (kDebugMode) debugPrint('CallService: $msg');
  }

  StreamSubscription? _callKitSubscription;

  void init() {
    _ws.onCallSignal = _handleCallSignal;
    _ws.onConnected = _onWsConnected;
    if (Platform.isAndroid) {
      _callKitSubscription = FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
      FlutterCallkitIncoming.requestFullIntentPermission().catchError((_) {});
    }
  }

  void _onWsConnected() {
    if (_pendingReject != null) {
      final r = _pendingReject!;
      _pendingReject = null;
      _ws.send({'type': 'call-reject', 'to': r.to, 'callId': r.callId});
      if (kDebugMode) debugPrint('CallService: sent pending reject callId=${r.callId} to=${r.to}');
    }
  }

  Future<String> _getRemoteName(String userId) async {
    final chats = await _chatService.getChats();
    for (final c in chats) {
      if (c.recipientId == userId && c.name.isNotEmpty) return c.name;
    }
    return userId;
  }

  /// Отправляет «Звонок пропущен» только когда мы получатель (отклонили/пропустили).
  /// Звонящему это сообщение не показываем.
  void _sendMissedCallMessageIfNeeded() {
    if (_currentCall == null || _state == CallState.connected) return;
    if (!_currentCall!.isIncoming) return; // мы звонящий — не отправляем
    final remoteUserId = _currentCall!.remoteUserId;
    _chatService.addLocalMissedCallMessage(remoteUserId).catchError((e) {
      if (kDebugMode) debugPrint('CallService: addLocalMissedCallMessage error $e');
    });
  }

  void _onCallKitEvent(CallEvent? event) {
    if (event == null) return;
    final body = event.body is Map ? event.body as Map : null;
    final extra = body?['extra'] is Map ? body!['extra'] as Map : body;
    final eventCallId = body?['id'] ?? body?['callId'] ?? extra?['callId'];
    final eventFrom = body?['handle'] ?? body?['number'] ?? extra?['from'] ?? extra?['sender'];
    final eventFromName = body?['nameCaller'] ?? extra?['fromName'];
    if (kDebugMode) {
      debugPrint('CallService: CallKit event ${event.event} body=$body extra=$extra');
    }

    switch (event.event) {
      case Event.actionCallAccept:
        if (_currentCall != null && eventCallId == _currentCall!.callId) {
          _acceptedFromBackground = true; // Accept из CallKit — запускаем auto-renegotiate
          acceptCall();
          _hideCallKit();
        } else if (eventCallId != null && eventFrom != null && eventFrom.toString().isNotEmpty) {
          final callId = eventCallId.toString();
          final from = eventFrom.toString();
          var fromName = eventFromName?.toString();
          if (fromName == null || fromName.isEmpty) {
            fromName = (body?['nameCaller'] ?? body?['name'])?.toString();
          }
          setPendingAcceptFromLaunch(callId, from, fromName: fromName);
          final displayName = (fromName != null && fromName.isNotEmpty) ? fromName : from;
          _currentCall = CallInfo(
            callId: callId,
            remoteUserId: from,
            remoteName: displayName,
            isIncoming: true,
          );
          _setState(CallState.connecting);
          _hideCallKit();
          if (kDebugMode) debugPrint('CallService: Accept from CallKit (no offer yet) callId=$callId from=$from fromName=$fromName');
          _getRemoteName(from).then((nameFromChat) {
            if (_currentCall != null && _currentCall!.remoteUserId == from && nameFromChat != from && nameFromChat.isNotEmpty) {
              _currentCall = CallInfo(
                callId: _currentCall!.callId,
                remoteUserId: from,
                remoteName: nameFromChat,
                isIncoming: true,
              );
              notifyListeners();
            }
          });
        }
        break;
      case Event.actionCallDecline:
      case Event.actionCallEnded:
        if (_currentCall != null && eventCallId == _currentCall!.callId) {
          _sendMissedCallMessageIfNeeded();
          rejectCall();
          _hideCallKit();
        } else {
          // Killed state: _currentCall не установлен, нужно сохранить reject для отправки при подключении WS
          final declineCallId = eventCallId?.toString() ?? '';
          final declineFrom = eventFrom?.toString() ?? '';
          if (declineCallId.isNotEmpty && declineFrom.isNotEmpty) {
            _pendingReject = (callId: declineCallId, to: declineFrom);
            _chatService.addLocalMissedCallMessage(declineFrom).catchError((e) {
              if (kDebugMode) debugPrint('CallService: addLocalMissedCallMessage (killed decline) error $e');
            });
            if (kDebugMode) debugPrint('CallService: stored pending reject callId=$declineCallId to=$declineFrom');
          }
          _cleanupConnection();
          _hideCallKit();
        }
        break;
      case Event.actionCallTimeout:
        if (_currentCall != null && eventCallId == _currentCall!.callId) {
          _sendMissedCallMessageIfNeeded();
        } else if (eventFrom != null && eventFrom.toString().isNotEmpty) {
          _chatService.addLocalMissedCallMessage(eventFrom.toString()).catchError((e) {
            if (kDebugMode) debugPrint('CallService: addLocalMissedCallMessage (timeout) error $e');
          });
        }
        _cleanupConnection();
        _setState(CallState.ended);
        _hideCallKit();
        break;
      case Event.actionCallCallback:
        if (eventFrom != null && eventFrom.toString().isNotEmpty) {
          _chatService.addLocalMissedCallMessage(eventFrom.toString()).catchError((e) {
            if (kDebugMode) debugPrint('CallService: addLocalMissedCallMessage (callback) error $e');
          });
        }
        _cleanupConnection();
        _setState(CallState.ended);
        _hideCallKit();
        break;
      default:
        break;
    }
  }

  Future<void> _hideCallKit() async {
    if (_currentCall != null) {
      try {
        await FlutterCallkitIncoming.hideCallkitIncoming(
          CallKitParams(id: _currentCall!.callId),
        );
      } catch (_) {}
    }
  }

  String get _callAcceptText =>
      ui.PlatformDispatcher.instance.locale.languageCode == 'ru' ? 'Ответить' : 'Answer';
  String get _callDeclineText =>
      ui.PlatformDispatcher.instance.locale.languageCode == 'ru' ? 'Отклонить' : 'Decline';

  Future<void> _showCallKit(String callId, String fromName, String from) async {
    if (!Platform.isAndroid) return;
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(
        CallKitParams(
          id: callId,
          nameCaller: fromName,
          appName: 'Black Square',
          handle: from,
          type: 0, // audio — не video, чтобы показывать «Ответить» вместо иконки video
          duration: 45000,
          textAccept: _callAcceptText,
          textDecline: _callDeclineText,
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
          extra: {'callId': callId, 'from': from, 'fromName': fromName},
            android: const AndroidParams(
              isCustomNotification: true,
              isShowFullLockedScreen: true,
              ringtonePath: 'system_ringtone_default',
            backgroundColor: '#0A0A0A',
            actionColor: '#6B8AFF',
            textColor: '#ffffff',
            incomingCallNotificationChannelName: 'Входящие звонки',
            missedCallNotificationChannelName: 'Пропущенные',
          ),
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('CallService: CallKit error $e');
    }
  }

  @override
  void dispose() {
    _callKitSubscription?.cancel();
    _ws.onCallSignal = null;
    hangUp();
    super.dispose();
  }

  void _handleCallSignal(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    final from = msg['from'] as String?;
    final callId = msg['callId'] as String?;
    if (kDebugMode) debugPrint('CallService: _handleCallSignal type=$type from=$from callId=$callId myUserId=${_chatService.userId}');
    if (callId == null) return;
    // call-hangup и call-reject могут приходить от сервера без from (офлайн-ситуация)
    if (from == null && type != 'call-hangup' && type != 'call-reject') return;
    // call-offer не игнорируем при from==self — звонок с другого своего устройства
    if (from != null && from == _chatService.userId && type != 'call-offer') return;
    // Гарантированно non-null для всех типов кроме server-hangup/reject (там from не используется)
    final fromId = from ?? '';

    switch (type) {
      case 'call-offer':
        if (kDebugMode) debugPrint('CallService: received call-offer from $fromId, callId=$callId state=$_state');
        // Если пользователь уже отклонил этот звонок из killed state — отклоняем offer немедленно
        if (_pendingReject != null && _pendingReject!.callId == callId) {
          final r = _pendingReject!;
          _pendingReject = null;
          _ws.send({'type': 'call-reject', 'to': r.to, 'callId': r.callId});
          if (kDebugMode) debugPrint('CallService: rejected buffered offer callId=$callId');
          break;
        }
        final pending = _pendingAcceptFromLaunch;
        if (_state == CallState.connecting &&
            pending != null &&
            pending.callId == callId &&
            pending.from == fromId) {
          _pendingOffer = {'callId': callId, 'from': fromId, 'sdp': msg['sdp']};
          _pendingAcceptFromLaunch = null;
          final callerName = (msg['callerName'] as String?)?.trim();
          final pushName = pending.fromName?.trim();
          // pushName — имя из contactNames сервера (имя звонящего в контактах получателя).
          // callerName — имя, которое звонящий сам себе выставил.
          // Предпочитаем pushName, если это не placeholder-значение.
          final pushIsReal = pushName != null &&
              pushName.isNotEmpty &&
              pushName != 'Входящий звонок' &&
              pushName != 'Кто-то звонит';
          final displayName = pushIsReal
              ? pushName
              : (callerName != null && callerName.isNotEmpty ? callerName : (pushName ?? fromId));
          _currentCall = CallInfo(
            callId: callId,
            remoteUserId: fromId,
            remoteName: displayName,
            isIncoming: true,
          );
          _setState(CallState.incoming);
          _acceptedFromBackground = true;
          if (kDebugMode) debugPrint('CallService: call-offer arrived for pending accept, auto-accepting');
          acceptCall();
          break;
        }
        if (_state == CallState.idle) {
          final callerName = (msg['callerName'] as String?)?.trim();
          final initialName = (callerName != null && callerName.isNotEmpty) ? callerName : fromId;
          if (kDebugMode) debugPrint('CallService: call-offer callerName=$callerName initialName=$initialName');
          _currentCall = CallInfo(
            callId: callId,
            remoteUserId: fromId,
            remoteName: initialName,
            isIncoming: true,
          );
          _pendingOffer = {'callId': callId, 'from': fromId, 'sdp': msg['sdp']};
          _setState(CallState.incoming);

          // Если приложение запущено принятием звонка из killed — сразу принимаем
          final pending = _pendingAcceptFromLaunch;
          if (pending != null && pending.callId == callId && pending.from == fromId) {
            _pendingAcceptFromLaunch = null;
            _acceptedFromBackground = true;
            if (kDebugMode) debugPrint('CallService: auto-accept from launch intent');
            acceptCall();
          } else {
            // В background — CallKit (полноэкранный звонок поверх других приложений)
            if (Platform.isAndroid && appLifecycleNotifier.value != AppLifecycleState.resumed) {
              _showCallKit(callId, initialName, fromId);
            }
            // В foreground показываем наш CallScreen, CallKit не нужен
            _getRemoteName(fromId).then((nameFromChat) {
              if (_currentCall != null && _currentCall!.remoteUserId == fromId) {
                // Используем имя из чата только если это не userId (есть контакт).
                // Иначе оставляем callerName из offer — имя звонящего.
                final displayName = (nameFromChat != fromId && nameFromChat.isNotEmpty)
                    ? nameFromChat
                    : initialName;
                _currentCall = CallInfo(
                  callId: _currentCall!.callId,
                  remoteUserId: fromId,
                  remoteName: displayName,
                  isIncoming: true,
                );
                notifyListeners();
              }
            });
          }
        }
        break;
      case 'call-answer':
        if (_currentCall?.callId == callId) {
          _handleAnswer(msg['sdp']);
        }
        break;
      case 'call-reoffer':
        if (_currentCall?.callId == callId && _peerConnection != null) {
          _handleReoffer(fromId, msg['sdp']);
        }
        break;
      case 'call-reanswer':
        if (_currentCall?.callId == callId && _peerConnection != null) {
          _handleReanswer(msg['sdp']);
        }
        break;
      case 'call-ice':
        if (_currentCall?.callId != callId) break;
        final c = msg['candidate'] as Map<String, dynamic>?;
        if (c == null) break;
        final candidate = RTCIceCandidate(
          c['candidate'] as String? ?? '',
          c['sdpMid'] as String? ?? '',
          (c['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (_peerConnection != null) {
          _peerConnection!.addCandidate(candidate).catchError((e) {
            if (kDebugMode) debugPrint('CallService: addCandidate error $e');
          });
        } else {
          _pendingIceCandidates.add(c);
        }
        break;
      case 'call-hangup':
        // Защита от повторной обработки (сервер может слать несколько hangup для одного callId)
        if (_currentCall?.callId == callId &&
            _state != CallState.idle &&
            _state != CallState.ended) {
          final wasIncoming = _currentCall!.isIncoming;
          final wasRinging = _state == CallState.incoming;
          final remoteId = _currentCall!.remoteUserId;
          _hideCallKit();
          FlutterRingtonePlayer().stop();
          _cleanupConnection(); // _currentCall сохраняем для отображения имени
          if (wasIncoming && wasRinging) {
            // Звонящий отменил до ответа → пропущенный в чате, сразу idle
            _chatService.addLocalMissedCallMessage(remoteId).catchError((_) {});
            _currentCall = null;
            _setState(CallState.idle);
          } else {
            // Разговор завершён — показываем имя 3 секунды, авто-dismiss
            _setState(CallState.ended);
          }
        }
        break;
      case 'call-reject':
        if (_currentCall?.callId == callId) {
          // Собеседник отклонил наш звонок — показываем имя 3 секунды, авто-dismiss
          _hideCallKit();
          FlutterRingtonePlayer().stop();
          _cleanupConnection(); // _currentCall сохраняем для отображения имени
          _setState(CallState.ended);
        }
        break;
      case 'call-offer-ack':
        // Подтверждение от сервера: сигнал дошёл, recipientOnline — абонент в сети
        if (kDebugMode) {
          final ack = msg['recipientOnline'] == true ? 'online' : 'offline';
          debugPrint('CallService: call-offer-ack callId=$callId recipient=$ack');
        }
        // Если получатель офлайн — пометим флаг для re-negotiate после получения answer
        if (msg['recipientOnline'] != true && _currentCall?.callId == callId) {
          _calledOfflineRecipient = true;
        }
        break;
    }
  }

  Future<void> _handleOffer(String callId, String from, Map<String, dynamic>? sdpMap) async {
    if (sdpMap == null) return;

    try {
      if (Platform.isAndroid) {
        await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration.communication);
      }
      _localStream = await navigator.mediaDevices.getUserMedia({'audio': true});
      await Helper.setSpeakerphoneOn(true);

      _peerConnection = await createPeerConnection(_iceServers);
      if (_peerConnection == null) {
        throw Exception('Не удалось создать соединение');
      }

      final tracks = _localStream!.getTracks();
      if (tracks.isEmpty) {
        throw Exception('Микрофон недоступен. На эмуляторе проверьте настройки.');
      }
      for (final track in tracks) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
        if (kDebugMode) debugPrint('CallService: ICE candidate (incoming) ${candidate.candidate?.length ?? 0} chars');
        _ws.send({
          'type': 'call-ice',
          'to': from,
          'callId': callId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      };

      _peerConnection!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams.first;
        } else {
          _remoteStream = null;
        }
        if (_state == CallState.connecting) _setState(CallState.connected);
        notifyListeners();
      };

      _peerConnection!.onIceConnectionState = (state) {
        if (kDebugMode) debugPrint('CallService: ICE state (incoming)=$state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          if (_state == CallState.connecting) _setState(CallState.connected);
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _setError('Соединение не установлено. Проверьте интернет.');
        }
        notifyListeners();
      };

      final sdpStr = sdpMap['sdp'] as String?;
      final sdpType = sdpMap['type'] as String?;
      if (sdpStr == null || sdpType == null) {
        throw Exception('Неверный формат SDP в offer');
      }
      final sdp = RTCSessionDescription(sdpStr, sdpType);

      final pc = _peerConnection;
      if (pc == null) {
        throw Exception('Соединение было закрыто');
      }
      await pc.setRemoteDescription(sdp);

      final answer = await pc.createAnswer({});
      if (answer.type == null || answer.sdp == null) {
        throw Exception('createAnswer вернул неполный SDP');
      }
      if (_peerConnection == null) return; // звонящий уже сбросил
      try {
        await pc.setLocalDescription(answer);
      } catch (e) {
        if (e.toString().contains('closed') || e.toString().contains('wrong state')) return;
        rethrow;
      }

      if (!_ws.isConnected) {
        throw Exception('Соединение потеряно. Проверьте интернет.');
      }
      _ws.send({
        'type': 'call-answer',
        'to': from,
        'callId': callId,
        'sdp': {
          'type': answer.type!,
          'sdp': answer.sdp!,
        },
      });

      while (_pendingIceCandidates.isNotEmpty && _peerConnection != null) {
        final c = _pendingIceCandidates.removeAt(0);
        try {
          await _peerConnection!.addCandidate(RTCIceCandidate(
            c['candidate'] as String? ?? '',
            c['sdpMid'] as String? ?? '',
            (c['sdpMLineIndex'] as num?)?.toInt(),
          ));
        } catch (_) {}
      }

      _setState(CallState.connecting);

      // Принятие из background/killed: переговоры могут «залипнуть».
      // Ручное включение камеры помогает — запускаем renegotiate автоматически.
      if (_acceptedFromBackground) {
        _acceptedFromBackground = false;
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (_peerConnection != null &&
              _currentCall != null &&
              (_state == CallState.connecting || _state == CallState.connected)) {
            _renegotiate();
            if (kDebugMode) debugPrint('CallService: auto-renegotiate after accept from background');
          }
        });
      }
    } catch (e, st) {
      _acceptedFromBackground = false;
      _setError('Ошибка при приёме: ${e.toString()}');
      if (kDebugMode) debugPrint('CallService: handleOffer error $e\n$st');
      if (_ws.isConnected) {
        _ws.send({'type': 'call-reject', 'to': from, 'callId': callId});
      }
      _setState(CallState.ended);
      _cleanup();
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic>? sdpMap) async {
    if (sdpMap == null || _peerConnection == null) return;

    final sdp = RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String);
    await _peerConnection!.setRemoteDescription(sdp);
    _setState(CallState.connected);

    // Если получатель принял из background/killed (пуш), ICE-кандидаты звонящего были потеряны.
    // Запускаем re-negotiate чтобы обменяться свежими ICE-кандидатами.
    if (_calledOfflineRecipient) {
      _calledOfflineRecipient = false;
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (_peerConnection != null &&
            _currentCall != null &&
            (_state == CallState.connected || _state == CallState.connecting)) {
          _renegotiate();
          if (kDebugMode) debugPrint('CallService: auto-renegotiate (caller, offline recipient answered)');
        }
      });
    }
  }

  Future<void> _handleReoffer(String from, dynamic sdpMap) async {
    if (sdpMap == null || _peerConnection == null || _currentCall == null) return;
    try {
      final sdp = RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String);
      await _peerConnection!.setRemoteDescription(sdp);
      if (_peerConnection == null) return;
      final answer = await _peerConnection!.createAnswer({});
      if (_peerConnection == null) return;
      try {
        await _peerConnection!.setLocalDescription(answer);
      } catch (e) {
        if (e.toString().contains('closed') || e.toString().contains('wrong state')) return;
        rethrow;
      }
      if (_peerConnection == null) return;
      _ws.send({
        'type': 'call-reanswer',
        'to': from,
        'callId': _currentCall!.callId,
        'sdp': {'type': answer.type, 'sdp': answer.sdp},
      });
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('CallService: _handleReoffer error $e');
    }
  }

  Future<void> _handleReanswer(Map<String, dynamic>? sdpMap) async {
    if (sdpMap == null || _peerConnection == null) return;
    try {
      final sdp = RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String);
      await _peerConnection!.setRemoteDescription(sdp);
      notifyListeners();
    } catch (e) {
      if (e.toString().contains('closed') || e.toString().contains('wrong state')) return;
      if (kDebugMode) debugPrint('CallService: _handleReanswer error $e');
    }
  }

  Future<void> startCall(String recipientId, String recipientName, {String? callerName}) async {
    if (_state != CallState.idle || !_ws.isConnected) return;

    _lastError = null;
    final callId = _uuid.v4();
    _currentCall = CallInfo(
      callId: callId,
      remoteUserId: recipientId,
      remoteName: recipientName,
      isIncoming: false,
    );
    _setState(CallState.calling);

    try {
      if (Platform.isAndroid) {
        await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration.communication);
      }
      _localStream = await navigator.mediaDevices.getUserMedia({'audio': true});
      await Helper.setSpeakerphoneOn(true);

      _peerConnection = await createPeerConnection(_iceServers);

      final tracks = _localStream!.getTracks();
      if (tracks.isEmpty) {
        throw Exception('Микрофон недоступен. На эмуляторе проверьте настройки.');
      }
      for (final track in tracks) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
        if (kDebugMode) debugPrint('CallService: ICE candidate (outgoing) ${candidate.candidate?.length ?? 0} chars');
        _ws.send({
          'type': 'call-ice',
          'to': recipientId,
          'callId': callId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      };

      _peerConnection!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams.first;
        } else {
          _remoteStream = null;
        }
        if (_state == CallState.connecting) _setState(CallState.connected);
        notifyListeners();
      };

      _peerConnection!.onIceConnectionState = (state) {
        if (kDebugMode) debugPrint('CallService: ICE state (outgoing)=$state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          if (_state == CallState.connecting) _setState(CallState.connected);
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _setError('Соединение не установлено. Проверьте интернет.');
        }
        notifyListeners();
      };

      final offer = await _peerConnection!.createOffer({});
      await _peerConnection!.setLocalDescription(offer);

      if (!_ws.isConnected) {
        _setError('Соединение потеряно. Проверьте интернет.');
        _setState(CallState.ended);
        _cleanup();
        return;
      }

      // Проверка: отвечает ли сервер (ping → pong)
      final ok = await _ws.checkConnection();
      if (!ok) {
        _setError('Сервер не отвечает. Проверьте интернет и URL: ${Config.serverUrl}');
        _setState(CallState.ended);
        _cleanup();
        return;
      }

      final nameToSend = (callerName != null && callerName.trim().isNotEmpty) ? callerName.trim() : 'Собеседник';
      if (kDebugMode) debugPrint('CallService: sending call-offer to $recipientId, callerName=$nameToSend');
      _ws.send({
        'type': 'call-offer',
        'to': recipientId,
        'callId': callId,
        'callerName': nameToSend,
        'sdp': {
          'type': offer.type,
          'sdp': offer.sdp,
        },
      });

      _setState(CallState.connecting);
    } catch (e, st) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _setError(msg.contains('null') ? 'Ошибка доступа к микрофону. На эмуляторе проверьте настройки.' : 'Ошибка: $msg');
      if (kDebugMode) debugPrint('CallService: startCall error $e\n$st');
      _setState(CallState.ended);
      _cleanup();
    }
  }

  Future<void> acceptCall() async {
    if (_state != CallState.incoming || _currentCall == null || _pendingOffer == null) return;

    final offer = _pendingOffer!;
    final callId = offer['callId'] as String?;
    final from = offer['from'] as String?;
    final sdp = offer['sdp'] as Map<String, dynamic>?;
    _pendingOffer = null;

    if (callId == null || from == null) return;

    missedCallFromPush = null;
    await _handleOffer(callId, from, sdp);
  }

  void rejectCall() {
    if (_state != CallState.incoming || _currentCall == null) return;
    dismissMissedCallFromPush();

    _ws.send({
      'type': 'call-reject',
      'to': _currentCall!.remoteUserId,
      'callId': _currentCall!.callId,
    });
    _cleanup(); // Получатель отклонил — сразу очищаем
    _setState(CallState.idle);
  }

  void hangUp() {
    if (_currentCall == null || _state == CallState.ended) {
      _cleanup();
      _setState(CallState.idle);
      return;
    }

    _ws.send({
      'type': 'call-hangup',
      'to': _currentCall!.remoteUserId,
      'callId': _currentCall!.callId,
    });
    _cleanupConnection();
    _setState(CallState.ended);
  }

  Future<void> toggleMute() async {
    if (_localStream == null) return;
    _isMuted = !_isMuted;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await Helper.setSpeakerphoneOn(_isSpeakerOn);
    notifyListeners();
  }

  Future<void> toggleVideo() async {
    if (_localStream == null || _peerConnection == null || _currentCall == null) return;
    if (_state != CallState.connected && _state != CallState.connecting) return;

    _isVideoOn = !_isVideoOn;
    final videoTracks = _localStream!.getVideoTracks();

    if (_isVideoOn) {
      if (videoTracks.isNotEmpty) {
        for (final t in videoTracks) {
          t.enabled = true;
        }
        notifyListeners();
        return;
      }
      try {
        final videoStream = await navigator.mediaDevices.getUserMedia({'video': {'facingMode': 'user'}});
        for (final track in videoStream.getVideoTracks()) {
          _localStream!.addTrack(track);
          await _peerConnection!.addTrack(track, _localStream!);
        }
        await _renegotiate();
      } catch (e) {
        if (kDebugMode) debugPrint('CallService: toggleVideo on error $e');
        _isVideoOn = false;
      }
    } else {
      if (videoTracks.isEmpty) {
        notifyListeners();
        return;
      }
      final tracksToRemove = videoTracks.toList();
      for (final track in tracksToRemove) {
        _localStream!.removeTrack(track);
        final senders = await _peerConnection!.getSenders();
        for (final s in senders) {
          if (s.track == track) {
            await _peerConnection!.removeTrack(s);
            break;
          }
        }
        track.stop();
      }
      await _renegotiate();
    }
    notifyListeners();
  }

  Future<void> _renegotiate() async {
    if (_peerConnection == null || _currentCall == null) return;
    try {
      final offer = await _peerConnection!.createOffer({});
      await _peerConnection!.setLocalDescription(offer);
      _ws.send({
        'type': 'call-reoffer',
        'to': _currentCall!.remoteUserId,
        'callId': _currentCall!.callId,
        'sdp': {'type': offer.type, 'sdp': offer.sdp},
      });
    } catch (e) {
      if (kDebugMode) debugPrint('CallService: _renegotiate error $e');
    }
  }

  Future<void> switchCamera() async {
    if (_localStream == null) return;
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isEmpty) return;
    try {
      await Helper.switchCamera(videoTracks.first);
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('CallService: switchCamera error $e');
    }
  }

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  /// Есть ли видео (локальное или удалённое)
  bool get hasVideo =>
      (_localStream?.getVideoTracks().isNotEmpty ?? false) ||
      (_remoteStream?.getVideoTracks().isNotEmpty ?? false);
}
