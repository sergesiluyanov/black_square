import 'dart:async';

import 'package:black_square/services/chat_service.dart';
import 'package:black_square/services/websocket_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

/// STUN для WebRTC (NAT traversal)
/// sdpSemantics: 'unified-plan' — требуется addTrack вместо addStream
const _iceServers = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
  'sdpSemantics': 'unified-plan',
};

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

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  void _setState(CallState s) {
    _state = s;
    notifyListeners();
  }

  void _cleanup() {
    _pendingOffer = null;
    _peerConnection?.close();
    _peerConnection = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    _remoteStream = null;
    _currentCall = null;
  }

  void init() {
    _ws.onCallSignal = _handleCallSignal;
  }

  Future<String> _getRemoteName(String userId) async {
    final chats = await _chatService.getChats();
    for (final c in chats) {
      if (c.recipientId == userId) return c.name;
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
    if (from == null || callId == null) return;
    if (from == _chatService.userId) return;

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
        if (_currentCall?.callId == callId && _peerConnection != null) {
          final c = msg['candidate'] as Map<String, dynamic>?;
          if (c != null) {
            _peerConnection!.addCandidate(RTCIceCandidate(
              c['candidate'] as String?,
              c['sdpMid'] as String?,
              c['sdpMLineIndex'] as int?,
            ));
          }
        }
        break;
      case 'call-hangup':
      case 'call-reject':
        if (_currentCall?.callId == callId) {
          _setState(CallState.ended);
          _cleanup();
        }
        break;
    }
  }

  Future<void> _handleOffer(String callId, String from, Map<String, dynamic>? sdpMap) async {
    if (sdpMap == null) return;

    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

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

      _setState(CallState.connecting);
    } catch (e) {
      if (kDebugMode) debugPrint('CallService: handleOffer error $e');
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

    final callId = _uuid.v4();
    _currentCall = CallInfo(
      callId: callId,
      remoteUserId: recipientId,
      remoteName: recipientName,
      isIncoming: false,
    );
    _setState(CallState.calling);

    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

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
        notifyListeners();
      };

      final offer = await _peerConnection!.createOffer({});
      await _peerConnection!.setLocalDescription(offer);

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
    } catch (e) {
      if (kDebugMode) debugPrint('CallService: startCall error $e');
      _setState(CallState.ended);
      _cleanup();
    }
  }

  Future<void> acceptCall() async {
    if (_state != CallState.incoming || _currentCall == null || _pendingOffer == null) return;

    final offer = _pendingOffer!;
    final callId = offer['callId'] as String;
    final from = offer['from'] as String;
    final sdp = offer['sdp'] as Map<String, dynamic>?;

    _pendingOffer = null;
    await _handleOffer(callId, from, sdp);
  }

  void rejectCall() {
    if (_state != CallState.incoming || _currentCall == null) return;

    _ws.send({
      'type': 'call-reject',
      'to': _currentCall!.remoteUserId,
      'callId': _currentCall!.callId,
    });
    _setState(CallState.ended);
    _cleanup();
  }

  void hangUp() {
    if (_currentCall == null) {
      _cleanup();
      _setState(CallState.idle);
      return;
    }

    _ws.send({
      'type': 'call-hangup',
      'to': _currentCall!.remoteUserId,
      'callId': _currentCall!.callId,
    });
    _setState(CallState.ended);
    _cleanup();
  }

  Future<void> toggleMute() async {
    if (_localStream == null) return;
    _isMuted = !_isMuted;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
    notifyListeners();
  }

  MediaStream? get remoteStream => _remoteStream;
}
