class ClipboardItem {
  final String id;
  final String content;
  DateTime timestamp;
  bool starred;

  ClipboardItem({
    required this.id,
    required this.content,
    required this.timestamp,
    this.starred = false,
  });

  /// 标题：前 15 个字符（换行替换为空格）
  String get displayTitle {
    final clean = content.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return clean.length > 15 ? clean.substring(0, 15) : clean;
  }

  /// 预览：第 15~55 字符（换行替换为空格）
  String get displayPreview {
    final clean = content.replaceAll(RegExp(r'[\r\n]+'), ' ');
    if (clean.length <= 15) return '';
    final end = clean.length < 55 ? clean.length : 55;
    return clean.substring(15, end);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'starred': starred,
      };

  factory ClipboardItem.fromJson(Map<String, dynamic> json) => ClipboardItem(
        id: json['id'] as String,
        content: json['content'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        starred: json['starred'] as bool? ?? false,
      );
}
