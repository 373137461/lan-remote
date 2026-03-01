import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/udp_service.dart';
import '../widgets/collapse_card.dart';

/// 空中飞鼠模式
///
/// X 轴（左右）：陀螺仪 Z 轴（偏航率）直接积分
/// Y 轴（上下）：陀螺仪 X 轴（俯仰率）直接积分
///
/// 注：纯陀螺仪积分，无磁力计互补修正，避免磁力计修正引起的"回弹"问题。
/// 磁力计数据仅用于诊断信息展示，不参与鼠标位移计算。
class GyroScreen extends StatefulWidget {
  final UdpService udpService;
  const GyroScreen({super.key, required this.udpService});

  @override
  State<GyroScreen> createState() => _GyroScreenState();
}

class _GyroScreenState extends State<GyroScreen> {
  static const int _throttleMs = 16; // ~60Hz
  static const double _defaultSensitivity = 8.0;

  /// 将弧度/帧 → 像素的基础缩放因子
  static const double _radToPixel = 100.0;

  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  Timer? _throttleTimer;

  bool _active = false;
  double _sensitivity = _defaultSensitivity;
  static const _keySens = 'gyro_sensitivity';

  // 控制面板折叠状态（默认折叠，节省屏幕空间）
  bool _controlsExpanded = false;

  // 节流累积量
  double _accDx = 0;
  double _accDy = 0;

  // 陀螺仪时间戳
  int _lastGyroUs = 0;

  // 磁力计状态（仅用于 UI 展示，不参与位移计算）
  double _magHeading = 0;
  bool _magReady = false;

  // UI 显示用
  double _dispGyroZ = 0;
  double _dispGyroX = 0;
  double _dispMagDeg = 0;

  @override
  void initState() {
    super.initState();
    _loadSensitivity();
  }

