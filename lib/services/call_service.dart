import 'dart:async';
import 'dart:io';

import 'package:black_square/config.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:black_square/services/websocket_service.dart';
import 'package:flutter/foundation.dart';
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
  } else {
    // Публичный TURN для 4G (freeTURN) — fallback когда свой coturn не настроен
    servers.add({
      'urls': 'turn:freeturn.net:3478',
      'username': 'free',
      'credential': 'free',
    });
  }
  return {
    'iceServers': servers,
    'sdpSemantics': 'unified-plan',
  };
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

  /// Последняя ошибка (очищается при новом звонке)
  String? _lastError;
  String? get lastError => _lastError;

  /// Пропущенный звонок из push — показываем экран «Перезвонить»
  ({String senderId, String senderName})? missedCallFromPush;
  void showMissedCallFromPush(String senderId, String senderName) {
    missedCallFromPush = (senderId: senderId, senderName: senderName);
    notifyListeners();
  }
  void dismissMissedCallFromPush() {
    missedCallFromPush = null;
    notifyListeners();
  }

  void _setState(CallState s) {
    _state = s;
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
    _cleanupConnection();
    _currentCall = null;
  }

  void _setError(String msg) {
    _lastError = msg;
    if (kDebugMode) debugPrint('CallService: $msg');
  }

  void init() {
    _ws.onCallSignal = _handleCallSignal;
  }

  Future<String> _getRemoteName(String userId) async {
    final chats = await _chatService.getChats();
    for (final c in chats) {
      if (c.recipientId == userId && c.name.isNotEmpty) return c.name;
    }
    return userId;
  }

  @override
  void dispose() {
    _ws.onCallSignal = null;
    hangUp();
    super.dispose();
  }

  void _handleCallSignal(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    final from = msg['from'] as String?;
    final callId = msg['callId'] as String?;
    if (kDebugMode) debugPrint('CallService: _handleCallSignal type=$type from=$from callId=$callId myUserId=${_chatService.userId}');
    if (from == null || callId == null) return;
    // call-offer не игнорируем при from==self — звонок с другого своего устройства
    if (from == _chatService.userId && type != 'call-offer') return;

    switch (type) {
      case 'call-offer':
        if (kDebugMode) debugPrint('CallService: received call-offer from $from, callId=$callId');
        if (_state == CallState.idle) {
          _currentCall = CallInfo(
            callId: callId,
            remoteUserId: from,
            remoteName: from,
            isIncoming: true,
          );
          _pendingOffer = {'callId': callId, 'from': from, 'sdp': msg['sdp']};
          _setState(CallState.incoming);
          _getRemoteName(from).then((name) {
            if (_currentCall != null && _currentCall!.remoteUserId == from) {
              _currentCall = CallInfo(
                callId: _currentCall!.callId,
                remoteUserId: from,
                remoteName: name,
                isIncoming: true,
              );
              notifyListeners();
            }
          });
        }
        break;
      case 'call-answer':
        if (_currentCall?.callId == callId) {
          _handleAnswer(msg['sdp']);
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
      case 'call-reject':
        if (_currentCall?.callId == callId) {
          _cleanupConnection();
          _setState(CallState.ended);
        }
        break;
      case 'call-offer-ack':
        // Подтверждение от сервера: сигнал дошёл, recipientOnline — абонент в сети
        if (kDebugMode) {
          final ack = msg['recipientOnline'] == true ? 'online' : 'offline';
          debugPrint('CallService: call-offer-ack callId=$callId recipient=$ack');
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
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      await Helper.setSpeakerphoneOn(false); // звук в трубку, не в динамик

      _peerConnection = await createPeerConnection(_iceServers);

      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
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
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          if (_state == CallState.connecting) _setState(CallState.connected);
        }
        notifyListeners();
      };

      final sdp = RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String);
      await _peerConnection!.setRemoteDescription(sdp);

      final answer = await _peerConnection!.createAnswer({});
      await _peerConnection!.setLocalDescription(answer);

      _ws.send({
        'type': 'call-answer',
        'to': from,
        'callId': callId,
        'sdp': {
          'type': answer.type,
          'sdp': answer.sdp,
        },
      });

      while (_pendingIceCandidates.isNotEmpty) {
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
    } catch (e, st) {
      _setError('Ошибка при приёме: ${e.toString()}');
      if (kDebugMode) debugPrint('CallService: handleOffer error $e\n$st');
      _ws.send({'type': 'call-reject', 'to': from, 'callId': callId});
      _setState(CallState.ended);
      _cleanup();
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic>? sdpMap) async {
    if (sdpMap == null || _peerConnection == null) return;

    final sdp = RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String);
    await _peerConnection!.setRemoteDescription(sdp);
    _setState(CallState.connected);
  }

  Future<void> startCall(String recipientId, String recipientName) async {
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
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      await Helper.setSpeakerphoneOn(false); // звук в трубку, не в динамик

      _peerConnection = await createPeerConnection(_iceServers);

      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      _peerConnection!.onIceCandidate = (candidate) {
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
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          if (_state == CallState.connecting) _setState(CallState.connected);
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

      if (kDebugMode) debugPrint('CallService: sending call-offer to $recipientId, callId=$callId');
      _ws.send({
        'type': 'call-offer',
        'to': recipientId,
        'callId': callId,
        'sdp': {
          'type': offer.type,
          'sdp': offer.sdp,
        },
      });

      _setState(CallState.connecting);
    } catch (e, st) {
      _setError('Ошибка: ${e.toString()}');
      if (kDebugMode) debugPrint('CallService: startCall error $e\n$st');
      _setState(CallState.ended);
      _cleanup();
    }
  }

  Future<void> acceptCall() async {
    if (_state != CallState.incoming || _currentCall == null || _pendingOffer == null) return;
    dismissMissedCallFromPush();

    final offer = _pendingOffer!;
    final callId = offer['callId'] as String;
    final from = offer['from'] as String;
    final sdp = offer['sdp'] as Map<String, dynamic>?;

    _pendingOffer = null;
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
    _setState(CallState.ended);
    _cleanup();
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

  MediaStream? get remoteStream => _remoteStream;
}
