import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/macro.dart';
import '../services/macro_service.dart';
import '../services/udp_service.dart';
import 'macro_editor_screen.dart';

/// 宏列表页
class MacroScreen extends StatefulWidget {
  final UdpService udpService;
  const MacroScreen({super.key, required this.udpService});

  @override
  State<MacroScreen> createState() => _MacroScreenState();
}

class _MacroScreenState extends State<MacroScreen> {
  final _service = MacroService();
  List<Macro> _macros = [];
  bool _running = false;
  String? _runningId;
  bool _stopFlag = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _service.loadAll();
    if (mounted) setState(() => _macros = list);
  }

  Future<void> _save() => _service.saveAll(_macros);

  Future<void> _openEditor({Macro? macro}) async {
    final result = await Navigator.push<Macro>(
      context,
      MaterialPageRoute(builder: (_) => MacroEditorScreen(macro: macro)),
    );
    if (result == null) return;
    setState(() {
      final idx = _macros.indexWhere((m) => m.id == result.id);
      if (idx >= 0) {
        _macros[idx] = result;
      } else {
        _macros.add(result);
      }
    });
    await _save();
  }

  Future<void> _delete(Macro macro) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除宏'),
        content: Text('确定删除「${macro.name}」？'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurface.withAlpha(138))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _macros.removeWhere((m) => m.id == macro.id));
    await _save();
  }

  Future<void> _execute(Macro macro) async {
    if (_running) return;
    setState(() {
      _running = true;
      _runningId = macro.id;
      _stopFlag = false;
    });

    final lines = macro.content.split('\n');
    for (final rawLine in lines) {
      if (_stopFlag) break;
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.startsWith('sleep+')) {
        final sec = double.tryParse(line.substring(6).trim()) ?? 1.0;
        final endMs =
            DateTime.now().millisecondsSinceEpoch + (sec * 1000).round();
        while (DateTime.now().millisecondsSinceEpoch < endMs) {
          if (_stopFlag) break;
          await Future.delayed(const Duration(milliseconds: 50));
        }
      } else if (line.length >= 2 &&
          line.substring(0, 2).toLowerCase() == 'w+') {
        widget.udpService.sendTextInputDirect(line.substring(2));
      } else {
        widget.udpService.sendKeyCombo(line);
      }
    }

    if (mounted) setState(() { _running = false; _runningId = null; });
  }

  // ── 导出：JSON → base64 → 剪贴板 ──
  Future<void> _export() async {
    if (_macros.isEmpty) {
      _snack('暂无宏可导出');
      return;
    }
    final json = jsonEncode(_macros.map((m) => m.toJson()).toList());
    final b64 = base64.encode(utf8.encode(json));
    await Clipboard.setData(ClipboardData(text: b64));
    _snack('已导出 ${_macros.length} 条宏并复制到剪贴板');
  }

  // ── 导入：剪贴板 → base64 → JSON ──
  Future<void> _import() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _snack('剪贴板为空');
      return;
    }

    List<Macro> imported;
    try {
      final decoded = utf8.decode(base64.decode(text));
      final list = jsonDecode(decoded) as List;
      imported =
          list.map((e) => Macro.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      _snack('格式错误，无法解析');
      return;
    }
    if (imported.isEmpty) {
      _snack('导入内容为空');
      return;
    }

    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导入 ${imported.length} 条宏'),
        content: const Text('选择导入方式'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text('取消',
                style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurface.withAlpha(138))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'append'),
            child: const Text('追加'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'overwrite'),
            child: const Text('覆盖', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return;

    setState(() {
      if (choice == 'overwrite') {
        _macros = imported;
      } else {
        // 追加时若 id 冲突则生成新 id
        final existing = _macros.map((m) => m.id).toSet();
        for (final m in imported) {
          _macros.add(existing.contains(m.id)
              ? Macro(
                  id: '${DateTime.now().millisecondsSinceEpoch}_${m.id}',
                  name: m.name,
                  content: m.content)
              : m);
        }
      }
    });
    await _save();
    _snack(choice == 'overwrite'
        ? '已覆盖为 ${imported.length} 条宏'
        : '已追加 ${imported.length} 条宏');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    // FAB 区域高度：小按钮 40px + 间距 8px + 大按钮 56px 取最大 = 56px，加 bottom padding
    final fabBottom = (_running ? 104.0 : 16.0) + bottomPad;

    return Stack(
      children: [
        _macros.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_outline,
                        size: 64, color: cs.onSurface.withAlpha(61)),
                    const SizedBox(height: 12),
                    Text('暂无宏，点击 + 新建',
                        style: TextStyle(color: cs.onSurface.withAlpha(100))),
                  ],
                ),
              )
            : ListView.builder(
                padding: EdgeInsets.fromLTRB(12, 12, 12, 80 + bottomPad),
                itemCount: _macros.length,
                itemBuilder: (_, i) => _MacroCard(
                  macro: _macros[i],
                  running: _running && _runningId == _macros[i].id,
                  onEdit: () => _openEditor(macro: _macros[i]),
                  onDelete: () => _delete(_macros[i]),
                  onRun: _running ? null : () => _execute(_macros[i]),
                ),
              ),

        // 执行中底部状态栏
        if (_running)
          Positioned(
            bottom: bottomPad + 56,
            left: 0,
            right: 0,
            child: Container(
              color: cs.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '正在执行: ${_macros.firstWhere((m) => m.id == _runningId, orElse: () => _macros.first).name}',
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _stopFlag = true),
                    child: const Text('停止',
                        style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              ),
            ),
          ),

        // 底部右侧按钮组：导入 | 导出 | 新建
        Positioned(
          bottom: fabBottom,
          right: 16,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 导入
              FloatingActionButton.small(
                heroTag: 'macro_import',
                onPressed: _import,
                tooltip: '从剪贴板导入',
                backgroundColor: cs.surface,
                foregroundColor: cs.onSurface.withAlpha(200),
                elevation: 2,
                child: const Icon(Icons.download_outlined, size: 20),
              ),
              const SizedBox(width: 8),
              // 导出
              FloatingActionButton.small(
                heroTag: 'macro_export',
                onPressed: _export,
                tooltip: '导出到剪贴板',
                backgroundColor: cs.surface,
                foregroundColor: cs.onSurface.withAlpha(200),
                elevation: 2,
                child: const Icon(Icons.upload_outlined, size: 20),
              ),
              const SizedBox(width: 8),
              // 新建
              FloatingActionButton(
                heroTag: 'macro_fab',
                onPressed: () => _openEditor(),
                tooltip: '新建宏',
                child: const Icon(Icons.add),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MacroCard extends StatelessWidget {
  final Macro macro;
  final bool running;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onRun;

  const _MacroCard({
    required this.macro,
    required this.running,
    required this.onEdit,
    required this.onDelete,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  if (running) ...[
                    const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      macro.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.play_arrow_rounded,
                  color: onRun != null
                      ? const Color(0xFF2D6CDF)
                      : cs.onSurface.withAlpha(61)),
              tooltip: '执行',
              onPressed: onRun,
            ),
            IconButton(
              icon: Icon(Icons.edit_outlined,
                  color: cs.onSurface.withAlpha(138)),
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
