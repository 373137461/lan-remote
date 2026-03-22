import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/macro.dart';

class MacroService {
  static const _key = 'macros_v1';

  Future<List<Macro>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Macro.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAll(List<Macro> macros) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(macros.map((m) => m.toJson()).toList()));
  }
}
