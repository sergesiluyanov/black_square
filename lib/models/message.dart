/// Модель сообщения в мессенджере
class Message {
  final String id;
  final String chatId;
  final String senderId;
  final String content;
  final DateTime timestamp;
  final MessageType type;
  final bool isFromMe;
  final String? fileName;
  final String? filePath;
  final int? fileSize;

  const Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.content,
    required this.timestamp,
    this.type = MessageType.text,
    this.isFromMe = true,
    this.fileName,
    this.filePath,
    this.fileSize,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      chatId: json['chatId'] as String,
      senderId: json['senderId'] as String,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      type: MessageType.values.byName(json['type'] as String? ?? 'text'),
      isFromMe: json['isFromMe'] as bool? ?? true,
      fileName: json['fileName'] as String?,
      filePath: json['filePath'] as String?,
      fileSize: json['fileSize'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chatId': chatId,
      'senderId': senderId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'type': type.name,
      'isFromMe': isFromMe,
      'fileName': fileName,
      'filePath': filePath,
      'fileSize': fileSize,
    };
  }

  Message copyWith({
    String? id,
    String? chatId,
    String? senderId,
    String? content,
    DateTime? timestamp,
    MessageType? type,
    bool? isFromMe,
    String? fileName,
    String? filePath,
    int? fileSize,
  }) {
    return Message(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      type: type ?? this.type,
      isFromMe: isFromMe ?? this.isFromMe,
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
    );
  }
}

enum MessageType {
  text,
  file,
}
