import 'dart:async';
import 'dart:io';

import 'package:black_square/models/chat.dart';
import 'package:black_square/models/message.dart';
import 'package:black_square/services/call_service.dart';
import 'package:black_square/services/chat_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

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
  final _newMessageIds = <String>{};
  StreamSubscription<Message>? _messageSubscription;
  StreamSubscription<Message>? _messageUpdatedSubscription;

  @override
  void initState() {
    super.initState();
    final chatService = context.read<ChatService>();
    chatService.setCurrentChatId(widget.chat.id);
    chatService.markChatAsRead(widget.chat.id);
    _loadMessages();
    _messageSubscription = chatService.incomingMessages.listen((msg) {
      if (msg.chatId == widget.chat.id && mounted) {
        setState(() {
          _messages = [..._messages, msg];
          _newMessageIds.add(msg.id);
        });
        _scrollToBottom();
      }
    });
    _messageUpdatedSubscription = chatService.messageUpdated.listen((msg) {
      if (msg.chatId == widget.chat.id && mounted) {
        final i = _messages.indexWhere((m) => m.id == msg.id);
        if (i >= 0) {
          setState(() => _messages = [..._messages]..[i] = msg);
          _scrollToBottom();
        }
      }
    });
  }

  @override
  void dispose() {
    context.read<ChatService>().setCurrentChatId(null);
    _messageSubscription?.cancel();
    _messageUpdatedSubscription?.cancel();
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
    final fileName = result.files.single.name;
    if (_isVideoFile(fileName)) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text('Отправка видео временно отключена'),
          backgroundColor: Color(0xFF333333),
        ),
      );
      return;
    }

    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Шифрование и отправка...'),
        backgroundColor: Color(0xFF333333),
      ),
    );

    try {
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
    } catch (e) {
      if (!mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('Ошибка: ${e.toString().replaceAll('Exception:', '').trim()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
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
        actions: [
          if (widget.chat.recipientId != null)
            IconButton(
              icon: const Icon(Icons.call, color: Color(0xFF6B8AFF)),
              onPressed: () {
                final callService = context.read<CallService>();
                if (callService.state != CallState.idle) return;
                if (!callService.canCall) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Нет подключения к серверу. Проверьте интернет.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }
                callService.startCall(
                  widget.chat.recipientId!,
                  widget.chat.name,
                );
              },
            ),
        ],
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
                          final msg = _messages[index];
                          return _MessageBubble(
                            message: msg,
                            chatService: context.read<ChatService>(),
                            onFileTap: (m) => _openFile(m),
                            showNewMarker: _newMessageIds.contains(msg.id),
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

bool _isImageFile(String? fileName) {
  if (fileName == null) return false;
  final ext = fileName.toLowerCase().split('.').last;
  return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext);
}

bool _isVideoFile(String? fileName) {
  if (fileName == null) return false;
  final ext = fileName.toLowerCase().split('.').last;
  return ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final ChatService chatService;
  final void Function(Message)? onFileTap;
  final bool showNewMarker;

  const _MessageBubble({
    required this.message,
    required this.chatService,
    this.onFileTap,
    this.showNewMarker = false,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = message.isFromMe;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showNewMarker && !isMe)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 6, bottom: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF6B8AFF),
                shape: BoxShape.circle,
              ),
            ),
          Flexible(
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
              if (message.filePath == null)
                _FileLoadingPlaceholder(fileName: message.fileName)
              else if (_isImageFile(message.fileName))
                _ImagePreview(
                  message: message,
                  chatService: chatService,
                  onTap: () => _showFullscreenImage(context, message),
                )
              else if (_isVideoFile(message.fileName))
                _VideoPreview(
                  message: message,
                  chatService: chatService,
                )
              else
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
              '${message.timestamp.toLocal().hour.toString().padLeft(2, '0')}:${message.timestamp.toLocal().minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    ),
  ],
  ),
);
  }

  void _showFullscreenImage(BuildContext context, Message message) async {
    try {
      final file = await chatService.getDecryptedFile(message.filePath!);
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Stack(
                children: [
                  Center(
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4,
                      child: Image.file(file, fit: BoxFit.contain),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _FileLoadingPlaceholder extends StatelessWidget {
  final String? fileName;

  const _FileLoadingPlaceholder({this.fileName});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 120,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              fileName ?? 'Загрузка...',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final Message message;
  final ChatService chatService;
  final VoidCallback onTap;

  const _ImagePreview({
    required this.message,
    required this.chatService,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: chatService.getDecryptedFile(message.filePath!),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image, color: Colors.white54, size: 48),
              const SizedBox(width: 8),
              Text(
                message.fileName ?? 'Фото',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          );
        }
        if (!snapshot.hasData) {
          return const SizedBox(
            width: 120,
            height: 120,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              ),
            ),
          );
        }
        return GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              snapshot.data!,
              width: 200,
              height: 200,
              fit: BoxFit.cover,
            ),
          ),
        );
      },
    );
  }
}

class _VideoPreview extends StatefulWidget {
  final Message message;
  final ChatService chatService;

  const _VideoPreview({required this.message, required this.chatService});

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  File? _thumbnail;
  bool _thumbnailChecked = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    final thumb = await widget.chatService.getVideoThumbnail(widget.message.filePath!);
    if (!mounted) return;
    setState(() {
      _thumbnail = thumb;
      _thumbnailChecked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_thumbnailChecked) {
      return const SizedBox(
        width: 200,
        height: 120,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: () => _showFullscreenVideo(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 200,
              height: 120,
              child: _thumbnail != null
                  ? Image.file(
                      _thumbnail!,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: Colors.black26,
                      child: const Center(
                        child: Icon(Icons.videocam, color: Colors.white38, size: 48),
                      ),
                    ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow,
              color: Colors.white,
              size: 32,
            ),
          ),
        ],
      ),
    );
  }

  void _showFullscreenVideo() async {
    if (!mounted) return;
    try {
      final file = await widget.chatService.getDecryptedFile(widget.message.filePath!);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => _FullscreenVideoPage(file: file),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ошибка загрузки видео'), backgroundColor: Colors.red),
        );
      }
    }
  }
}

class _FullscreenVideoPage extends StatefulWidget {
  final File file;

  const _FullscreenVideoPage({required this.file});

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.file)
      ..initialize().then((_) => setState(() {}))
      ..play();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: _controller.value.isInitialized
                  ? AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    )
                  : const CircularProgressIndicator(color: Colors.white),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
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
