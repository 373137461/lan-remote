import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/clipboard_item.dart';

class ClipboardService {
  static const _key = 'clipboard_items_v1';

  Future<List<ClipboardItem>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => ClipboardItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAll(List<ClipboardItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(items.map((i) => i.toJson()).toList()));
  }
}
