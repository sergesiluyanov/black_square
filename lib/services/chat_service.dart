import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:black_square/config.dart';
import 'package:black_square/models/chat.dart';
import 'package:flutter/foundation.dart';
import 'package:black_square/models/message.dart';
import 'package:black_square/services/encryption_service.dart';
import 'package:black_square/services/storage_service.dart';
import 'package:black_square/services/websocket_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Макс. размер файла ~100 MB
const _maxFileSizeBytes = 100 * 1024 * 1024;

/// Расшифровка в изоляте — не блокирует UI
Uint8List _decryptFileInIsolate(List<Object> args) {
  final fileData = args[0] as String;
  final shareCode = args[1] as String;
  return EncryptionService.decryptBytesWithShareCode(
    Uint8List.fromList(base64Decode(fileData)),
    shareCode,
  );
}

/// Чтение файла в изоляте
Uint8List _readFileInIsolate(List<Object> args) {
  return File(args[0] as String).readAsBytesSync();
}

/// Шифрование в изоляте — не блокирует UI
Uint8List _encryptFileInIsolate(List<Object> args) {
  final fileBytes = args[0] as Uint8List;
  final shareCode = args[1] as String;
  return EncryptionService.encryptBytesWithShareCode(fileBytes, shareCode);
}

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
  final _messageUpdatedController = StreamController<Message>.broadcast();

  WebSocketService get ws => _ws;
  Stream<Message> get incomingMessages => _incomingMessageController.stream;
  Stream<void> get chatsUpdated => _chatsUpdatedController.stream;
  Stream<Message> get messageUpdated => _messageUpdatedController.stream;

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
    _handleIncomingMessageAsync(msg).catchError((e, st) {
      if (kDebugMode) debugPrint('ChatService: error handling message: $e\n$st');
    });
  }

  Future<void> _handleIncomingMessageAsync(Map<String, dynamic> msg) async {
    final from = msg['from'] as String?;
    final chatId = msg['chatId'] as String?;
    final payload = msg['payload'];
    final timestamp = msg['timestamp'] as String?;
    if (from == null || payload == null) return;

    if (kDebugMode) debugPrint('ChatService: received message from $from, payload type: ${payload.runtimeType}');

    Map<String, dynamic>? messageJson;
    String? shareCode;
    if (payload is String) {
      try {
        messageJson = jsonDecode(payload) as Map<String, dynamic>;
        shareCode = messageJson['shareCode'] as String?;
        if (kDebugMode) debugPrint('ChatService: parsed as plain JSON (first message?)');
      } catch (_) {
        final chats = await getChats();
        Chat? chat;
        for (final c in chats) {
          if (c.recipientId == from) {
            chat = c;
            break;
          }
        }
        if (chat != null && chat.shareCode != null) {
          try {
            final decrypted = EncryptionService.decryptWithShareCode(payload, chat.shareCode!);
            messageJson = jsonDecode(decrypted) as Map<String, dynamic>;
            if (kDebugMode) debugPrint('ChatService: decrypted successfully');
          } catch (e) {
            if (kDebugMode) debugPrint('ChatService: decrypt failed for msg from $from: $e');
            return;
          }
        } else {
          if (kDebugMode) debugPrint('ChatService: no chat or shareCode for $from, dropping');
          return;
        }
      }
    } else if (payload is Map<String, dynamic>) {
      messageJson = payload;
      shareCode = messageJson['shareCode'] as String?;
    } else {
      return;
    }
    final content = messageJson['content'] as String? ?? '';
    MessageType type = MessageType.text;
    try {
      final typeStr = messageJson['type'] as String? ?? 'text';
      type = MessageType.values.byName(typeStr);
    } catch (_) {
      type = MessageType.text;
    }
    final fileName = messageJson['fileName'] as String?;
    final fileData = messageJson['fileData'] as String?;

    final fileSize = messageJson['fileSize'] as int?;

    await _saveIncomingMessage(
      from: from,
      chatId: chatId ?? from,
      content: content,
      shareCode: shareCode,
      type: type,
      fileName: fileName,
      fileData: fileData,
      fileSize: fileSize,
      timestamp: timestamp != null ? DateTime.tryParse(timestamp) : null,
    );
  }

  Future<void> _saveIncomingMessage({
    required String from,
    required String chatId,
    required String content,
    String? shareCode,
    MessageType type = MessageType.text,
    String? fileName,
    String? fileData,
    int? fileSize,
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
        shareCode: shareCode,
        lastMessageAt: timestamp ?? DateTime.now(),
      );
      await _saveChat(chat);
      _chatsUpdatedController.add(null);
    } else if (shareCode != null) {
      // Всегда используем shareCode отправителя — он шифрует своими ключом
      chat = chat.copyWith(shareCode: shareCode);
      await _saveChat(chat);
    }

    String filePath = content;
    final isFile = type == MessageType.file && fileData != null;
    final messageId = _uuid.v4();

    if (isFile) {
      // Показываем сообщение сразу, файл обрабатываем в фоне
      final placeholderMessage = Message(
        id: messageId,
        chatId: chat.id,
        senderId: from,
        content: '',
        timestamp: timestamp ?? DateTime.now(),
        type: type,
        isFromMe: false,
        fileName: fileName,
        filePath: null, // ещё загружается
        fileSize: fileSize,
      );
      await _saveMessage(placeholderMessage);
      final preview = '📎 ${fileName ?? 'Файл'}';
      await _saveChat(chat.copyWith(
        lastMessageAt: placeholderMessage.timestamp,
        lastMessagePreview: preview,
      ));
      _incomingMessageController.add(placeholderMessage);

      // Обработка файла в фоне
      _processAndUpdateFile(
        messageId: messageId,
        chatId: chat.id,
        from: from,
        fileData: fileData!,
        shareCode: chat.shareCode!,
        fileName: fileName,
        fileSize: fileSize,
        timestamp: timestamp ?? DateTime.now(),
      );
      return;
    }

    final message = Message(
      id: messageId,
      chatId: chat.id,
      senderId: from,
      content: filePath,
      timestamp: timestamp ?? DateTime.now(),
      type: type,
      isFromMe: false,
      fileName: fileName,
      filePath: type == MessageType.file ? filePath : null,
      fileSize: type == MessageType.file ? fileSize : null,
    );
    await _saveMessage(message);

    final preview = type == MessageType.file
        ? '📎 ${fileName ?? 'Файл'}'
        : content.length > 50 ? '${content.substring(0, 50)}...' : content;

    await _saveChat(chat.copyWith(
      lastMessageAt: message.timestamp,
      lastMessagePreview: preview,
    ));

    _incomingMessageController.add(message);
  }

  Future<void> _processAndUpdateFile({
    required String messageId,
    required String chatId,
    required String from,
    required String fileData,
    required String shareCode,
    String? fileName,
    int? fileSize,
    required DateTime timestamp,
  }) async {
    try {
      final estimatedSize = (fileData.length * 3) ~/ 4;
      if (estimatedSize > _maxFileSizeBytes) {
        if (kDebugMode) debugPrint('ChatService: file too large ($estimatedSize bytes)');
        return;
      }
      final decrypted = await compute(_decryptFileInIsolate, [fileData, shareCode]);

      final appDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${appDir.path}/black_square_files');
      if (!await filesDir.exists()) await filesDir.create(recursive: true);
      final filePath = '${filesDir.path}/${_uuid.v4()}';
      final encrypted = _encryption.encryptBytes(decrypted);
      await File(filePath).writeAsBytes(encrypted);

      final updatedMessage = Message(
        id: messageId,
        chatId: chatId,
        senderId: from,
        content: filePath,
        timestamp: timestamp,
        type: MessageType.file,
        isFromMe: false,
        fileName: fileName,
        filePath: filePath,
        fileSize: fileSize,
      );
      await _updateMessageInStorage(updatedMessage);
      _messageUpdatedController.add(updatedMessage);
    } catch (e) {
      if (kDebugMode) debugPrint('ChatService: failed to save file: $e');
    }
  }

  Future<void> _updateMessageInStorage(Message updated) async {
    final encrypted = await _storage.getString(_messagesKey);
    if (encrypted == null) return;
    try {
      final allMessages = jsonDecode(_encryption.decryptText(encrypted)) as Map<String, dynamic>;
      final list = allMessages[updated.chatId] as List? ?? [];
      final index = list.indexWhere((e) => (e as Map)['id'] == updated.id);
      if (index >= 0) {
        list[index] = updated.toJson();
        allMessages[updated.chatId] = list;
        await _storage.setString(
          _messagesKey,
          _encryption.encryptText(jsonEncode(allMessages)),
        );
      }
    } catch (_) {}
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
  Future<Chat> createChat(String name, {String? recipientId, String? shareCode}) async {
    final code = shareCode ?? _generateShareCode();
    final chat = Chat(
      id: _uuid.v4(),
      name: name,
      recipientId: recipientId,
      shareCode: code,
      lastMessageAt: DateTime.now(),
    );
    await _saveChat(chat);
    return chat;
  }

  String _generateShareCode() {
    final random = _uuid.v4().replaceAll('-', '') + _uuid.v4().replaceAll('-', '');
    return random.substring(0, 32);
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
      final messages = await getMessages(chatId);
      final isFirstMessage = messages.length <= 1;
      String payload;
      if (isFirstMessage) {
        payload = jsonEncode({
          ...message.toJson(),
          'shareCode': chat.shareCode,
        });
      } else {
        payload = EncryptionService.encryptWithShareCode(
          jsonEncode(message.toJson()),
          chat.shareCode!,
        );
      }
      _ws.sendMessage(
        to: chat.recipientId!,
        chatId: chatId,
        payload: payload,
      );
    }

    return message;
  }

  /// Отправить файл
  Future<Message> sendFile(String chatId, File file) async {
    if (file.lengthSync() > _maxFileSizeBytes) {
      throw Exception('Файл слишком большой (макс. 100 MB)');
    }
    final appDir = await getApplicationDocumentsDirectory();
    final filesDir = Directory('${appDir.path}/black_square_files');
    if (!await filesDir.exists()) await filesDir.create(recursive: true);

    final fileName = file.path.split(RegExp(r'[/\\]')).last;
    final encryptedPath = '${filesDir.path}/${_uuid.v4()}';

    final fileBytes = await compute(_readFileInIsolate, [file.path]);
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

    if (_ws.isConnected && chat.recipientId != null && chat.shareCode != null) {
      final encryptedFile = await compute(_encryptFileInIsolate, [fileBytes, chat.shareCode!]);
      final fileData = base64Encode(encryptedFile);

      final messages = await getMessages(chatId);
      final isFirstMessage = messages.length <= 1;

      final payloadMap = {
        'type': 'file',
        'content': '',
        'fileName': fileName,
        'fileData': fileData,
        'fileSize': file.lengthSync(),
        'id': message.id,
        'chatId': message.chatId,
        'senderId': message.senderId,
        'timestamp': message.timestamp.toIso8601String(),
      };

      String payload;
      if (isFirstMessage && chat.shareCode != null) {
        payloadMap['shareCode'] = chat.shareCode!;
        payload = jsonEncode(payloadMap);
      } else {
        payload = EncryptionService.encryptWithShareCode(jsonEncode(payloadMap), chat.shareCode!);
      }

      _ws.sendMessage(
        to: chat.recipientId!,
        chatId: chatId,
        payload: payload,
      );
    }

    return message;
  }

  /// Расшифровать и получить файл (с кэшем, чтобы не расшифровывать повторно)
  Future<File> getDecryptedFile(String encryptedPath) async {
    final cacheDir = await getApplicationCacheDirectory();
    final cacheSubdir = Directory('${cacheDir.path}/black_square_decrypted');
    if (!await cacheSubdir.exists()) await cacheSubdir.create(recursive: true);
    final cacheKey = encryptedPath.split(RegExp(r'[/\\]')).last;
    final cachedFile = File('${cacheSubdir.path}/$cacheKey');
    if (await cachedFile.exists()) return cachedFile;

    final encrypted = await File(encryptedPath).readAsBytes();
    final decrypted = _encryption.decryptBytes(encrypted);
    await cachedFile.writeAsBytes(decrypted);
    return cachedFile;
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
