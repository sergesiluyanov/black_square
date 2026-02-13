import 'package:black_square/models/chat.dart';
import 'package:black_square/screens/chat_screen.dart';
import 'package:black_square/services/call_service.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:flutter/material.dart';
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

        return Material(
          color: const Color(0xFF0A0A0A),
          child: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(),
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
                  showMissedCall ? 'Пропущенный звонок' : _stateText(state),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 14,
                  ),
                ),
                if (callService.lastError != null) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      callService.lastError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.red.shade300,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (showMissedCall) ...[
                  _CallButton(
                    icon: Icons.call_end,
                    color: Colors.white54,
                    onPressed: () => callService.dismissMissedCallFromPush(),
                  ),
                  const SizedBox(width: 48),
                  _CallButton(
                    icon: Icons.call,
                    color: const Color(0xFF1A5F1A),
                    onPressed: () => _onCallBack(context, callService),
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
                const SizedBox(height: 48),
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
          child: Icon(icon, color: color, size: 32),
        ),
      ),
    );
  }
}
