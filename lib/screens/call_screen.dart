import 'package:black_square/screens/chat_screen.dart';
import 'package:black_square/services/call_service.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

Future<void> _onCallBack(BuildContext context, CallService callService) async {
  final missed = callService.missedCallFromPush;
  if (missed == null) return;
  callService.dismissMissedCallFromPush();
  final chatService = context.read<ChatService>();
  final chats = await chatService.getChats();
  final chat = chats.where((c) => c.recipientId == missed.senderId).firstOrNull;
  if (!context.mounted) return;
  if (chat != null) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
    callService.startCall(missed.senderId, missed.senderName);
  }
}

/// Экран активного или входящего звонка
class CallScreen extends StatelessWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: context.watch<CallService>(),
      builder: (context, _) {
        final callService = context.read<CallService>();
        final state = callService.state;
        final call = callService.currentCall;
        final missed = callService.missedCallFromPush;

        if (state == CallState.idle && missed == null) {
          return const SizedBox.shrink();
        }

        final displayName = call?.remoteName ?? missed?.senderName ?? '?';
        final showMissedCall = state == CallState.idle && missed != null;
        final showVideo = callService.localStream != null &&
            state != CallState.incoming &&
            state != CallState.ended;

        return Material(
          color: const Color(0xFF0A0A0A),
          child: SafeArea(
            child: Stack(
              children: [
                if (showVideo)
                  _VideoCallView(
                    localStream: callService.localStream,
                    remoteStream: callService.remoteStream,
                  )
                else
                  _AvatarContent(
                    displayName: displayName,
                    stateText: showMissedCall
                        ? 'Пропущенный звонок'
                        : _stateText(state),
                    error: callService.lastError,
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _CallControls(
                    callService: callService,
                    showMissedCall: showMissedCall,
                    state: state,
                    onCallBack: () => _onCallBack(context, callService),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _stateText(CallState state) {
    switch (state) {
      case CallState.calling:
        return 'Вызов...';
      case CallState.incoming:
        return 'Входящий звонок';
      case CallState.connecting:
        return 'Подключение...';
      case CallState.connected:
        return 'В разговоре';
      case CallState.ended:
        return 'Звонок завершён';
      default:
        return '';
    }
  }
}

class _AvatarContent extends StatelessWidget {
  final String displayName;
  final String stateText;
  final String? error;

  const _AvatarContent({
    required this.displayName,
    required this.stateText,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 48,
            backgroundColor: const Color(0xFF1A1A1A),
            child: Text(
              displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
              style: const TextStyle(
                color: Color(0xFF6B8AFF),
                fontSize: 36,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            displayName,
            style: const TextStyle(color: Colors.white, fontSize: 22),
          ),
          const SizedBox(height: 8),
          Text(
            stateText,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.red.shade300,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VideoCallView extends StatefulWidget {
  final MediaStream? localStream;
  final MediaStream? remoteStream;

  const _VideoCallView({
    required this.localStream,
    required this.remoteStream,
  });

  @override
  State<_VideoCallView> createState() => _VideoCallViewState();
}

class _VideoCallViewState extends State<_VideoCallView> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (!mounted) return;
    setState(() {
      _initialized = true;
      _localRenderer.srcObject = widget.localStream;
      _remoteRenderer.srcObject = widget.remoteStream;
    });
  }

  @override
  void didUpdateWidget(_VideoCallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _localRenderer.srcObject = widget.localStream;
    _remoteRenderer.srcObject = widget.remoteStream;
  }

  @override
  void dispose() {
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6B8AFF)),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Удалённое видео — на весь экран
        RTCVideoView(
          _remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
        // Локальное видео — PiP в углу
        Positioned(
          top: 16,
          right: 16,
          width: 120,
          height: 160,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: RTCVideoView(
              _localRenderer,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
        ),
      ],
    );
  }
}

class _CallControls extends StatelessWidget {
  final CallService callService;
  final bool showMissedCall;
  final CallState state;
  final VoidCallback onCallBack;

  const _CallControls({
    required this.callService,
    required this.showMissedCall,
    required this.state,
    required this.onCallBack,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showMissedCall) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallButton(
                  icon: Icons.call_end,
                  color: Colors.white54,
                  onPressed: () => callService.dismissMissedCallFromPush(),
                ),
                const SizedBox(width: 48),
                _CallButton(
                  icon: Icons.call,
                  color: const Color(0xFF1A5F1A),
                  onPressed: onCallBack,
                ),
              ],
            ),
          ] else if (state == CallState.incoming) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallButton(
                  icon: Icons.call_end,
                  color: Colors.red,
                  onPressed: () => callService.rejectCall(),
                ),
                const SizedBox(width: 48),
                _CallButton(
                  icon: Icons.call,
                  color: const Color(0xFF1A5F1A),
                  onPressed: () => callService.acceptCall(),
                ),
              ],
            ),
          ] else ...[
            // Верхний ряд: видео и переключение камеры
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallButton(
                  icon: callService.isVideoOn ? Icons.videocam : Icons.videocam_off,
                  color: callService.isVideoOn
                      ? const Color(0xFF6B8AFF)
                      : Colors.red,
                  onPressed: () => callService.toggleVideo(),
                ),
                const SizedBox(width: 24),
                _CallButton(
                  icon: Icons.cameraswitch,
                  color: Colors.white54,
                  onPressed: () => callService.switchCamera(),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Нижний ряд: микрофон, динамик, завершить
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallButton(
                  icon: callService.isMuted ? Icons.mic_off : Icons.mic,
                  color: callService.isMuted
                      ? Colors.red
                      : const Color(0xFF6B8AFF),
                  onPressed: () => callService.toggleMute(),
                ),
                const SizedBox(width: 24),
                _CallButton(
                  icon: callService.isSpeakerOn ? Icons.volume_up : Icons.phone_in_talk,
                  color: callService.isSpeakerOn
                      ? const Color(0xFF6B8AFF)
                      : Colors.white54,
                  onPressed: () => callService.toggleSpeaker(),
                ),
                const SizedBox(width: 24),
                _CallButton(
                  icon: Icons.call_end,
                  color: Colors.red,
                  onPressed: () => callService.hangUp(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _CallButton({
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.2),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Icon(icon, color: color, size: 28),
        ),
      ),
    );
  }
}
