class VoltixProfile {
  final int id;
  final int voltixUserId;
  final String name;
  final String? avatarColor;
  final String? avatarEmoji;
  final bool isOwner;
  final bool isKids;

  const VoltixProfile({
    required this.id,
    required this.voltixUserId,
    required this.name,
    this.avatarColor,
    this.avatarEmoji,
    required this.isOwner,
    this.isKids = false,
  });

  factory VoltixProfile.fromJson(Map<String, dynamic> json) {
    return VoltixProfile(
      id: json['id'] as int,
      voltixUserId: json['voltixUserId'] as int,
      name: json['name'] as String,
      avatarColor: json['avatarColor'] as String?,
      avatarEmoji: json['avatarEmoji'] as String?,
      isOwner: json['isOwner'] as bool? ?? false,
      isKids: json['isKids'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'voltixUserId': voltixUserId,
      'name': name,
      'avatarColor': avatarColor,
      'avatarEmoji': avatarEmoji,
      'isOwner': isOwner,
      'isKids': isKids,
    };
  }

  VoltixProfile copyWith({
    int? id,
    int? voltixUserId,
    String? name,
    String? avatarColor,
    String? avatarEmoji,
    bool? isOwner,
    bool? isKids,
  }) {
    return VoltixProfile(
      id: id ?? this.id,
      voltixUserId: voltixUserId ?? this.voltixUserId,
      name: name ?? this.name,
      avatarColor: avatarColor ?? this.avatarColor,
      avatarEmoji: avatarEmoji ?? this.avatarEmoji,
      isOwner: isOwner ?? this.isOwner,
      isKids: isKids ?? this.isKids,
    );
  }
}
