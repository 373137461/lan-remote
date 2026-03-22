import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/udp_service.dart';
import '../utils/keycodes.dart';

/// 键盘与文本输入界面
/// - 快捷键面板：常用功能键、方向键、媒体键、系统操作
/// - 音量滑动条：拖动控制被控端音量（每格 = 1次音量键）
/// - 文本输入框：整段发送，支持剪贴板粘贴或逐字输入两种模式
class KeyboardScreen extends StatefulWidget {
  final UdpService udpService;
  const KeyboardScreen({super.key, required this.udpService});

  @override
  State<KeyboardScreen> createState() => _KeyboardScreenState();
}

class _KeyboardScreenState extends State<KeyboardScreen>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  late final TabController _tabController;

  // 文本输入模式：false=剪贴板粘贴（默认），true=逐字输入
  bool _useTypeStr = false;
  static const _keyTypeStr = 'kb_use_typestr';

  // 逐字模式：零宽空格哨兵，使退格键在空输入框时也能被检测
  static const _sentinel = '\u200B';
  bool _lockTextUpdate = false;

  // 自定义快捷键（从服务端拉取）
  List<Map<String, dynamic>> _customShortcuts = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _textController.addListener(_handleDirectInput);
    _loadInputMode();
    _loadCustomShortcuts();
  }

  Future<void> _loadInputMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final v = prefs.getBool(_keyTypeStr) ?? false;
    setState(() => _useTypeStr = v);
    if (v) _initDirectMode();
  }

  /// 进入逐字模式时，将输入框设为哨兵状态（零宽空格 + 光标在末尾）
  void _initDirectMode() {
    _lockTextUpdate = true;
    _textController.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: 1),
    );
    _lockTextUpdate = false;
  }

  /// 逐字模式下的输入监听：每次文本变化立即发送并重置
  void _handleDirectInput() {
    if (_lockTextUpdate || !_useTypeStr) return;
    final text = _textController.text;
    if (text == _sentinel) return; // 仅哨兵，无变化

    _lockTextUpdate = true;

    if (!text.contains(_sentinel)) {
      // 哨兵被删掉 → 退格键
      widget.udpService.sendKeyTap(KeyCodes.backspace);
    } else {
      // 哨兵后有新内容 → 逐字发送
      final added = text.replaceFirst(_sentinel, '');
      for (final rune in added.runes) {
        final ch = String.fromCharCode(rune);
        if (ch == '\n') {
          widget.udpService.sendKeyTap(KeyCodes.enter);
        } else {
          widget.udpService.sendTextInputDirect(ch);
        }
      }
    }

    // 重置回哨兵状态
    _textController.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: 1),
    );
    _lockTextUpdate = false;
  }

  Future<void> _loadCustomShortcuts() async {
    await widget.udpService.fetchShortcuts();
    if (!mounted) return;
    setState(() => _customShortcuts = widget.udpService.customShortcuts);
  }

  @override
  void dispose() {
    _textController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _sendText() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_useTypeStr) {
      widget.udpService.sendTextInputDirect(text);
    } else {
      widget.udpService.sendTextInput(text);
    }
    _textController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已发送: $text'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 系统操作（带确认弹窗）
  void _sysActionWithConfirm(int action, String label) {
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('确认执行', style: TextStyle(color: cs.onSurface)),
        content: Text('确定要执行「$label」吗？',
            style: TextStyle(color: cs.onSurface.withAlpha(178))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: cs.onSurface.withAlpha(138))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              widget.udpService.sendSysAction(action);
            },
            child: Text(label),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          color: cs.surface,
          child: TabBar(
            controller: _tabController,
            indicatorColor: const Color(0xFF2D6CDF),
            labelColor: cs.onSurface,
            unselectedLabelColor: cs.onSurface.withAlpha(97),
            tabs: const [
              Tab(icon: Icon(Icons.grid_view), text: '快捷键'),
              Tab(icon: Icon(Icons.text_fields), text: '文本发送'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildKeyPanel(context),
              _buildTextPanel(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildKeyPanel(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // F1-F12（带 OS 默认功能提示）
          _buildFKeyRow(),
          const SizedBox(height: 10),

          // 控制键
          _buildKeyRow([
            (icon: '⎋', label: 'Esc',   code: KeyCodes.escape),
            (icon: '⇥', label: 'Tab',   code: KeyCodes.tab),
            (icon: '⌫', label: '退格',  code: KeyCodes.backspace),
            (icon: '⌦', label: 'Del',   code: KeyCodes.delete),
            (icon: '↵', label: 'Enter', code: KeyCodes.enter),
          ]),
          const SizedBox(height: 10),

          // 导航键
          _buildKeyRow([
            (icon: '↖', label: 'Home',  code: KeyCodes.home),
            (icon: '↘', label: 'End',   code: KeyCodes.end),
            (icon: '⇑', label: 'PgUp',  code: KeyCodes.pageUp),
            (icon: '⇓', label: 'PgDn',  code: KeyCodes.pageDown),
          ]),
          const SizedBox(height: 10),

          // 方向键
          _buildKeyRow([
            (icon: '←', label: '左', code: KeyCodes.arrowLeft),
            (icon: '↑', label: '上', code: KeyCodes.arrowUp),
            (icon: '↓', label: '下', code: KeyCodes.arrowDown),
            (icon: '→', label: '右', code: KeyCodes.arrowRight),
          ]),
          const SizedBox(height: 10),

          // 媒体键
          _buildKeyRow([
            (icon: '⏮', label: '上一首',   code: KeyCodes.prevTrack),
            (icon: '⏯', label: '播放/暂停', code: KeyCodes.playPause),
            (icon: '⏭', label: '下一首',   code: KeyCodes.nextTrack),
          ]),
          const SizedBox(height: 12),

          _buildVolumeSlider(),
          const SizedBox(height: 12),
          _buildEditShortcuts(context),
          if (_customShortcuts.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildCustomShortcuts(context),
          ],
          const SizedBox(height: 12),
          _buildSystemShortcuts(context),
        ],
      ),
    );
  }

  Widget _buildKeyRow(
      List<({String icon, String label, int code})> keys) {
    return Row(
      children: keys
          .map((k) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _KeyTile(
                    label: k.icon,
                    sublabel: k.label,
                    onTap: () => widget.udpService.sendKeyTap(k.code),
                  ),
                ),
              ))
          .toList(),
    );
  }

  /// F1-F12 横向滚动行，根据服务端 OS 显示默认系统功能名称
  Widget _buildFKeyRow() {
    final os = widget.udpService.serverOs;

    // macOS 默认 F 键功能
    const macLabels = {
      1: '亮度-',  2: '亮度+',  3: '调度中心', 4: '启动台',
      5: '听写',   6: '勿扰',   7: '上一首',  8: '播放',
      9: '下一首', 10: '静音',  11: '音量-',  12: '音量+',
    };
    // Windows 有默认功能的 F 键
    const winLabels = {
      1: '帮助', 2: '重命名', 3: '搜索',  4: '地址栏',
      5: '刷新', 6: '切换',  10: '菜单', 11: '全屏',
    };

    String? subLabel(int n) {
      if (os == 1) return macLabels[n];
      if (os == 0) return winLabels[n];
      return null;
    }

    final keycodes = [
      KeyCodes.f1, KeyCodes.f2,  KeyCodes.f3,  KeyCodes.f4,
      KeyCodes.f5, KeyCodes.f6,  KeyCodes.f7,  KeyCodes.f8,
      KeyCodes.f9, KeyCodes.f10, KeyCodes.f11, KeyCodes.f12,
    ];

    return SizedBox(
      height: 58,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: 12,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final n = i + 1;
          return SizedBox(
            width: 52,
            child: _KeyTile(
              label: 'F$n',
              sublabel: subLabel(n),
              onTap: () => widget.udpService.sendKeyTap(keycodes[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEditShortcuts(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final os = widget.udpService.serverOs;
    final modLabel = os == 1 ? '⌘' : 'Ctrl';

    final items = [
      (label: '全选', sublabel: '$modLabel+A', action: 0x07, icon: Icons.select_all),
      (label: '复制', sublabel: '$modLabel+C', action: 0x08, icon: Icons.copy),
      (label: '剪切', sublabel: '$modLabel+X', action: 0x09, icon: Icons.cut),
      (label: '撤销', sublabel: '$modLabel+Z', action: 0x0A, icon: Icons.undo),
      (label: '重做', sublabel: os == 1 ? '⌘⇧Z' : 'Ctrl+Y', action: 0x0B, icon: Icons.redo),
      (label: '保存', sublabel: '$modLabel+S', action: 0x0C, icon: Icons.save_outlined),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.edit_outlined, color: Color(0xFF2D6CDF), size: 16),
              const SizedBox(width: 6),
              Text('编辑快捷键',
                  style: TextStyle(color: cs.onSurface.withAlpha(178), fontSize: 13)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: items.map((item) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _EditChip(
                  label: item.label,
                  sublabel: item.sublabel,
                  icon: item.icon,
                  onTap: () => widget.udpService.sendSysAction(item.action),
                ),
              ),
            )).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeSlider() {
    return _buildKeyRow([
      (icon: '🔉', label: '音量-', code: KeyCodes.volDown),
      (icon: '🔇', label: '静音',  code: KeyCodes.mute),
      (icon: '🔊', label: '音量+', code: KeyCodes.volUp),
    ]);
  }

  Widget _buildCustomShortcuts(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.stars_outlined, color: Color(0xFF2D6CDF), size: 16),
              const SizedBox(width: 6),
              Text('自定义快捷键',
                  style: TextStyle(color: cs.onSurface.withAlpha(178), fontSize: 13)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _customShortcuts.map((sc) {
              final idx = sc['idx'] as int;
              final name = sc['name'] as String;
              final desc = (sc['desc'] as String?) ?? '';
              return _CustomShortcutChip(
                name: name,
                desc: desc,
                onTap: () => widget.udpService.sendSysAction(0x20 + idx),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemShortcuts(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final os = widget.udpService.serverOs; // 0=Win, 1=macOS, 2=Linux, -1=未知

    // 通用操作（所有平台）
    final commonItems = <Widget>[
      _SysChip(
        label: '切换应用',
        icon: Icons.swap_horiz,
        onTap: () => widget.udpService.sendSysAction(0x05),
      ),
      _SysChip(
        label: '截图',
        icon: Icons.screenshot,
        onTap: () => widget.udpService.sendSysAction(0x06),
      ),
      _SysChip(
        label: '锁屏',
        icon: Icons.lock_outline,
        onTap: () => widget.udpService.sendSysAction(0x01),
      ),
      _SysChip(
        label: '睡眠',
        icon: Icons.bedtime_outlined,
        onTap: () => widget.udpService.sendSysAction(0x02),
      ),
    ];

    // 危险操作（需确认）
    final dangerItems = <Widget>[
      _SysChip(
        label: '关机',
        icon: Icons.power_settings_new,
        danger: true,
        onTap: () => _sysActionWithConfirm(0x03, '关机'),
      ),
      _SysChip(
        label: '重启',
        icon: Icons.restart_alt,
        danger: true,
        onTap: () => _sysActionWithConfirm(0x04, '重启'),
      ),
    ];

    // OS 标签
    String osHint;
    switch (os) {
      case 0: osHint = 'Windows'; break;
      case 1: osHint = 'macOS'; break;
      case 2: osHint = 'Linux'; break;
      default: osHint = '未知系统';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.computer, color: Color(0xFF2D6CDF), size: 16),
              const SizedBox(width: 6),
              Text('系统操作',
                  style: TextStyle(color: cs.onSurface.withAlpha(178), fontSize: 13)),
              const Spacer(),
              Text(osHint,
                  style: TextStyle(color: cs.onSurface.withAlpha(61), fontSize: 11)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [...commonItems, ...dangerItems],
          ),
        ],
      ),
    );
  }

  Widget _buildTextPanel(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ① 常用单键（顶部）
          Text('常用单键',
              style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 13)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _QuickKey(label: '↵ 回车', keycode: KeyCodes.enter, udp: widget.udpService),
              _QuickKey(label: '⌫ 退格', keycode: KeyCodes.backspace, udp: widget.udpService),
              _QuickKey(label: '⇥ Tab', keycode: KeyCodes.tab, udp: widget.udpService),
              _QuickKey(label: '⎋ Esc', keycode: KeyCodes.escape, udp: widget.udpService),
              _QuickKey(label: '␣ 空格', keycode: KeyCodes.space, udp: widget.udpService),
            ],
          ),
          const SizedBox(height: 16),

          // ② 发送按钮（仅粘贴模式显示；逐字模式敲即发，不需要按钮）
          if (!_useTypeStr) ...[
            ElevatedButton.icon(
              onPressed: _sendText,
              icon: const Icon(Icons.send),
              label: const Text('发送并粘贴', style: TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2D6CDF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // ③ 输入框
          TextField(
            controller: _textController,
            // 逐字模式单行（每字即发）；粘贴模式多行
            maxLines: _useTypeStr ? 1 : 5,
            decoration: InputDecoration(
              hintText: _useTypeStr ? null : '在此输入要发送的文字...',
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: _useTypeStr
                      ? Colors.orangeAccent
                      : const Color(0xFF2D6CDF),
                  width: 2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ④ 输入模式（底部）
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.tune, color: Color(0xFF2D6CDF), size: 16),
                const SizedBox(width: 8),
                Text('输入模式',
                    style: TextStyle(color: cs.onSurface.withAlpha(178), fontSize: 13)),
                const Spacer(),
                Text(
                  _useTypeStr ? '逐字输入' : '剪贴板粘贴',
                  style: TextStyle(
                    color: _useTypeStr
                        ? Colors.orangeAccent
                        : Colors.greenAccent,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 4),
                Switch(
                  value: _useTypeStr,
                  onChanged: (v) {
                    setState(() => _useTypeStr = v);
                    SharedPreferences.getInstance()
                        .then((p) => p.setBool(_keyTypeStr, v));
                    if (v) {
                      _initDirectMode();
                    } else {
                      _lockTextUpdate = true;
                      _textController.clear();
                      _lockTextUpdate = false;
                    }
                  },
                  activeThumbColor: Colors.orangeAccent,
                  inactiveThumbColor: Colors.greenAccent,
                  inactiveTrackColor: Colors.greenAccent.withAlpha(60),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _useTypeStr
                ? '逐字模式：敲入即发，换行键=回车，退格键=退格'
                : '剪贴板粘贴：写入剪贴板后触发 Cmd/Ctrl+V，速度快',
            style: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _KeyTile extends StatefulWidget {
  final String label;
  final String? sublabel;
  final VoidCallback onTap;
  const _KeyTile({required this.label, this.sublabel, required this.onTap});

  @override
  State<_KeyTile> createState() => _KeyTileState();
}

class _KeyTileState extends State<_KeyTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: 56,
        decoration: BoxDecoration(
          color: _pressed
              ? const Color(0xFF2D6CDF).withAlpha(60)
              : cs.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _pressed
                ? const Color(0xFF2D6CDF).withAlpha(180)
                : cs.onSurface.withAlpha(30),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              widget.label,
              style: TextStyle(
                color: _pressed ? Colors.white : cs.onSurface.withAlpha(178),
                fontSize: 18,
              ),
            ),
            if (widget.sublabel != null)
              Text(widget.sublabel!,
                  style: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _QuickKey extends StatefulWidget {
  final String label;
  final int keycode;
  final UdpService udp;
  const _QuickKey({required this.label, required this.keycode, required this.udp});

  @override
  State<_QuickKey> createState() => _QuickKeyState();
}

class _QuickKeyState extends State<_QuickKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.udp.sendKeyTap(widget.keycode);
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _pressed
              ? const Color(0xFF2D6CDF).withAlpha(50)
              : cs.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _pressed
                ? const Color(0xFF2D6CDF).withAlpha(180)
                : const Color(0xFF2D6CDF).withAlpha(80),
          ),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            color: _pressed ? Colors.white : cs.onSurface.withAlpha(178),
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

/// 系统操作快捷按钮（带触觉+视觉反馈）
class _SysChip extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool danger;
  final VoidCallback onTap;
  const _SysChip({
    required this.label,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  @override
  State<_SysChip> createState() => _SysChipState();
}

class _SysChipState extends State<_SysChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = widget.danger ? Colors.redAccent : const Color(0xFF2D6CDF);
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _pressed ? color.withAlpha(70) : color.withAlpha(30),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _pressed ? color.withAlpha(200) : color.withAlpha(100),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              widget.label,
              style: TextStyle(
                color: widget.danger
                    ? Colors.redAccent
                    : (_pressed ? Colors.white : cs.onSurface.withAlpha(178)),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑快捷键按钮（图标 + 主标签 + 快捷键提示）
class _EditChip extends StatefulWidget {
  final String label;
  final String sublabel;
  final IconData icon;
  final VoidCallback onTap;
  const _EditChip({
    required this.label,
    required this.sublabel,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_EditChip> createState() => _EditChipState();
}

class _EditChipState extends State<_EditChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const color = Color(0xFF2D6CDF);
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: _pressed ? color.withAlpha(60) : color.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _pressed ? color.withAlpha(200) : color.withAlpha(80),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, size: 16, color: _pressed ? Colors.white : color),
            const SizedBox(height: 3),
            Text(
              widget.label,
              style: TextStyle(
                color: _pressed ? Colors.white : cs.onSurface.withAlpha(178),
                fontSize: 11,
              ),
            ),
            Text(
              widget.sublabel,
              style: TextStyle(color: cs.onSurface.withAlpha(76), fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义快捷键按钮：备注文字（desc）始终显示在图标下方
class _CustomShortcutChip extends StatefulWidget {
  final String name;
  final String desc;
  final VoidCallback onTap;

  const _CustomShortcutChip({
    required this.name,
    required this.desc,
    required this.onTap,
  });

  @override
  State<_CustomShortcutChip> createState() => _CustomShortcutChipState();
}

class _CustomShortcutChipState extends State<_CustomShortcutChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const color = Color(0xFF2D6CDF);
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        HapticFeedback.lightImpact();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _pressed ? color.withAlpha(70) : color.withAlpha(30),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _pressed ? color.withAlpha(200) : color.withAlpha(80),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_outlined, size: 14, color: color),
                const SizedBox(width: 4),
                Text(
                  widget.name,
                  style: TextStyle(
                    color: _pressed ? Colors.white : cs.onSurface.withAlpha(178),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            if (widget.desc.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                widget.desc,
                style: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
