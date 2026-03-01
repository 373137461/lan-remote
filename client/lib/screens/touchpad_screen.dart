import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/udp_service.dart';
import '../widgets/collapse_card.dart';

/// 触摸板模式
/// - 单指滑动：鼠标移动
/// - 单指轻敲：左键单击
/// - 单指双敲（快速两次）：左键双击
/// - 单指长按后滑动：拖拽（鼠标按下并移动）
/// - 双指轻敲：右键单击
/// - 右侧弹簧滑块：鼠标滚轮
class TouchpadScreen extends StatefulWidget {
  final UdpService udpService;
  const TouchpadScreen({super.key, required this.udpService});

  @override
  State<TouchpadScreen> createState() => _TouchpadScreenState();
}

class _TouchpadScreenState extends State<TouchpadScreen> {
  // ── 灵敏度设置 ──
  double _touchSensitivity = 1.5;  // 触控移动速度
  double _scrollSensitivity = 1.0; // 滚轮速度倍率
  bool _settingsExpanded = false;

  static const _keyTouch = 'tp_touch_sens';
  static const _keyScroll = 'tp_scroll_sens';

  // ── 手势状态 ──
  Offset? _lastFocalPoint;
  int _pointerCount = 0;
  bool _isTap = false;
  bool _isTwoFingerTap = false;
  Offset _tapDownPosition = Offset.zero;
  static const double _tapMoveThreshold = 10.0;

  // 双击检测
  int? _lastTapMs;
  static const int _doubleClickMs = 300;

  // 拖拽状态
  bool _isDragging = false;
  Timer? _dragTimer;
  static const int _dragDelayMs = 300;

  @override
  void initState() {
    super.initState();
    _loadSensitivity();
  }

