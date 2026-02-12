import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:black_square/config.dart';
import 'package:black_square/models/chat.dart';
import 'package:black_square/models/message.dart';
import 'package:black_square/services/encryption_service.dart';
import 'package:black_square/services/storage_service.dart';
import 'package:black_square/services/websocket_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Сервис чатов с E2E шифрованием
class ChatService {
  final EncryptionService _encryption = EncryptionService();
  final StorageService _storage = StorageService();
  final WebSocketService _ws = WebSocketService();
  final _uuid = const Uuid();

  static const _messagesKey = 'messages';
  static const _chatsKey = 'chats';
  static const _userIdKey = 'user_id';

  String? _userId;

  String get userId => _userId ?? '';

  final _incomingMessageController = StreamController<Message>.broadcast();
  final _chatsUpdatedController = StreamController<void>.broadcast();

  WebSocketService get ws => _ws;
  Stream<Message> get incomingMessages => _incomingMessageController.stream;
  Stream<void> get chatsUpdated => _chatsUpdatedController.stream;

  Future<void> initialize() async {
    await _encryption.initialize();
    await _storage.initialize();
    _userId ??= await _storage.getString(_userIdKey) ?? _uuid.v4();
    await _storage.setString(_userIdKey, _userId!);

    _ws.onMessage = _handleIncomingMessage;
    try {
      await _ws.connect(Config.serverUrl, _userId!);
    } catch (_) {}
  }

