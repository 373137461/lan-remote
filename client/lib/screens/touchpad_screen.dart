import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/udp_service.dart';
import '../widgets/collapse_card.dart';

/// 触摸板模式 + 空中飞鼠集成
///
/// 触摸板手势：
/// - 单指滑动：鼠标移动（带发光指示点特效）
/// - 单指轻敲：左键单击
/// - 单指双敲（< 300ms）：左键双击
/// - 单指长按后滑动：拖拽（橙色发光 + 背景变色）
/// - 双指轻敲：右键单击
/// - 右侧弹簧滑块：鼠标滚轮
///
/// 空中飞鼠（整合在设置折叠卡中）：
/// - 纯陀螺仪积分，无回弹，Z 轴→横向，X 轴→纵向
class TouchpadScreen extends StatefulWidget {
  final UdpService udpService;
  const TouchpadScreen({super.key, required this.udpService});

  @override
  State<TouchpadScreen> createState() => _TouchpadScreenState();
}

class _TouchpadScreenState extends State<TouchpadScreen> {

  // ── 灵敏度 ──
  double _touchSensitivity = 1.5;
  double _scrollSensitivity = 1.0;
  double _gyroSensitivity = 8.0;
  bool _settingsExpanded = false;

  static const _keyTouch = 'tp_touch_sens';
  static const _keyScroll = 'tp_scroll_sens';
  static const _keyGyroSens = 'gyro_sensitivity';

  // ── 手势状态 ──
  Offset? _lastFocalPoint;
  int _pointerCount = 0;
  bool _isTap = false;
  bool _isTwoFingerTap = false;
  Offset _tapDownPosition = Offset.zero;
  static const double _tapMoveThreshold = 10.0;
  int? _lastTapMs;
  static const int _doubleClickMs = 300;
  bool _isDragging = false;
  Timer? _dragTimer;
  static const int _dragDelayMs = 300;

  // ── 视觉特效 ──
  Offset? _fingerPos;      // 手指在触摸板局部坐标
  bool _isTouching = false;

  // ── 空中飞鼠 ──
  bool _gyroActive = false;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _gyroThrottleTimer;
  double _accDx = 0, _accDy = 0;
  int _lastGyroUs = 0;
  double _dispGyroZ = 0, _dispGyroX = 0;
  static const double _radToPixel = 100.0;
  static const int _throttleMs = 16;