  Future<void> _loadSensitivity() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _touchSensitivity = prefs.getDouble(_keyTouch) ?? 1.5;
      _scrollSensitivity = prefs.getDouble(_keyScroll) ?? 1.0;
    });
  }

  Future<void> _saveSensitivity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyTouch, _touchSensitivity);
    await prefs.setDouble(_keyScroll, _scrollSensitivity);
  }

  @override
  void dispose() {
    _dragTimer?.cancel();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent e) => _pointerCount++;
  void _onPointerUp(PointerUpEvent e) =>
      _pointerCount = (_pointerCount - 1).clamp(0, 10);

  void _onScaleStart(ScaleStartDetails d) {
    _lastFocalPoint = d.focalPoint;
    _isTap = true;
    _isTwoFingerTap = _pointerCount >= 2;
    _tapDownPosition = d.focalPoint;

    if (_pointerCount == 1 && !_isDragging) {
      _dragTimer?.cancel();
      _dragTimer = Timer(const Duration(milliseconds: _dragDelayMs), () {
        if (_isTap && !_isDragging && _pointerCount == 1) {
          _isDragging = true;
          _isTap = false;
          widget.udpService.sendMouseDown(0);
        }
      });
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_lastFocalPoint == null) return;

    final delta = d.focalPoint - _lastFocalPoint!;
    final totalMove = (d.focalPoint - _tapDownPosition).distance;

    if (totalMove > _tapMoveThreshold) {
      _isTap = false;
      _dragTimer?.cancel();
      _dragTimer = null;
    }

    if (_pointerCount < 2) {
      final dx = (delta.dx * _touchSensitivity).round();
      final dy = (delta.dy * _touchSensitivity).round();
      if (dx != 0 || dy != 0) {
        widget.udpService.sendMouseMove(dx, dy);
      }
    }

    _lastFocalPoint = d.focalPoint;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _dragTimer?.cancel();
    _dragTimer = null;

    if (_isDragging) {
      widget.udpService.sendMouseUp(0);
      _isDragging = false;
    } else if (_isTap) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_isTwoFingerTap) {
        widget.udpService.sendMouseClick(1);
        _lastTapMs = null;
      } else {
        if (_lastTapMs != null && now - _lastTapMs! < _doubleClickMs) {
          widget.udpService.sendMouseDoubleClick(0);
          _lastTapMs = null;
        } else {
          widget.udpService.sendMouseClick(0);
          _lastTapMs = now;
        }
      }
    }

    _lastFocalPoint = null;
    _isTap = false;
    _isTwoFingerTap = false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildSettings(),
        _buildButtonBar(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerUp: _onPointerUp,
                  child: GestureDetector(
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: Container(
                      color: _isDragging
                          ? const Color(0xFF0A2850)
                          : const Color(0xFF0F3460),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _isDragging ? Icons.open_with : Icons.touch_app,
                              size: 44,
                              color: Colors.white.withAlpha(_isDragging ? 100 : 50),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _isDragging
                                  ? '拖拽中…松手结束'
                                  : '单指滑动 移动鼠标\n单击 左键 · 双击 左键双击\n长按后滑动 拖拽\n双指轻敲 右键',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white
                                    .withAlpha(_isDragging ? 120 : 70),
                                fontSize: 13,
                                height: 1.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 54,
                child: _SpringScrollSlider(
                  onScroll: (v) => widget.udpService.sendMouseScroll(v),
                  scrollSensitivity: _scrollSensitivity,
                ),
              ),
            ],
          ),
        ),
        _buildClickButtons(),
      ],
    );
  }

  Widget _buildSettings() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: CollapseCard(
        expanded: _settingsExpanded,
        onToggle: () => setState(() => _settingsExpanded = !_settingsExpanded),
        header: Row(
          children: [
            const Icon(Icons.tune, color: Color(0xFF2D6CDF), size: 14),
            const SizedBox(width: 6),
            const Text('触摸板设置', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const Spacer(),
            Text(
              '触控 ${_touchSensitivity.toStringAsFixed(1)}  ·  滚轮 ${_scrollSensitivity.toStringAsFixed(1)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        body: Column(
          children: [
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 10),
            _SensitivityRow(
              label: '触控灵敏度',
              icon: Icons.touch_app,
              value: _touchSensitivity,
              min: 0.5,
              max: 5.0,
              divisions: 18,
              onChanged: (v) {
                setState(() => _touchSensitivity = v);
                _saveSensitivity();
              },
            ),
            const SizedBox(height: 4),
            _SensitivityRow(
              label: '滚轮灵敏度',
              icon: Icons.mouse,
              value: _scrollSensitivity,
              min: 0.3,
              max: 4.0,
              divisions: 19,
              onChanged: (v) {
                setState(() => _scrollSensitivity = v);
                _saveSensitivity();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButtonBar() {
    return Container(
      color: const Color(0xFF16213E),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ActionChip(label: '左键', onTap: () => widget.udpService.sendMouseClick(0)),
          _ActionChip(label: '右键', onTap: () => widget.udpService.sendMouseClick(1)),
          _ActionChip(label: '中键', onTap: () => widget.udpService.sendMouseClick(2)),
          _ActionChip(label: '双击', onTap: () => widget.udpService.sendMouseDoubleClick(0)),
        ],
      ),
    );
  }

  Widget _buildClickButtons() {
    return Container(
      color: const Color(0xFF16213E),
      child: Row(
        children: [
          Expanded(
            child: _LargeButton(
              label: '左键',
              onTap: () => widget.udpService.sendMouseClick(0),
              onLongPressStart: () => widget.udpService.sendMouseDown(0),
              onLongPressEnd: () => widget.udpService.sendMouseUp(0),
            ),
          ),
          Container(width: 1, height: 56, color: Colors.white12),
          Expanded(
            child: _LargeButton(
              label: '右键',
              onTap: () => widget.udpService.sendMouseClick(1),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 灵敏度滑块行 ────────────────────────────────────────────
class _SensitivityRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SensitivityRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.white38),
        const SizedBox(width: 6),
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            activeColor: const Color(0xFF2D6CDF),
            inactiveColor: Colors.white12,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            value.toStringAsFixed(1),
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ─── 弹簧回弹滚轮滑块 ───────────────────────────────────────
class _SpringScrollSlider extends StatefulWidget {
  final ValueChanged<int> onScroll;
  final double scrollSensitivity;
  const _SpringScrollSlider({
    required this.onScroll,
    this.scrollSensitivity = 1.0,
  });

  @override
  State<_SpringScrollSlider> createState() => _SpringScrollSliderState();
}

class _SpringScrollSliderState extends State<_SpringScrollSlider>
    with SingleTickerProviderStateMixin {
  double _offset = 0.0;
  double _halfTrack = 120.0;

  /// 滚动累积器：每累积 _basePx 像素触发 1 次 scroll
  /// 灵敏度越高 → 分母越小 → 同样滑动触发次数越多
  static const double _basePx = 30.0;
  double _scrollAcc = 0.0;

  late final AnimationController _springCtrl;
  Animation<double>? _springAnim;

  @override
  void initState() {
    super.initState();
    _springCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
  }

  @override
  void dispose() {
    _springCtrl.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) => _springCtrl.stop();

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() {
      _offset = (_offset + d.delta.dy).clamp(-_halfTrack, _halfTrack);
    });
    // 累积滑动距离，每 (_basePx / sensitivity) 像素触发 1 次 scroll
    _scrollAcc += -d.delta.dy * widget.scrollSensitivity;
    while (_scrollAcc >= _basePx) {
      widget.onScroll(1);
      _scrollAcc -= _basePx;
    }
    while (_scrollAcc <= -_basePx) {
      widget.onScroll(-1);
      _scrollAcc += _basePx;
    }
  }

  void _onDragEnd(DragEndDetails _) {
    _scrollAcc = 0.0; // 松手时重置累积器，避免下次拖动时跨越阈值误触发
    final start = _offset;
    _springAnim = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _springCtrl, curve: Curves.elasticOut),
    )..addListener(() {
        if (mounted) setState(() => _offset = _springAnim!.value);
      });
    _springCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        _halfTrack = (constraints.maxHeight / 2 - 36).clamp(60.0, 200.0);
        final center = constraints.maxHeight / 2;
        final thumbTop = center + _offset - 22;
        final intensity = (_offset / _halfTrack).abs().clamp(0.0, 1.0);

        return GestureDetector(
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFF0A2040),
              border: Border(left: BorderSide(color: Colors.white10, width: 1)),
            ),
            child: Stack(
              children: [
                const Positioned(
                  top: 10, left: 0, right: 0,
                  child: Icon(Icons.keyboard_arrow_up, color: Colors.white24, size: 18),
                ),
                const Positioned(
                  top: 26, left: 0, right: 0,
                  child: Icon(Icons.mouse, color: Colors.white12, size: 14),
                ),
                Positioned(
                  top: 44, bottom: 44, left: 0, right: 0,
                  child: Center(
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: thumbTop, left: 7, right: 7,
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: Color.lerp(
                          const Color(0xFF2D6CDF), const Color(0xFF00CFFF), intensity),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        if (intensity > 0.05)
                          BoxShadow(
                            color: const Color(0xFF2D6CDF)
                                .withAlpha((intensity * 160).round()),
                            blurRadius: 10,
                            spreadRadius: 1,
                          ),
                      ],
                    ),
                    child: const Icon(Icons.drag_handle, color: Colors.white70, size: 16),
                  ),
                ),
                const Positioned(
                  bottom: 10, left: 0, right: 0,
                  child: Icon(Icons.keyboard_arrow_down, color: Colors.white24, size: 18),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── 顶栏快捷按钮（带触觉+视觉反馈）────────────────────────
class _ActionChip extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _ActionChip({required this.label, required this.onTap});

  @override
  State<_ActionChip> createState() => _ActionChipState();
}

class _ActionChipState extends State<_ActionChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: _pressed
              ? const Color(0xFF2D6CDF).withAlpha(110)
              : const Color(0xFF2D6CDF).withAlpha(40),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _pressed
                ? const Color(0xFF2D6CDF).withAlpha(200)
                : const Color(0xFF2D6CDF).withAlpha(80),
          ),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            color: _pressed ? Colors.white : Colors.white70,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

// ─── 底栏大按钮（带触觉+视觉反馈，支持长按拖拽）────────────
class _LargeButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;
  const _LargeButton({
    required this.label,
    required this.onTap,
    this.onLongPressStart,
    this.onLongPressEnd,
  });

  @override
  State<_LargeButton> createState() => _LargeButtonState();
}

class _LargeButtonState extends State<_LargeButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
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
      onLongPressStart: widget.onLongPressStart != null
          ? (d) {
              setState(() => _pressed = true);
              HapticFeedback.mediumImpact();
              widget.onLongPressStart!();
            }
          : null,
      onLongPressEnd: widget.onLongPressEnd != null
          ? (d) {
              setState(() => _pressed = false);
              widget.onLongPressEnd!();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _pressed ? const Color(0xFF2D6CDF).withAlpha(40) : Colors.transparent,
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            color: _pressed ? Colors.white : Colors.white70,
            fontSize: 16,
            fontWeight: _pressed ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
