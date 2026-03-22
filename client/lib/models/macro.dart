class Macro {
  final String id;
  String name;
  String content;

  Macro({required this.id, required this.name, required this.content});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'content': content};

  factory Macro.fromJson(Map<String, dynamic> json) => Macro(
        id: json['id'] as String,
        name: json['name'] as String,
        content: json['content'] as String,
      );
}
