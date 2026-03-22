import 'package:flutter/material.dart';
import '../models/macro.dart';

/// 宏编辑器页
class MacroEditorScreen extends StatefulWidget {
  final Macro? macro;
  const MacroEditorScreen({super.key, this.macro});

  @override
  State<MacroEditorScreen> createState() => _MacroEditorScreenState();
}

class _MacroEditorScreenState extends State<MacroEditorScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _contentCtrl;
  final FocusNode _contentFocus = FocusNode();

  static const _quickChips = [
    // 特殊前缀
    ('w+', '逐字输入'),
    ('sleep+1', '延迟1秒'),
    // 通用快捷键（command 在 Windows 上自动替换为 ctrl）
    ('command+a', '全选'),
    ('command+c', '复制'),
    ('command+v', '粘贴'),
    ('command+x', '剪切'),
    ('command+z', '撤销'),
    ('command+shift+z', '重做'),
    ('command+s', '保存'),
    ('command+w', '关闭窗口'),
    ('command+q', '退出'),
    ('command+tab', '切换应用'),
    ('command+space', '聚焦/启动器'),
    ('command+shift+4', '截图'),
    ('alt+tab', 'Win切换应用'),
    ('ctrl+alt+t', '终端'),
    // 单键
    ('escape', 'Esc'),
    ('enter', '回车'),
    ('tab', 'Tab'),
    ('backspace', '退格'),
    ('delete', 'Delete'),
    ('home', 'Home'),
    ('end', 'End'),
    ('pageup', 'PgUp'),
    ('pagedown', 'PgDn'),
    // 方向键
    ('up', '↑'),
    ('down', '↓'),
    ('left', '←'),
    ('right', '→'),
    // Fn 键
    ('f1', 'F1'), ('f2', 'F2'), ('f3', 'F3'), ('f4', 'F4'),
    ('f5', 'F5'), ('f6', 'F6'), ('f7', 'F7'), ('f8', 'F8'),
    ('f9', 'F9'), ('f10', 'F10'), ('f11', 'F11'), ('f12', 'F12'),
  ];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.macro?.name ?? '');
    _contentCtrl = TextEditingController(text: widget.macro?.content ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _contentCtrl.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim().isEmpty
        ? '宏_${DateTime.now().millisecondsSinceEpoch}'
        : _nameCtrl.text.trim();
    final macro = Macro(
      id: widget.macro?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      content: _contentCtrl.text,
    );
    Navigator.pop(context, macro);
  }

  /// 在光标处插入一行指令（自动处理换行）
  void _insertLine(String text) {
    final ctrl = _contentCtrl;
    final cur = ctrl.selection.isValid
        ? ctrl.selection.baseOffset
        : ctrl.text.length;
    final current = ctrl.text;

    // 确保插入前当前行已结束
    String prefix = '';
    if (cur > 0 && current[cur - 1] != '\n') prefix = '\n';
    final insert = '$prefix$text\n';

    final newText = current.substring(0, cur) + insert + current.substring(cur);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cur + insert.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('宏编辑器'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _save,
              child: const Text('保存',
                  style: TextStyle(
                      color: Color(0xFF2D6CDF),
                      fontWeight: FontWeight.w600,
                      fontSize: 16)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 宏名称
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _nameCtrl,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                hintText: '宏名称（留空则按时间戳命名）',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 提示文字
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 12, color: cs.onSurface.withAlpha(80)),
                const SizedBox(width: 4),
                Text(
                  '每行一条：command+shift+a │ sleep+1 │ w+输入文字',
                  style: TextStyle(fontSize: 11, color: cs.onSurface.withAlpha(80)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 内容编辑器
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: TextField(
                controller: _contentCtrl,
                focusNode: _contentFocus,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'Courier', fontSize: 14, height: 1.6),
                decoration: InputDecoration(
                  hintText: 'command+shift+a\nsleep+1\nw+hello world',
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
          // 快捷输入区
          Container(
            height: 44,
            margin: const EdgeInsets.only(top: 8),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _quickChips.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final (cmd, label) = _quickChips[i];
                final isSpecial = cmd == 'w+' || cmd.startsWith('sleep+');
                final color = isSpecial
                    ? Colors.orange
                    : const Color(0xFF2D6CDF);
                return GestureDetector(
                  onTap: () {
                    _insertLine(cmd == 'w+' ? 'w+' : cmd);
                    // w+ 后定位光标到行尾（让用户直接输入文字）
                    if (cmd == 'w+') {
                      final pos = _contentCtrl.text.length;
                      _contentCtrl.selection =
                          TextSelection.collapsed(offset: pos - 1);
                    }
                    _contentFocus.requestFocus();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: color.withAlpha(30),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withAlpha(100)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(cmd,
                            style: TextStyle(
                                fontSize: 11,
                                color: color,
                                fontFamily: 'Courier',
                                fontWeight: FontWeight.w600)),
                        if (label.isNotEmpty && label != cmd)
                          Text(label,
                              style: TextStyle(
                                  fontSize: 9,
                                  color: color.withAlpha(160))),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(height: 12 + MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
