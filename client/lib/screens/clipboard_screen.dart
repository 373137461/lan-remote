import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/clipboard_item.dart';
import '../services/clipboard_service.dart';
import '../services/udp_service.dart';

const _maxNonStarred = 20;

/// 粘贴板监视页
class ClipboardScreen extends StatefulWidget {
  final UdpService udpService;
  const ClipboardScreen({super.key, required this.udpService});

  @override
  State<ClipboardScreen> createState() => _ClipboardScreenState();
}

class _ClipboardScreenState extends State<ClipboardScreen> {
  final _service = ClipboardService();
  List<ClipboardItem> _items = [];
  StreamSubscription? _clipSub;

  @override
  void initState() {
    super.initState();
    _load();
    _clipSub = widget.udpService.clipboardStream.listen(_onNewText);
  }

  @override
  void dispose() {
    _clipSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await _service.loadAll();
    if (mounted) setState(() => _items = list);
  }

  Future<void> _save() => _service.saveAll(_items);

  // ── 收到服务端推送 ──
  void _onNewText(String text) {
    if (text.trim().isEmpty) return;
    setState(() {
      // 若内容已存在，移到顶部并保留收藏状态
      final existing = _items.where((i) => i.content == text).toList();
      final wasStarred = existing.any((i) => i.starred);
      _items.removeWhere((i) => i.content == text);

      _items.insert(
        0,
        ClipboardItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          content: text,
          timestamp: DateTime.now(),
          starred: wasStarred,
        ),
      );

      // 非收藏超过 20 条时删除最旧的
      final nonStarred = _items.where((i) => !i.starred).toList();
      if (nonStarred.length > _maxNonStarred) {
        final remove =
            nonStarred.sublist(_maxNonStarred).map((i) => i.id).toSet();
        _items.removeWhere((i) => remove.contains(i.id));
      }
    });
    _save();
  }

  // ── 排序后的展示列表 ──
  List<ClipboardItem> get _sorted {
    final starred = _items.where((i) => i.starred).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final unstarred = _items.where((i) => !i.starred).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return [...starred, ...unstarred];
  }

  void _toggleStar(ClipboardItem item) {
    setState(() => item.starred = !item.starred);
    _save();
  }

  void _delete(ClipboardItem item) {
    setState(() => _items.removeWhere((i) => i.id == item.id));
    _save();
  }

  void _send(ClipboardItem item) {
    widget.udpService.sendTextInput(item.content);
    _snack('已发送');
  }

  void _clearNonStarred() {
    setState(() => _items.removeWhere((i) => !i.starred));
    _save();
    _snack('已清空非收藏内容');
  }

  // ── 导出：JSON → base64 → 剪贴板 ──
  Future<void> _export() async {
    if (_items.isEmpty) { _snack('暂无内容可导出'); return; }
    final json = jsonEncode(_items.map((i) => i.toJson()).toList());
    final b64 = base64.encode(utf8.encode(json));
    await Clipboard.setData(ClipboardData(text: b64));
    _snack('已导出 ${_items.length} 条并复制到剪贴板');
  }

  // ── 导入：剪贴板 → base64 → JSON ──
  Future<void> _import() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) { _snack('剪贴板为空'); return; }

    List<ClipboardItem> imported;
    try {
      final decoded = utf8.decode(base64.decode(text));
      final list = jsonDecode(decoded) as List;
      imported = list
          .map((e) => ClipboardItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _snack('格式错误，无法解析'); return;
    }
    if (imported.isEmpty) { _snack('导入内容为空'); return; }
    if (!mounted) return;

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导入 ${imported.length} 条记录'),
        content: const Text('选择导入方式'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text('取消',
                style: TextStyle(
                    color: Theme.of(ctx)
                        .colorScheme
                        .onSurface
                        .withAlpha(138))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'append'),
            child: const Text('追加'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'overwrite'),
            child: const Text('覆盖',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return;

    setState(() {
      if (choice == 'overwrite') {
        _items = imported;
      } else {
        final existingIds = _items.map((i) => i.id).toSet();
        for (final m in imported) {
          _items.add(existingIds.contains(m.id)
              ? ClipboardItem(
                  id: '${DateTime.now().millisecondsSinceEpoch}_${m.id}',
                  content: m.content,
                  timestamp: m.timestamp,
                  starred: m.starred)
              : m);
        }
      }
    });
    await _save();
    _snack(choice == 'overwrite'
        ? '已覆盖为 ${imported.length} 条记录'
        : '已追加 ${imported.length} 条记录');
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
    final sorted = _sorted;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Column(
      children: [
        // 列表
        Expanded(
          child: sorted.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.content_paste_off_outlined,
                          size: 64, color: cs.onSurface.withAlpha(61)),
                      const SizedBox(height: 12),
                      Text('等待被控端复制内容…',
                          style: TextStyle(
                              color: cs.onSurface.withAlpha(100))),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: sorted.length,
                  itemBuilder: (_, i) => _ClipCard(
                    item: sorted[i],
                    onSend: () => _send(sorted[i]),
                    onCopy: () async {
                      await Clipboard.setData(
                          ClipboardData(text: sorted[i].content));
                      _snack('已复制到手机剪贴板');
                    },
                    onStar: () => _toggleStar(sorted[i]),
                    onDelete: () => _delete(sorted[i]),
                  ),
                ),
        ),
        // 底部操作栏
        Container(
          decoration: BoxDecoration(
            color: cs.surface,
            border: Border(
                top: BorderSide(color: cs.onSurface.withAlpha(20))),
          ),
          padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + bottomPad),
          child: Row(
            children: [
              _BottomBtn(
                icon: Icons.download_outlined,
                label: '导入',
                onTap: _import,
              ),
              const SizedBox(width: 8),
              _BottomBtn(
                icon: Icons.upload_outlined,
                label: '导出',
                onTap: _export,
              ),
              const Spacer(),
              _BottomBtn(
                icon: Icons.delete_sweep_outlined,
                label: '清空全部',
                color: Colors.redAccent,
                onTap: _items.any((i) => !i.starred)
                    ? () => showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('清空全部'),
                            content: const Text('清空所有非收藏记录？收藏内容保留。'),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(ctx, false),
                                child: Text('取消',
                                    style: TextStyle(
                                        color: cs.onSurface.withAlpha(138))),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(ctx, true),
                                child: const Text('清空',
                                    style: TextStyle(
                                        color: Colors.redAccent)),
                              ),
                            ],
                          ),
                        ).then((v) { if (v == true) _clearNonStarred(); })
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── 单条记录卡片 ──
class _ClipCard extends StatelessWidget {
  final ClipboardItem item;
  final VoidCallback onSend;
  final VoidCallback onCopy;
  final VoidCallback onStar;
  final VoidCallback onDelete;

  const _ClipCard({
    required this.item,
    required this.onSend,
    required this.onCopy,
    required this.onStar,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 收藏项底色更深
    final bg = item.starred
        ? Color.alphaBlend(
            const Color(0xFF2D6CDF).withAlpha(28), cs.surface)
        : cs.surface;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: item.starred
            ? BorderSide(
                color: const Color(0xFF2D6CDF).withAlpha(80))
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 文字区：点击直接发送
            Expanded(
              child: GestureDetector(
                onTap: onSend,
                behavior: HitTestBehavior.opaque,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.displayTitle,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.displayPreview.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.displayPreview,
                        style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withAlpha(120)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 发送
            IconButton(
              icon: const Icon(Icons.send_outlined, size: 18),
              color: const Color(0xFF2D6CDF),
              tooltip: '发送到被控端',
              onPressed: onSend,
              visualDensity: VisualDensity.compact,
            ),
            // 复制到手机剪贴板
            IconButton(
              icon: Icon(Icons.copy_outlined, size: 18,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(138)),
              tooltip: '复制到手机剪贴板',
              onPressed: onCopy,
              visualDensity: VisualDensity.compact,
            ),
            // 收藏
            IconButton(
              icon: Icon(
                item.starred ? Icons.star_rounded : Icons.star_outline_rounded,
                size: 18,
                color: item.starred
                    ? Colors.amber
                    : cs.onSurface.withAlpha(138),
              ),
              tooltip: item.starred ? '取消收藏' : '收藏',
              onPressed: onStar,
              visualDensity: VisualDensity.compact,
            ),
            // 删除
            IconButton(
              icon: const Icon(Icons.close, size: 18,
                  color: Colors.redAccent),
              tooltip: '删除',
              onPressed: onDelete,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

// ── 底部操作按钮 ──
class _BottomBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  const _BottomBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? const Color(0xFF2D6CDF);
    final active = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? c.withAlpha(22) : cs.onSurface.withAlpha(12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: active ? c.withAlpha(80) : cs.onSurface.withAlpha(30)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 15,
                color: active ? c : cs.onSurface.withAlpha(61)),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: active ? c : cs.onSurface.withAlpha(61))),
          ],
        ),
      ),
    );
  }
}
