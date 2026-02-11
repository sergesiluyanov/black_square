import 'dart:convert';
import 'dart:io';

import 'package:black_square/models/chat.dart';
import 'package:black_square/models/message.dart';
import 'package:black_square/services/encryption_service.dart';
import 'package:black_square/services/storage_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Сервис чатов с E2E шифрованием
class ChatService {
  final EncryptionService _encryption = EncryptionService();
  final StorageService _storage = StorageService();
  final _uuid = const Uuid();

  static const _messagesKey = 'messages';
  static const _chatsKey = 'chats';
  static const _userIdKey = 'user_id';

  String? _userId;

  Future<void> initialize() async {
    await _encryption.initialize();
    await _storage.initialize();
    _userId ??= await _storage.getString(_userIdKey) ?? _uuid.v4();
    await _storage.setString(_userIdKey, _userId!);
  }

  String get userId => _userId ?? '';

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
  Future<Chat> createChat(String name) async {
    final chat = Chat(
      id: _uuid.v4(),
      name: name,
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
