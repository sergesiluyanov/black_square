/// Модель чата
class Chat {
  final String id;
  final String name;
  final String? recipientId;
  final String? shareCode;
  final String? avatarPath;
  final String? myDisplayName; // Имя, которое показывается при исходящем звонке
  final DateTime lastMessageAt;
  final String? lastMessagePreview;
  final int unreadCount;

  const Chat({
    required this.id,
    required this.name,
    this.recipientId,
    this.shareCode,
    this.avatarPath,
    this.myDisplayName,
    required this.lastMessageAt,
    this.lastMessagePreview,
    this.unreadCount = 0,
  });

  factory Chat.fromJson(Map<String, dynamic> json) {
    return Chat(
      id: json['id'] as String,
      name: json['name'] as String,
      recipientId: json['recipientId'] as String?,
      shareCode: json['shareCode'] as String?,
      avatarPath: json['avatarPath'] as String?,
      myDisplayName: json['myDisplayName'] as String?,
      lastMessageAt: DateTime.parse(json['lastMessageAt'] as String),
      lastMessagePreview: json['lastMessagePreview'] as String?,
      unreadCount: json['unreadCount'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'recipientId': recipientId,
      'shareCode': shareCode,
      'avatarPath': avatarPath,
      'myDisplayName': myDisplayName,
      'lastMessageAt': lastMessageAt.toIso8601String(),
      'lastMessagePreview': lastMessagePreview,
      'unreadCount': unreadCount,
    };
  }

  Chat copyWith({
    String? id,
    String? name,
    String? recipientId,
    String? shareCode,
    String? avatarPath,
    String? myDisplayName,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
    int? unreadCount,
  }) {
    return Chat(
      id: id ?? this.id,
      name: name ?? this.name,
      recipientId: recipientId ?? this.recipientId,
      shareCode: shareCode ?? this.shareCode,
      avatarPath: avatarPath ?? this.avatarPath,
      myDisplayName: myDisplayName ?? this.myDisplayName,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}
