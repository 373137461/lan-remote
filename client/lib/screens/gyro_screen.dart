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
/// X 轴（左右）：陀螺仪 Z 轴（偏航率）积分 + 磁力计互补滤波修正漂移
/// Y 轴（上下）：陀螺仪 X 轴（俯仰率）直接积分（俯仰轴漂移极小）
///
/// 互补滤波公式：
///   yaw_est = α × (yaw_est + gyro.z × dt) + (1-α) × mag_heading
/// α = 0.95 → 短期响应靠陀螺仪（平滑），长期方向由磁力计修正（防漂移）
class GyroScreen extends StatefulWidget {
  final UdpService udpService;
  const GyroScreen({super.key, required this.udpService});

  @override
  State<GyroScreen> createState() => _GyroScreenState();
}

class _GyroScreenState extends State<GyroScreen> {
  static const int _throttleMs = 16; // ~60Hz
  static const double _defaultSensitivity = 8.0;

  /// 互补滤波系数：越大越信任陀螺仪（响应快），越小越信任磁力计（防漂移）
  static const double _alpha = 0.95;

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

  // 互补滤波状态
  double _estimatedYaw = 0;
  double _prevYaw = 0;
  bool _yawInitialized = false;
  int _lastGyroUs = 0;

  // 磁力计状态
  double _magHeading = 0;
  bool _magReady = false;

  // UI 显示用
  double _dispGyroZ = 0;
  double _dispGyroX = 0;
  double _dispMagDeg = 0;
  double _dispFusedDeg = 0;

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
    _yawInitialized = false;
    _magReady = false;
    _lastGyroUs = 0;
    _estimatedYaw = 0;
    _prevYaw = 0;
    _accDx = 0;
    _accDy = 0;

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
      if (_magReady) {
        _estimatedYaw = _magHeading;
        _prevYaw = _magHeading;
        _yawInitialized = true;
      }
      return;
    }

    final dt = (nowUs - _lastGyroUs) / 1e6;
    _lastGyroUs = nowUs;

    if (!_yawInitialized && _magReady) {
      _estimatedYaw = _magHeading;
      _prevYaw = _magHeading;
      _yawInitialized = true;
    }

    final gyroPredict = _estimatedYaw + event.z * dt;

    double magDiff = _magHeading - gyroPredict;
    while (magDiff > math.pi) { magDiff -= 2 * math.pi; }
    while (magDiff < -math.pi) { magDiff += 2 * math.pi; }

    _estimatedYaw = gyroPredict + (1.0 - _alpha) * magDiff;

    double deltaYaw = _estimatedYaw - _prevYaw;
    while (deltaYaw > math.pi) { deltaYaw -= 2 * math.pi; }
    while (deltaYaw < -math.pi) { deltaYaw += 2 * math.pi; }
    _prevYaw = _estimatedYaw;

    _accDx -= deltaYaw * _sensitivity * _radToPixel;
    _accDy -= event.x * dt * _sensitivity * _radToPixel;

    if (mounted) {
      setState(() {
        _dispGyroZ = event.z;
        _dispGyroX = event.x;
        _dispFusedDeg = _estimatedYaw * 180 / math.pi;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // ── 鼠标按键（置顶，加大） ──
          Row(
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
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── 折叠控制面板（启动按钮 + 灵敏度） ──
          CollapseCard(
            expanded: _controlsExpanded,
            onToggle: () =>
                setState(() => _controlsExpanded = !_controlsExpanded),
            bodyPadding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
            header: Row(
              children: [
                // 运行状态指示点
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

                // 紧凑版启动/停止按钮
                _StartStopButton(
                  active: _active,
                  onTap: _active ? _stopSensors : _startSensors,
                ),
                const SizedBox(height: 8),
                Text(
                  _active
                      ? '竖持手机：左右转动→鼠标X，前后倾斜→鼠标Y'
                      : '点击启动空中飞鼠（陀螺仪 + 指南针互补滤波）',
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
            magDeg: _dispMagDeg,
            fusedDeg: _dispFusedDeg,
          ),
          const SizedBox(height: 10),

          // ── 指南针可视化（激活后显示） ──
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 300),
            crossFadeState:
                _active ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: _CompassCard(
              magHeading: _magHeading,
              fusedYaw: _estimatedYaw,
            ),
            secondChild: const SizedBox.shrink(),
          ),
          if (_active) const SizedBox(height: 8),
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
  final double fusedDeg;

  const _StatusCard({
    required this.active,
    required this.gyroZ,
    required this.gyroX,
    required this.magDeg,
    required this.fusedDeg,
  });

  @override
  Widget build(BuildContext context) {
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
          _DataItem(label: '罗盘°', value: magDeg.toStringAsFixed(0), valueColor: Colors.amber),
          _DataItem(label: '融合°', value: fusedDeg.toStringAsFixed(0), valueColor: Colors.cyanAccent),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// 指南针可视化卡片
// ─────────────────────────────────────────────────────────
class _CompassCard extends StatelessWidget {
  final double magHeading;
  final double fusedYaw;

  const _CompassCard({required this.magHeading, required this.fusedYaw});

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
              painter: _CompassPainter(
                magHeading: magHeading,
                fusedYaw: fusedYaw,
              ),
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
                Row(
                  children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                            color: Colors.cyanAccent, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(
                      '融合估算 ${(fusedYaw * 180 / math.pi).toStringAsFixed(1)}°',
                      style:
                          const TextStyle(color: Colors.cyanAccent, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '互补滤波：α=0.95\n陀螺仪主导，罗盘修正漂移',
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
  final double fusedYaw;

  const _CompassPainter({required this.magHeading, required this.fusedYaw});

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
    _drawNeedle(canvas, center, r - 12, fusedYaw, Colors.cyanAccent, 1.8);
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
  bool shouldRepaint(_CompassPainter old) =>
      old.magHeading != magHeading || old.fusedYaw != fusedYaw;
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
// 鼠标按键（带触觉+视觉反馈，支持长按拖拽）
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
