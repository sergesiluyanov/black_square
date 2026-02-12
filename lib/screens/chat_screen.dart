import 'dart:async';
import 'dart:io';

import 'package:black_square/models/chat.dart';
import 'package:black_square/models/message.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ChatScreen extends StatefulWidget {
  final Chat chat;

  const ChatScreen({super.key, required this.chat});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  List<Message> _messages = [];
  bool _isLoading = true;
  StreamSubscription<Message>? _messageSubscription;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _messageSubscription = context.read<ChatService>().incomingMessages.listen((msg) {
      if (msg.chatId == widget.chat.id && mounted) {
        setState(() => _messages = [..._messages, msg]);
        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    final chatService = context.read<ChatService>();
    final messages = await chatService.getMessages(widget.chat.id);
    setState(() {
      _messages = messages;
      _isLoading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    _controller.clear();
    final chatService = context.read<ChatService>();
    final message = await chatService.sendMessage(widget.chat.id, text);
    setState(() => _messages = [..._messages, message]);
    _scrollToBottom();
  }

  Future<void> _sendFile() async {
    final chatService = context.read<ChatService>();
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.any,
    );

    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);

    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Шифрование и отправка...'),
        backgroundColor: Color(0xFF333333),
      ),
    );

    final message = await chatService.sendFile(widget.chat.id, file);
    if (!mounted) return;
    setState(() => _messages = [..._messages, message]);
    _scrollToBottom();
    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Файл отправлен'),
        backgroundColor: Color(0xFF1A5F1A),
      ),
    );
  }

  Future<void> _openFile(Message message) async {
    if (message.type != MessageType.file || message.filePath == null) return;

    final chatService = context.read<ChatService>();
    try {
      final file = await chatService.getDecryptedFile(message.filePath!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Файл сохранён: ${file.path}'),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () {},
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xFF1A1A1A),
              child: Text(
                widget.chat.name.isNotEmpty ? widget.chat.name[0].toUpperCase() : '?',
                style: const TextStyle(color: Color(0xFF6B8AFF), fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              widget.chat.name,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF444444)),
                  )
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.lock, size: 48, color: Colors.white.withValues(alpha: 0.3)),
                            const SizedBox(height: 16),
                            Text(
                              'Сообщения зашифрованы',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Начните переписку',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 12),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          return _MessageBubble(
                            message: _messages[index],
                            onFileTap: (m) => _openFile(m),
                          );
                        },
                      ),
          ),
          _InputArea(
            controller: _controller,
            onSend: _sendMessage,
            onAttach: _sendFile,
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final void Function(Message)? onFileTap;

  const _MessageBubble({required this.message, this.onFileTap});

  @override
  Widget build(BuildContext context) {
    final isMe = message.isFromMe;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF6B8AFF) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.type == MessageType.file) ...[
              GestureDetector(
                onTap: onFileTap != null ? () => onFileTap!(message) : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.insert_drive_file, color: Colors.white70, size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.fileName ?? 'Файл',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (message.fileSize != null)
                            Text(
                              _formatSize(message.fileSize!),
                              style: const TextStyle(color: Colors.white60, fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              Text(
                message.content,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            const SizedBox(height: 4),
            Text(
              '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _InputArea extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  const _InputArea({
    required this.controller,
    required this.onSend,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D0D),
        border: Border(top: BorderSide(color: Color(0xFF1A1A1A))),
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              onPressed: onAttach,
              icon: const Icon(Icons.attach_file, color: Color(0xFF6B8AFF)),
              tooltip: 'Прикрепить файл',
            ),
            Expanded(
              child: TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Сообщение...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF1A1A1A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                maxLines: 4,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: onSend,
              icon: const Icon(Icons.send, color: Colors.white, size: 20),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF6B8AFF),
                shape: const CircleBorder(),
              ),
              tooltip: 'Отправить',
            ),
          ],
        ),
      ),
    );
  }
}
