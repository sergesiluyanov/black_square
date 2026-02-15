import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:black_square/config.dart';
import 'package:black_square/models/chat.dart';
import 'package:black_square/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:black_square/models/message.dart';
import 'package:black_square/services/encryption_service.dart';
import 'package:black_square/services/storage_service.dart';
import 'package:black_square/services/websocket_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Макс. размер файла ~100 MB
const _maxFileSizeBytes = 100 * 1024 * 1024;
const _maxSizeForThumbnail = 30 * 1024 * 1024; // 30 MB — большие видео без миниатюры

/// Очередь генерации миниатюр — по одной, чтобы не нагружать MediaCodec
Future<void> _thumbQueueNext = Future.value();

Future<void> _generateThumbnailQueued(Future<void> Function() fn) async {
  final prev = _thumbQueueNext;
  final completer = Completer<void>();
  _thumbQueueNext = completer.future;
  await prev;
  try {
    await fn();
  } finally {
    completer.complete();
  }
}

bool _isVideoFile(String? fileName) {
  if (fileName == null) return false;
  final ext = fileName.toLowerCase().split('.').last;
  return ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
}

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

/// Чтение + дешифрование для локального хранилища (getDecryptedFile)
Uint8List _decryptStorageFileInIsolate(List<Object> args) {
  final encryptedPath = args[0] as String;
  final keyBytes = args[1] as Uint8List;
  final encrypted = File(encryptedPath).readAsBytesSync();
  return EncryptionService.decryptBytesWithKey([keyBytes, encrypted]);
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
  String? _currentChatId;

  String get userId => _userId ?? '';

  void setCurrentChatId(String? chatId) {
    _currentChatId = chatId;
  }

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
    final fcmToken = NotificationService().fcmToken;
    try {
      await _ws.connect(Config.serverUrl, _userId!, fcmToken: fcmToken);
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
        unreadCount: 1,
      );
      await _saveChat(chat);
      _emitChatsUpdated();
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
      final unread = chatId != _currentChatId ? chat.unreadCount + 1 : 0;
      await _saveChat(chat.copyWith(
        lastMessageAt: placeholderMessage.timestamp,
        lastMessagePreview: preview,
        unreadCount: unread,
      ));
      _emitChatsUpdated();
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

    final unread = chatId != _currentChatId ? chat.unreadCount + 1 : 0;
    await _saveChat(chat.copyWith(
      lastMessageAt: message.timestamp,
      lastMessagePreview: preview,
      unreadCount: unread,
    ));
    _emitChatsUpdated();
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
      await Future.delayed(Duration.zero); // даём UI ответить, чтобы избежать ANR

      final appDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory('${appDir.path}/black_square_files');
      if (!await filesDir.exists()) await filesDir.create(recursive: true);
      final cacheKey = _uuid.v4();
      final filePath = '${filesDir.path}/$cacheKey';
      final keyBytes = _encryption.keyBytesForIsolate;
      final encrypted = keyBytes != null
          ? await compute(EncryptionService.encryptBytesWithKey, [keyBytes, decrypted])
          : _encryption.encryptBytes(decrypted);
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

      // Миниатюра — в фоне, с задержкой, в очереди (не блокируем UI)
      if (_isVideoFile(fileName) && estimatedSize < _maxSizeForThumbnail) {
        final decryptedPath = '${(await getTemporaryDirectory()).path}/$cacheKey';
        await File(decryptedPath).writeAsBytes(decrypted);
        Future.delayed(const Duration(milliseconds: 800), () {
          _generateThumbnailQueued(() async {
            try {
              final cacheDir = await getApplicationCacheDirectory();
              final thumbDir = Directory('${cacheDir.path}/black_square_thumbs');
              if (!await thumbDir.exists()) await thumbDir.create(recursive: true);
              if (await File(decryptedPath).exists()) {
                await VideoThumbnail.thumbnailFile(
                  video: decryptedPath,
                  thumbnailPath: '${thumbDir.path}/$cacheKey.jpg',
                  imageFormat: ImageFormat.JPEG,
                  maxWidth: 200,
                  quality: 50,
                );
                await File(decryptedPath).delete();
                _messageUpdatedController.add(updatedMessage);
              }
            } catch (_) {}
          });
        });
      }
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

  void _emitChatsUpdated() {
    _chatsUpdatedController.add(null);
  }

  /// Принудительно обновить список чатов (для навигации по push)
  void notifyChatsUpdated() {
    _emitChatsUpdated();
  }

  Future<void> markChatAsRead(String chatId) async {
    final chats = await getChats();
    final chat = chats.where((c) => c.id == chatId).firstOrNull;
    if (chat != null && chat.unreadCount > 0) {
      await _saveChat(chat.copyWith(unreadCount: 0));
      _emitChatsUpdated();
    }
  }

  /// Удалить чат и все его сообщения (включая файлы)
  Future<void> deleteChat(String chatId) async {
    final messages = await getMessages(chatId);
    for (final msg in messages) {
      if (msg.type == MessageType.file && msg.filePath != null) {
        try {
          final f = File(msg.filePath!);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    final cacheDir = await getApplicationCacheDirectory();
    final thumbDir = Directory('${cacheDir.path}/black_square_thumbs');
    final decryptedDir = Directory('${cacheDir.path}/black_square_decrypted');
    for (final msg in messages) {
      if (msg.filePath != null) {
        final key = msg.filePath!.split(RegExp(r'[/\\]')).last;
        try {
          final thumb = File('${thumbDir.path}/$key.jpg');
          if (await thumb.exists()) await thumb.delete();
        } catch (_) {}
        try {
          final dec = File('${decryptedDir.path}/$key');
          if (await dec.exists()) await dec.delete();
        } catch (_) {}
      }
    }

    final chats = await getChats();
    final updated = chats.where((c) => c.id != chatId).toList();
    await _storage.setString(
      _chatsKey,
      _encryption.encryptText(jsonEncode(updated.map((c) => c.toJson()).toList())),
    );

    final encrypted = await _storage.getString(_messagesKey);
    if (encrypted != null) {
      try {
        final allMessages = jsonDecode(_encryption.decryptText(encrypted)) as Map<String, dynamic>;
        allMessages.remove(chatId);
        await _storage.setString(
          _messagesKey,
          _encryption.encryptText(jsonEncode(allMessages)),
        );
      } catch (_) {}
    }

    if (_currentChatId == chatId) {
      _currentChatId = null;
    }
    _emitChatsUpdated();
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

    if (_isVideoFile(fileName) && file.lengthSync() < _maxSizeForThumbnail) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _generateThumbnailQueued(() async {
          try {
            final cacheDir = await getApplicationCacheDirectory();
            final thumbDir = Directory('${cacheDir.path}/black_square_thumbs');
            if (!await thumbDir.exists()) await thumbDir.create(recursive: true);
            final cacheKey = encryptedPath.split(RegExp(r'[/\\]')).last;
            await VideoThumbnail.thumbnailFile(
              video: file.path,
              thumbnailPath: '${thumbDir.path}/$cacheKey.jpg',
              imageFormat: ImageFormat.JPEG,
              maxWidth: 200,
              quality: 50,
            );
          } catch (_) {}
        });
      });
    }

    return message;
  }

  /// Путь к миниатюре видео (если есть) — мгновенная загрузка без расшифровки
  Future<File?> getVideoThumbnail(String encryptedPath) async {
    final cacheKey = encryptedPath.split(RegExp(r'[/\\]')).last;
    final cacheDir = await getApplicationCacheDirectory();
    final thumbFile = File('${cacheDir.path}/black_square_thumbs/$cacheKey.jpg');
    if (await thumbFile.exists()) return thumbFile;
    return null;
  }

  /// Расшифровать и получить файл (с кэшем, чтобы не расшифровывать повторно)
  Future<File> getDecryptedFile(String encryptedPath) async {
    final cacheDir = await getApplicationCacheDirectory();
    final cacheSubdir = Directory('${cacheDir.path}/black_square_decrypted');
    if (!await cacheSubdir.exists()) await cacheSubdir.create(recursive: true);
    final cacheKey = encryptedPath.split(RegExp(r'[/\\]')).last;
    final cachedFile = File('${cacheSubdir.path}/$cacheKey');
    if (await cachedFile.exists()) return cachedFile;

    final keyBytes = _encryption.keyBytesForIsolate;
    final decrypted = keyBytes != null
        ? await compute(_decryptStorageFileInIsolate, [encryptedPath, keyBytes])
        : _encryption.decryptBytes(await File(encryptedPath).readAsBytes());
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
