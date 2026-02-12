/// Модель чата
class Chat {
  final String id;
  final String name;
  final String? recipientId;
  final String? shareCode;
  final String? avatarPath;
  final DateTime lastMessageAt;
  final String? lastMessagePreview;

  const Chat({
    required this.id,
    required this.name,
    this.recipientId,
    this.shareCode,
    this.avatarPath,
    required this.lastMessageAt,
    this.lastMessagePreview,
  });

  factory Chat.fromJson(Map<String, dynamic> json) {
    return Chat(
      id: json['id'] as String,
      name: json['name'] as String,
      recipientId: json['recipientId'] as String?,
      shareCode: json['shareCode'] as String?,
      avatarPath: json['avatarPath'] as String?,
      lastMessageAt: DateTime.parse(json['lastMessageAt'] as String),
      lastMessagePreview: json['lastMessagePreview'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'recipientId': recipientId,
      'shareCode': shareCode,
      'avatarPath': avatarPath,
      'lastMessageAt': lastMessageAt.toIso8601String(),
      'lastMessagePreview': lastMessagePreview,
    };
  }

  Chat copyWith({
    String? id,
    String? name,
    String? recipientId,
    String? shareCode,
    String? avatarPath,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
  }) {
    return Chat(
      id: id ?? this.id,
      name: name ?? this.name,
      recipientId: recipientId ?? this.recipientId,
      shareCode: shareCode ?? this.shareCode,
      avatarPath: avatarPath ?? this.avatarPath,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
    );
  }
}