  void _handleIncomingMessage(Map<String, dynamic> msg) {
    if (msg['type'] != 'message') return;
    final from = msg['from'] as String?;
    final chatId = msg['chatId'] as String?;
    final payload = msg['payload'];
    final timestamp = msg['timestamp'] as String?;
    if (from == null || payload == null) return;

    Map<String, dynamic>? messageJson;
    if (payload is String) {
      try {
        messageJson = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
    } else if (payload is Map<String, dynamic>) {
      messageJson = payload;
    } else {
      return;
    }

    final content = messageJson['content'] as String? ?? '';
    _saveIncomingMessage(
      from: from,
      chatId: chatId ?? from,
      content: content,
      timestamp: timestamp != null ? DateTime.tryParse(timestamp) : null,
    );
  }

  Future<void> _saveIncomingMessage({
    required String from,
    required String chatId,
    required String content,
    DateTime? timestamp,
  }) async {
    final chats = await getChats();
    Chat? chat;
    for (final c in chats) {
      if (c.recipientId == from) {
        chat = c;
        break;
      }
    }

    if (chat == null) {
      chat = Chat(
        id: _uuid.v4(),
        name: from,
        recipientId: from,
        lastMessageAt: timestamp ?? DateTime.now(),
      );
      await _saveChat(chat);
      _chatsUpdatedController.add(null);
    }

    final message = Message(
      id: _uuid.v4(),
      chatId: chat.id,
      senderId: from,
      content: content,
      timestamp: timestamp ?? DateTime.now(),
      type: MessageType.text,
      isFromMe: false,
    );
    await _saveMessage(message);

    await _saveChat(chat.copyWith(
      lastMessageAt: message.timestamp,
      lastMessagePreview: content.length > 50 ? '${content.substring(0, 50)}...' : content,
    ));

    _incomingMessageController.add(message);
  }

  /// Получить все чаты
  Future<List<Chat>> getChats() async {
    final encrypted = await _storage.getString(_chatsKey);
    if (encrypted == null) return [];

    try {
      final json = jsonDecode(_encryption.decryptText(encrypted)) as List;
      return json.map((e) => Chat.fromJson(e as Map<String, dynamic>)).toList()
        ..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
    } catch (_) {
      return [];
    }
  }

  /// Создать новый чат
  Future<Chat> createChat(String name, {String? recipientId}) async {
    final chat = Chat(
      id: _uuid.v4(),
      name: name,
      recipientId: recipientId,
      lastMessageAt: DateTime.now(),
    );
    await _saveChat(chat);
    return chat;
  }

  Future<void> _saveChat(Chat chat) async {
    final chats = await getChats();
    final updated = chats.where((c) => c.id != chat.id).toList()
      ..insert(0, chat);
    await _storage.setString(
      _chatsKey,
      _encryption.encryptText(jsonEncode(updated.map((c) => c.toJson()).toList())),
    );
  }

  /// Получить сообщения чата
  Future<List<Message>> getMessages(String chatId) async {
    final encrypted = await _storage.getString(_messagesKey);
    if (encrypted == null) return [];

    try {
      final json = jsonDecode(_encryption.decryptText(encrypted)) as Map<String, dynamic>;
      final list = json[chatId] as List? ?? [];
      return list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    } catch (_) {
      return [];
    }
  }

  /// Отправить текстовое сообщение
  Future<Message> sendMessage(String chatId, String content) async {
    final message = Message(
      id: _uuid.v4(),
      chatId: chatId,
      senderId: _userId!,
      content: content,
      timestamp: DateTime.now(),
      type: MessageType.text,
      isFromMe: true,
    );
    await _saveMessage(message);

    final chats = await getChats();
    final chat = chats.firstWhere((c) => c.id == chatId);
    await _saveChat(chat.copyWith(
      lastMessageAt: message.timestamp,
      lastMessagePreview: content.length > 50 ? '${content.substring(0, 50)}...' : content,
    ));

    if (_ws.isConnected && chat.recipientId != null) {
      _ws.sendMessage(
        to: chat.recipientId!,
        chatId: chatId,
        payload: jsonEncode(message.toJson()),
      );
    }

    return message;
  }

  /// Отправить файл
  Future<Message> sendFile(String chatId, File file) async {
    final appDir = await getApplicationDocumentsDirectory();
    final filesDir = Directory('${appDir.path}/black_square_files');
    if (!await filesDir.exists()) await filesDir.create(recursive: true);

    final fileName = file.path.split(RegExp(r'[/\\]')).last;
    final encryptedPath = '${filesDir.path}/${_uuid.v4()}';

    final fileBytes = await file.readAsBytes();
    final encrypted = _encryption.encryptBytes(fileBytes);
    await File(encryptedPath).writeAsBytes(encrypted);

    final message = Message(
      id: _uuid.v4(),
      chatId: chatId,
      senderId: _userId!,
      content: encryptedPath,
      timestamp: DateTime.now(),
      type: MessageType.file,
      isFromMe: true,
      fileName: fileName,
      filePath: encryptedPath,
      fileSize: file.lengthSync(),
    );
    await _saveMessage(message);

    final chats = await getChats();
    final chat = chats.firstWhere((c) => c.id == chatId);
    await _saveChat(chat.copyWith(
      lastMessageAt: message.timestamp,
      lastMessagePreview: '📎 $fileName',
    ));

    return message;
  }

  /// Расшифровать и получить файл
  Future<File> getDecryptedFile(String encryptedPath) async {
    final encrypted = await File(encryptedPath).readAsBytes();
    final decrypted = _encryption.decryptBytes(encrypted);
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}');
    await tempFile.writeAsBytes(decrypted);
    return tempFile;
  }

  Future<void> _saveMessage(Message message) async {
    final encrypted = await _storage.getString(_messagesKey);
    Map<String, dynamic> allMessages = {};

    if (encrypted != null) {
      try {
        allMessages = jsonDecode(_encryption.decryptText(encrypted)) as Map<String, dynamic>;
      } catch (_) {}
    }

    final chatMessages = (allMessages[message.chatId] as List?)?.cast<Map<String, dynamic>>() ?? [];
    chatMessages.add(message.toJson());
    allMessages[message.chatId] = chatMessages;

    await _storage.setString(
      _messagesKey,
      _encryption.encryptText(jsonEncode(allMessages)),
    );
  }
}