  @override
  void initState() {
    super.initState();
    _loadPrefs();

  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _touchSensitivity = prefs.getDouble(_keyTouch) ?? 1.5;
      _scrollSensitivity = prefs.getDouble(_keyScroll) ?? 1.0;
      _gyroSensitivity = prefs.getDouble(_keyGyroSens) ?? 8.0;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyTouch, _touchSensitivity);
    await prefs.setDouble(_keyScroll, _scrollSensitivity);
    await prefs.setDouble(_keyGyroSens, _gyroSensitivity);
  }

  @override
  void dispose() {
    _dragTimer?.cancel();
    _gyroSub?.cancel();
    _gyroThrottleTimer?.cancel();
    super.dispose();
  }

  // ────────────────────────────────────────────────────────
  // 空中飞鼠控制
  // ────────────────────────────────────────────────────────

  void _startGyro() {
    HapticFeedback.mediumImpact();
    _lastGyroUs = 0;
    _accDx = 0;
    _accDy = 0;

    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_onGyroEvent, onError: (_) {
      if (mounted) setState(() => _gyroActive = false);
    });

    _gyroThrottleTimer = Timer.periodic(
      Duration(milliseconds: _throttleMs),
      (_) {
        final dx = _accDx.round();
        final dy = _accDy.round();
        if (dx != 0 || dy != 0) {
          widget.udpService.sendMouseMove(dx, dy);
          _accDx = 0;
          _accDy = 0;
        }
      },
    );
    setState(() => _gyroActive = true);
  }

  void _stopGyro() {
    _gyroSub?.cancel();
    _gyroSub = null;
    _gyroThrottleTimer?.cancel();
    _gyroThrottleTimer = null;
    _accDx = 0;
    _accDy = 0;
    if (mounted) {
      HapticFeedback.lightImpact();
      setState(() => _gyroActive = false);
    }
  }

  void _onGyroEvent(GyroscopeEvent event) {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    if (_lastGyroUs == 0) {
      _lastGyroUs = nowUs;
      return;
    }
    final dt = (nowUs - _lastGyroUs) / 1e6;
    _lastGyroUs = nowUs;
    _accDx -= event.z * dt * _gyroSensitivity * _radToPixel;
    _accDy -= event.x * dt * _gyroSensitivity * _radToPixel;
    if (mounted) setState(() { _dispGyroZ = event.z; _dispGyroX = event.x; });
  }

  // ────────────────────────────────────────────────────────
  // 指针 / 手势回调
  // ────────────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e) {
    _pointerCount++;
    setState(() {
      _isTouching = true;
      _fingerPos = e.localPosition;
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    setState(() => _fingerPos = e.localPosition);
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointerCount = (_pointerCount - 1).clamp(0, 10);
    if (_pointerCount == 0) {
      setState(() {
        _isTouching = false;
        _fingerPos = null;
      });
    }
  }

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
          HapticFeedback.mediumImpact();
          setState(() {});
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
      if (dx != 0 || dy != 0) widget.udpService.sendMouseMove(dx, dy);
    }
    _lastFocalPoint = d.focalPoint;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _dragTimer?.cancel();
    _dragTimer = null;

    if (_isDragging) {
      widget.udpService.sendMouseUp(0);
      setState(() => _isDragging = false);
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

  // ────────────────────────────────────────────────────────
  // 构建
  // ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildSettings(context),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildTouchpadArea(context)),
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
        _buildBottomButtons(context),
      ],
    );
  }

  // ── 设置区（触摸板 + 飞鼠合并为一张折叠卡） ──
  Widget _buildSettings(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gyroSummary = _gyroActive
        ? '飞鼠运行中'
        : '飞鼠 ${_gyroSensitivity.toStringAsFixed(0)}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: CollapseCard(
        expanded: _settingsExpanded,
        onToggle: () => setState(() => _settingsExpanded = !_settingsExpanded),
        header: Row(
          children: [
            const Icon(Icons.tune, color: Color(0xFF2D6CDF), size: 14),
            const SizedBox(width: 6),
            Text('设置',
                style: TextStyle(color: cs.onSurface.withAlpha(178), fontSize: 13)),
            const Spacer(),
            if (_gyroActive)
              Container(
                width: 6, height: 6,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.greenAccent,
                  boxShadow: [BoxShadow(
                      color: Colors.greenAccent.withAlpha(120), blurRadius: 4)],
                ),
              ),
            Text(
              '触控 ${_touchSensitivity.toStringAsFixed(1)}  ·  '
              '滚轮 ${_scrollSensitivity.toStringAsFixed(1)}  ·  $gyroSummary',
              style: TextStyle(
                color: _gyroActive ? Colors.greenAccent : cs.onSurface.withAlpha(97),
                fontSize: 11,
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            const Divider(height: 1),
            const SizedBox(height: 10),
            // 触摸板灵敏度
            _SensitivityRow(
              label: '触控灵敏度',
              icon: Icons.touch_app,
              value: _touchSensitivity,
              min: 0.5, max: 5.0, divisions: 18,
              onChanged: (v) {
                setState(() => _touchSensitivity = v);
                _savePrefs();
              },
            ),
            const SizedBox(height: 4),
            _SensitivityRow(
              label: '滚轮灵敏度',
              icon: Icons.mouse,
              value: _scrollSensitivity,
              min: 0.3, max: 4.0, divisions: 19,
              onChanged: (v) {
                setState(() => _scrollSensitivity = v);
                _savePrefs();
              },
            ),
            const Divider(height: 20),
            // 空中飞鼠
            _SensitivityRow(
              label: '飞鼠灵敏度',
              icon: Icons.screen_rotation_outlined,
              value: _gyroSensitivity,
              min: 1, max: 20, divisions: 19,
              onChanged: (v) {
                setState(() => _gyroSensitivity = v);
                _savePrefs();
              },
            ),
            const SizedBox(height: 10),
            _StartStopButton(
              active: _gyroActive,
              onTap: _gyroActive ? _stopGyro : _startGyro,
            ),
            const SizedBox(height: 8),
            if (_gyroActive) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _GyroChip(label: 'Z偏航', value: _dispGyroZ),
                  const SizedBox(width: 16),
                  _GyroChip(label: 'X俯仰', value: _dispGyroX),
                ],
              ),
              const SizedBox(height: 4),
            ],
            Text(
              _gyroActive
                  ? '竖持手机：左右转→鼠标X，前后倾→鼠标Y'
                  : '启动后转动手机控制鼠标（纯陀螺仪，无回弹）',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: cs.onSurface.withAlpha(97), fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  // ── 触摸板主区域（含视觉特效） ──
  Widget _buildTouchpadArea(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;
    final Color bgColor;
    if (_isDragging) {
      bgColor = isDark ? const Color(0xFF07192E) : const Color(0xFFACCBFF);
    } else if (_isTouching) {
      bgColor = isDark ? const Color(0xFF0D2A50) : const Color(0xFFBFD8FF);
    } else {
      bgColor = isDark ? const Color(0xFF0F3460) : const Color(0xFFDCEBFF);
    }

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: GestureDetector(
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          color: bgColor,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 视觉特效层
              if (_isTouching)
                CustomPaint(
                  painter: _TouchEffectPainter(
                    fingerPos: _fingerPos,
                    isTouching: _isTouching,
                    isDragging: _isDragging,
                  ),
                ),

              // 提示文字（触摸时淡出）
              AnimatedOpacity(
                opacity: _isTouching ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isDragging ? Icons.open_with : Icons.touch_app,
                        size: 44,
                        color: cs.onSurface.withAlpha(50),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isDragging
                            ? '拖拽中…松手结束'
                            : '单指滑动 移动鼠标\n单击 左键 · 双击 左键双击\n长按后滑动 拖拽\n双指轻敲 右键',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: cs.onSurface.withAlpha(70),
                          fontSize: 13,
                          height: 1.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 底部鼠标按键（左右键均支持长按，与飞鼠样式一致） ──
  Widget _buildBottomButtons(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: _MouseButton(
              label: '左键',
              icon: Icons.mouse,
              onTap: () => widget.udpService.sendMouseClick(0),
              onLongPressStart: () => widget.udpService.sendMouseDown(0),
              onLongPressEnd: () => widget.udpService.sendMouseUp(0),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _MouseButton(
              label: '右键',
              icon: Icons.mouse,
              onTap: () => widget.udpService.sendMouseClick(1),
              onLongPressStart: () => widget.udpService.sendMouseDown(1),
              onLongPressEnd: () => widget.udpService.sendMouseUp(1),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// 触摸视觉特效 Painter
// ─────────────────────────────────────────────────────────
class _TouchEffectPainter extends CustomPainter {
  final Offset? fingerPos;
  final bool isTouching;
  final bool isDragging;

  const _TouchEffectPainter({
    required this.fingerPos,
    required this.isTouching,
    required this.isDragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 手指发光点
    if (fingerPos != null && isTouching) {
      final color = isDragging ? Colors.orangeAccent : const Color(0xFF4D9FFF);
      final outerR = isDragging ? 38.0 : 26.0;
      final midR   = isDragging ? 20.0 : 13.0;
      final innerR = isDragging ? 7.0  : 5.0;

      // 外晕
      canvas.drawCircle(fingerPos!, outerR,
          Paint()..color = color.withAlpha(18));
      // 中晕
      canvas.drawCircle(fingerPos!, midR,
          Paint()..color = color.withAlpha(55));
      // 核心点
      canvas.drawCircle(fingerPos!, innerR,
          Paint()..color = color.withAlpha(200));
      // 外环描边
      canvas.drawCircle(
        fingerPos!, outerR,
        Paint()
          ..color = color.withAlpha(70)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_TouchEffectPainter old) =>
      old.fingerPos != fingerPos ||
      old.isTouching != isTouching ||
      old.isDragging != isDragging;
}

// ─────────────────────────────────────────────────────────
// 灵敏度滑块行
// ─────────────────────────────────────────────────────────
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
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 14, color: cs.onSurface.withAlpha(97)),
        const SizedBox(width: 6),
        SizedBox(
          width: 72,
          child: Text(label,
              style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min, max: max, divisions: divisions,
            activeColor: const Color(0xFF2D6CDF),
            inactiveColor: cs.onSurface.withAlpha(30),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            value.toStringAsFixed(1),
            textAlign: TextAlign.right,
            style: TextStyle(color: cs.onSurface.withAlpha(138), fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────
// 飞鼠数据小芯片
// ─────────────────────────────────────────────────────────
class _GyroChip extends StatelessWidget {
  final String label;
  final double value;
  const _GyroChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(label,
            style: TextStyle(color: cs.onSurface.withAlpha(97), fontSize: 10)),
        const SizedBox(height: 2),
        Text(
          value.toStringAsFixed(2),
          style: TextStyle(
              color: cs.onSurface.withAlpha(178), fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────
// 飞鼠启动/停止按钮
// ─────────────────────────────────────────────────────────
class _StartStopButton extends StatefulWidget {
  final bool active;
  final VoidCallback onTap;
  const _StartStopButton({required this.active, required this.onTap});

  @override
  State<_StartStopButton> createState() => _StartStopButtonState();
}

class _StartStopButtonState extends State<_StartStopButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? Colors.redAccent : const Color(0xFF2D6CDF);
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 48,
        decoration: BoxDecoration(
          color: _pressed ? color.withAlpha(200) : color,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: color.withAlpha(_pressed ? 60 : 90),
              blurRadius: _pressed ? 6 : 12,
              spreadRadius: _pressed ? 0 : 2,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.active ? Icons.stop_rounded : Icons.play_arrow_rounded,
              color: Colors.white, size: 22,
            ),
            const SizedBox(width: 6),
            Text(
              widget.active ? '停止飞鼠' : '启动飞鼠',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// 弹簧回弹滚轮滑块
// ─────────────────────────────────────────────────────────
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

  /// 累积器：每累积 _basePx 像素触发 1 次 scroll
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
    _scrollAcc = 0.0;
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
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0A2040) : const Color(0xFFE8F2FF);

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
            decoration: BoxDecoration(
              color: bgColor,
              border: Border(
                  left: BorderSide(color: Theme.of(context).dividerColor, width: 1)),
            ),
            child: Stack(
              children: [
                Positioned(
                  top: 10, left: 0, right: 0,
                  child: Icon(Icons.keyboard_arrow_up,
                      color: cs.onSurface.withAlpha(61), size: 18),
                ),
                Positioned(
                  top: 26, left: 0, right: 0,
                  child: Icon(Icons.mouse, color: cs.onSurface.withAlpha(30), size: 14),
                ),
                Positioned(
                  top: 44, bottom: 44, left: 0, right: 0,
                  child: Center(
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: cs.onSurface.withAlpha(26),
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
                          const Color(0xFF2D6CDF),
                          const Color(0xFF00CFFF),
                          intensity),
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
                    child: const Icon(Icons.drag_handle,
                        color: Colors.white70, size: 16),
                  ),
                ),
                Positioned(
                  bottom: 10, left: 0, right: 0,
                  child: Icon(Icons.keyboard_arrow_down,
                      color: cs.onSurface.withAlpha(61), size: 18),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────
// 底部鼠标按键（带触觉+视觉反馈，支持长按持续按下）
// ─────────────────────────────────────────────────────────
class _MouseButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;

  const _MouseButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.onLongPressStart,
    this.onLongPressEnd,
  });

  @override
  State<_MouseButton> createState() => _MouseButtonState();
}

class _MouseButtonState extends State<_MouseButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;
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
        duration: const Duration(milliseconds: 90),
        height: 72,
        decoration: BoxDecoration(
          color: _pressed
              ? (isDark ? const Color(0xFF1E3A6E) : const Color(0xFF2D6CDF).withAlpha(30))
              : cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _pressed
                ? const Color(0xFF2D6CDF)
                : const Color(0xFF2D6CDF).withAlpha(100),
            width: _pressed ? 1.5 : 1.0,
          ),
          boxShadow: _pressed
              ? [
                  BoxShadow(
                    color: const Color(0xFF2D6CDF).withAlpha(60),
                    blurRadius: 10,
                    spreadRadius: 1,
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, size: 22,
                color: _pressed ? cs.onSurface : cs.onSurface.withAlpha(138)),
            const SizedBox(width: 8),
            Text(
              widget.label,
              style: TextStyle(
                color: _pressed ? cs.onSurface : cs.onSurface.withAlpha(178),
                fontSize: 20,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
