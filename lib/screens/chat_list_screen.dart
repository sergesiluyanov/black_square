import 'dart:async';

import 'package:black_square/models/chat.dart';
import 'package:black_square/screens/chat_screen.dart';
import 'package:black_square/screens/new_chat_screen.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<Chat> _chats = [];
  bool _isLoading = true;
  StreamSubscription? _chatsSubscription;

  @override
  void initState() {
    super.initState();
    _loadChats();
    _chatsSubscription = context.read<ChatService>().chatsUpdated.listen((_) {
      if (mounted) _loadChats(silent: true);
    });
  }

  @override
  void dispose() {
    _chatsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadChats({bool silent = false}) async {
    if (!silent) {
      setState(() => _isLoading = true);
    }
    final chats = await context.read<ChatService>().getChats();
    if (mounted) {
      setState(() {
        _chats = chats;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.crop_square, color: Colors.white, size: 28),
            SizedBox(width: 12),
            Text(
              'Black Square',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        actions: [
          Builder(
            builder: (context) {
              final isConnected = context.read<ChatService>().ws.isConnected;
              return IconButton(
                icon: Icon(
                  isConnected ? Icons.wifi : Icons.wifi_off,
                  color: isConnected ? const Color(0xFF4CAF50) : Colors.white54,
                  size: 22,
                ),
                onPressed: () => _showConnectionStatus(context),
                tooltip: isConnected ? 'Подключено' : 'Нет подключения',
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.lock, color: Colors.white54, size: 22),
            onPressed: () => _showEncryptionInfo(context),
            tooltip: 'Шифрование',
          ),
        ],
      ),
      body: _isLoading && _chats.isEmpty
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF444444)),
            )
          : _chats.isEmpty
              ? _EmptyState(
                  onNewChat: () => _openNewChat(context),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _chats.length,
                  itemBuilder: (context, index) {
                    final chat = _chats[index];
                    return Dismissible(
                      key: ValueKey(chat.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
                      ),
                      confirmDismiss: (direction) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: const Color(0xFF1A1A1A),
                            title: const Text(
                              'Удалить чат?',
                              style: TextStyle(color: Colors.white),
                            ),
                            content: Text(
                              'Чат «${chat.name}» и все сообщения будут удалены безвозвратно.',
                              style: const TextStyle(color: Colors.white70, height: 1.5),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Удалить', style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        );
                      },
                      onDismissed: (_) async {
                        await context.read<ChatService>().deleteChat(chat.id);
                      },
                      child: _ChatTile(
                        chat: chat,
                        onTap: () => _openChat(context, chat),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openNewChat(context),
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
    );
  }

  void _openNewChat(BuildContext context) async {
    final chat = await Navigator.push<Chat>(
      context,
      MaterialPageRoute(builder: (_) => const NewChatScreen()),
    );
    if (chat != null && context.mounted) {
      _openChat(context, chat);
    }
  }

  void _openChat(BuildContext context, Chat chat) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(chat: chat),
      ),
    ).then((_) async {
      await context.read<ChatService>().markChatAsRead(chat.id);
      if (mounted) _loadChats(silent: true);
    });
  }

  void _showConnectionStatus(BuildContext context) {
    final isConnected = context.read<ChatService>().ws.isConnected;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Row(
          children: [
            Icon(
              isConnected ? Icons.wifi : Icons.wifi_off,
              color: isConnected ? const Color(0xFF4CAF50) : Colors.red,
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(
              isConnected ? 'Подключено' : 'Нет подключения',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        content: Text(
          isConnected
              ? 'Сервер доступен. Сообщения и файлы отправляются через облако.'
              : 'Проверьте интернет и что сервер запущен. Сообщения сохраняются локально.',
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Color(0xFF6B8AFF))),
          ),
        ],
      ),
    );
  }

  void _showEncryptionInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Сквозное шифрование',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Все сообщения и файлы шифруются на вашем устройстве с помощью AES-256. '
          'Ключ хранится в защищённом хранилище. Расшифровать сообщения может только получатель.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Понятно', style: TextStyle(color: Color(0xFF6B8AFF))),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onNewChat;

  const _EmptyState({required this.onNewChat});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.crop_square, size: 40, color: Color(0xFF444444)),
            ),
            const SizedBox(height: 24),
            const Text(
              'Нет чатов',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Нажмите + чтобы начать новый чат',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: onNewChat,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('Новый чат'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6B8AFF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final Chat chat;
  final VoidCallback onTap;

  const _ChatTile({required this.chat, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasUnread = chat.unreadCount > 0;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFF1A1A1A),
            child: Text(
              chat.name.isNotEmpty ? chat.name[0].toUpperCase() : '?',
              style: const TextStyle(color: Color(0xFF6B8AFF), fontWeight: FontWeight.w600),
            ),
          ),
          if (hasUnread)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  color: Color(0xFF6B8AFF),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
      title: Text(
        chat.name,
        style: TextStyle(
          color: Colors.white,
          fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        chat.lastMessagePreview ?? 'Нет сообщений',
        style: TextStyle(
          color: hasUnread ? Colors.white70 : Colors.white54,
          fontSize: 13,
          fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        _formatTime(chat.lastMessageAt),
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    if (local.day == now.day && local.month == now.month && local.year == now.year) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.day}.${local.month}';
  }
}
