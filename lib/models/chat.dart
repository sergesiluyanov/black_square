/// Модель чата
class Chat {
  final String id;
  final String name;
  final String? avatarPath;
  final DateTime lastMessageAt;
  final String? lastMessagePreview;

  const Chat({
    required this.id,
    required this.name,
    this.avatarPath,
    required this.lastMessageAt,
    this.lastMessagePreview,
  });

  factory Chat.fromJson(Map<String, dynamic> json) {
    return Chat(
      id: json['id'] as String,
      name: json['name'] as String,
      avatarPath: json['avatarPath'] as String?,
      lastMessageAt: DateTime.parse(json['lastMessageAt'] as String),
      lastMessagePreview: json['lastMessagePreview'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'avatarPath': avatarPath,
      'lastMessageAt': lastMessageAt.toIso8601String(),
      'lastMessagePreview': lastMessagePreview,
    };
  }

  Chat copyWith({
    String? id,
    String? name,
    String? avatarPath,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
  }) {
    return Chat(
      id: id ?? this.id,
      name: name ?? this.name,
      avatarPath: avatarPath ?? this.avatarPath,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
    );
  }
}