  Future<void> _loadSensitivity() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sensitivity = prefs.getDouble(_keySens) ?? _defaultSensitivity;
    });
  }

  Future<void> _saveSensitivity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keySens, _sensitivity);
  }

  @override
  void dispose() {
    _stopSensors();
    super.dispose();
  }

  void _startSensors() {
    HapticFeedback.mediumImpact();
    _lastGyroUs = 0;
    _accDx = 0;
    _accDy = 0;

    // 磁力计：仅用于 UI 展示
    _magSub = magnetometerEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen(
      _onMagEvent,
      onError: (_) {},
    );

    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(
      _onGyroEvent,
      onError: (_) {
        if (mounted) setState(() => _active = false);
      },
    );

    _throttleTimer = Timer.periodic(
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

    setState(() => _active = true);
  }

  void _stopSensors() {
    HapticFeedback.lightImpact();
    _gyroSub?.cancel();
    _gyroSub = null;
    _magSub?.cancel();
    _magSub = null;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _accDx = 0;
    _accDy = 0;
    if (mounted) setState(() => _active = false);
  }

  void _onMagEvent(MagnetometerEvent event) {
    _magHeading = math.atan2(event.x, event.y);
    _magReady = true;
    if (mounted) {
      setState(() {
        _dispMagDeg = _magHeading * 180 / math.pi;
      });
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

    // 纯陀螺仪积分：Z 轴→左右，X 轴→上下
    // 不使用磁力计修正，避免修正引起的鼠标回弹
    _accDx -= event.z * dt * _sensitivity * _radToPixel;
    _accDy -= event.x * dt * _sensitivity * _radToPixel;

    if (mounted) {
      setState(() {
        _dispGyroZ = event.z;
        _dispGyroX = event.x;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── 可滚动内容区（控制面板 + 状态卡片 + 指南针） ──
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // ── 折叠控制面板（启动按钮 + 灵敏度） ──
                CollapseCard(
                  expanded: _controlsExpanded,
                  onToggle: () =>
                      setState(() => _controlsExpanded = !_controlsExpanded),
                  bodyPadding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                  header: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _active ? Colors.greenAccent : Colors.white24,
                          boxShadow: _active
                              ? [
                                  BoxShadow(
                                    color: Colors.greenAccent.withAlpha(120),
                                    blurRadius: 6,
                                  )
                                ]
                              : null,
                        ),
                      ),
                      Text(
                        _active ? '运行中' : '已停止',
                        style: TextStyle(
                          color: _active ? Colors.greenAccent : Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '灵敏度  ${_sensitivity.toStringAsFixed(0)}',
                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                  body: Column(
                    children: [
                      const Divider(color: Colors.white10, height: 1),
                      const SizedBox(height: 12),

                      // 灵敏度滑块
                      Row(
                        children: [
                          const Text('灵敏度', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          Expanded(
                            child: Slider(
                              value: _sensitivity,
                              min: 1,
                              max: 20,
                              divisions: 19,
                              label: _sensitivity.toStringAsFixed(0),
                              activeColor: const Color(0xFF2D6CDF),
                              onChanged: (v) {
                                setState(() => _sensitivity = v);
                                _saveSensitivity();
                              },
                            ),
                          ),
                          SizedBox(
                            width: 28,
                            child: Text(
                              _sensitivity.toStringAsFixed(0),
                              textAlign: TextAlign.right,
                              style: const TextStyle(color: Colors.white54, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 启动/停止按钮
                      _StartStopButton(
                        active: _active,
                        onTap: _active ? _stopSensors : _startSensors,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _active
                            ? '竖持手机：左右转动→鼠标X，前后倾斜→鼠标Y'
                            : '点击启动空中飞鼠（陀螺仪积分）',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // ── 状态卡片（诊断信息） ──
                _StatusCard(
                  active: _active,
                  gyroZ: _dispGyroZ,
                  gyroX: _dispGyroX,
                  magDeg: _magReady ? _dispMagDeg : double.nan,
                ),
                const SizedBox(height: 10),

                // ── 指南针可视化（激活后显示） ──
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 300),
                  crossFadeState:
                      _active ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                  firstChild: _CompassCard(magHeading: _magHeading),
                  secondChild: const SizedBox.shrink(),
                ),
                if (_active) const SizedBox(height: 8),
              ],
            ),
          ),
        ),

        // ── 底部鼠标按键（固定在屏幕底部，大尺寸，双键均支持长按） ──
        _buildMouseButtons(),
      ],
    );
  }

  Widget _buildMouseButtons() {
    return Container(
      color: const Color(0xFF16213E),
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
// 紧凑启动/停止按钮
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
        height: 52,
        decoration: BoxDecoration(
          color: _pressed ? color.withAlpha(200) : color,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: color.withAlpha(_pressed ? 60 : 90),
              blurRadius: _pressed ? 6 : 14,
              spreadRadius: _pressed ? 0 : 2,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.active ? Icons.stop_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 26,
            ),
            const SizedBox(width: 8),
            Text(
              widget.active ? '停止飞鼠' : '启动飞鼠',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// 状态卡片
// ─────────────────────────────────────────────────────────
class _StatusCard extends StatelessWidget {
  final bool active;
  final double gyroZ;
  final double gyroX;
  final double magDeg;

  const _StatusCard({
    required this.active,
    required this.gyroZ,
    required this.gyroX,
    required this.magDeg,
  });

  @override
  Widget build(BuildContext context) {
    final magStr = magDeg.isNaN ? '—' : '${magDeg.toStringAsFixed(0)}°';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _DataItem(
            label: '状态',
            value: active ? '运行中' : '已停止',
            valueColor: active ? Colors.greenAccent : Colors.white38,
          ),
          _DataItem(label: 'Yaw(Z)', value: gyroZ.toStringAsFixed(2)),
          _DataItem(label: 'Pitch(X)', value: gyroX.toStringAsFixed(2)),
          _DataItem(label: '罗盘°', value: magStr, valueColor: Colors.amber),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// 指南针可视化卡片（仅展示磁力计方向，不参与位移计算）
// ─────────────────────────────────────────────────────────
class _CompassCard extends StatelessWidget {
  final double magHeading;

  const _CompassCard({required this.magHeading});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: CustomPaint(
              painter: _CompassPainter(magHeading: magHeading),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                            color: Colors.amber, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(
                      '磁力计  ${(magHeading * 180 / math.pi).toStringAsFixed(1)}°',
                      style: const TextStyle(color: Colors.amber, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '鼠标位移由陀螺仪积分控制\n罗盘仅供参考，不影响移动',
                  style: TextStyle(
                      color: Colors.white30, fontSize: 11, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  final double magHeading;

  const _CompassPainter({required this.magHeading});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 3;

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Colors.white12
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    for (var i = 0; i < 4; i++) {
      final angle = i * math.pi / 2;
      final pt = Offset(
        center.dx + (r - 4) * math.sin(angle),
        center.dy - (r - 4) * math.cos(angle),
      );
      canvas.drawCircle(pt, 2, Paint()..color = Colors.white24);
    }

    _drawNeedle(canvas, center, r - 6, magHeading, Colors.amber, 2.5);
    canvas.drawCircle(center, 3, Paint()..color = Colors.white54);
  }

  void _drawNeedle(Canvas canvas, Offset center, double length, double heading,
      Color color, double strokeWidth) {
    final tip = Offset(
      center.dx + length * math.sin(heading),
      center.dy - length * math.cos(heading),
    );
    final tail = Offset(
      center.dx - (length * 0.3) * math.sin(heading),
      center.dy + (length * 0.3) * math.cos(heading),
    );
    canvas.drawLine(
        tail,
        tip,
        Paint()
          ..color = color
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_CompassPainter old) => old.magHeading != magHeading;
}

class _DataItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _DataItem({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────
// 鼠标按键（带触觉+视觉反馈，支持长按持续按下）
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
          color: _pressed ? const Color(0xFF1E3A6E) : const Color(0xFF16213E),
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
            Icon(
              widget.icon,
              size: 22,
              color: _pressed ? Colors.white : Colors.white54,
            ),
            const SizedBox(width: 8),
            Text(
              widget.label,
              style: TextStyle(
                color: _pressed ? Colors.white : Colors.white70,
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
