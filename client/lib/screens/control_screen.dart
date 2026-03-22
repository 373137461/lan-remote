import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/udp_service.dart';
import 'touchpad_screen.dart';
import 'keyboard_screen.dart';
import 'connection_screen.dart';

/// 主控制界面：底部 Tab 切换触摸板（含空中飞鼠）、键盘两种模式
class ControlScreen extends StatefulWidget {
  final UdpService udpService;
  final String serverIp;

  const ControlScreen({
    super.key,
    required this.udpService,
    required this.serverIp,
  });

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  int _currentIndex = 0;
  late final List<Widget> _pages;
  StreamSubscription? _disconnectSub;
  StreamSubscription? _latencySub;
  StreamSubscription? _pingSentSub;
  int _latencyMs = -1;
  bool _pingSent = false;
  bool _pongReceived = false;

  @override
  void initState() {
    super.initState();
    // addPostFrameCallback 确保 iOS 渲染首帧后再调用，避免平台通道时序问题
    WidgetsBinding.instance.addPostFrameCallback((_) => WakelockPlus.enable());
    _pages = [
      TouchpadScreen(udpService: widget.udpService),
      KeyboardScreen(udpService: widget.udpService),
    ];

    // 订阅服务端断开事件
    _disconnectSub = widget.udpService.disconnectStream.listen((_) {
      if (mounted) _onServerDisconnected();
    });

    // 订阅网络延迟更新（pong 收到 → ✅ 绿色）
    _latencySub = widget.udpService.latencyStream.listen((ms) {
      if (mounted) {
        setState(() {
          _latencyMs = ms;
          _pongReceived = true;
          _pingSent = false;
        });
      }
    });

    // 订阅 ping 发出事件（⬆️ 绿色，✅ 黄色等待）
    _pingSentSub = widget.udpService.pingSentStream.listen((_) {
      if (mounted) {
        setState(() {
          _pingSent = true;
          _pongReceived = false;
        });
      }
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // 离开控制页面后恢复屏幕休眠
    _disconnectSub?.cancel();
    _latencySub?.cancel();
    _pingSentSub?.cancel();
    super.dispose();
  }

  void _onServerDisconnected() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ConnectionScreen(udpService: widget.udpService),
      ),
    );
  }

  Future<void> _disconnect() async {
    await widget.udpService.disconnect();
    if (!mounted) return;
    // autoConnect: false 避免回到连接页后再次自动重连
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ConnectionScreen(udpService: widget.udpService, autoConnect: false),
      ),
    );
  }

  /// 设备显示名：优先用主机名，否则用 IP
  String get _deviceLabel {
    final h = widget.udpService.serverHostname;
    return h.isNotEmpty ? h : widget.serverIp;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            _AppBarOsLogo(os: widget.udpService.serverOs),
            const SizedBox(width: 6),
            Text(_deviceLabel, style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 8),
            _LatencyBadge(latencyMs: _latencyMs),
            const SizedBox(width: 6),
            _HeartbeatDot(pingSent: _pingSent, pongReceived: _pongReceived),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: '断开连接',
            onPressed: _disconnect,
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.touch_app_outlined),
            selectedIcon: Icon(Icons.touch_app),
            label: '触摸板',
          ),
          NavigationDestination(
            icon: Icon(Icons.keyboard_outlined),
            selectedIcon: Icon(Icons.keyboard),
            label: '键盘',
          ),
        ],
      ),
    );
  }
}

/// AppBar 系统 Logo（与登录页 _OsLogo 样式一致，尺寸缩小适配标题栏）
class _AppBarOsLogo extends StatelessWidget {
  final int os;
  const _AppBarOsLogo({required this.os});

  @override
  Widget build(BuildContext context) {
    switch (os) {
      case 0:
        return SvgPicture.asset('assets/windows.svg', width: 18, height: 18,
            colorFilter: const ColorFilter.mode(Color(0xff01A6F0), BlendMode.srcIn));
      case 1:
        return SvgPicture.asset('assets/apple.svg', width: 18, height: 18,
            colorFilter: const ColorFilter.mode(Color(0xFFCCCCCC), BlendMode.srcIn));
      case 2:
        return SvgPicture.asset('assets/linux.svg', width: 18, height: 18);
      default:
        return const Icon(Icons.wifi, size: 18, color: Colors.greenAccent);
    }
  }
}

/// 心跳状态指示：⬆️ ping 发出，✅ pong 收到
class _HeartbeatDot extends StatelessWidget {
  final bool pingSent;
  final bool pongReceived;
  const _HeartbeatDot({required this.pingSent, required this.pongReceived});

  @override
  Widget build(BuildContext context) {
    final dimColor = Theme.of(context).colorScheme.onSurface.withAlpha(61);
    // ⬆️ 颜色：ping 已发 → 绿，否则灰
    final upColor = pingSent ? Colors.greenAccent : dimColor;
    // ✅ 颜色：pong 已收 → 绿，ping 已发未收 → 黄，否则灰
    final checkColor = pongReceived
        ? Colors.greenAccent
        : pingSent
            ? Colors.yellowAccent
            : dimColor;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.arrow_upward_rounded, size: 13, color: upColor),
        const SizedBox(width: 2),
        Icon(Icons.check_circle_rounded, size: 13, color: checkColor),
      ],
    );
  }
}

/// 网络延迟小标签，颜色随延迟变化
class _LatencyBadge extends StatelessWidget {
  final int latencyMs;
  const _LatencyBadge({required this.latencyMs});

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color color;

    if (latencyMs < 0) {
      label = '—';
      color = Theme.of(context).colorScheme.onSurface.withAlpha(61);
    } else if (latencyMs <= 50) {
      label = '${latencyMs}ms';
      color = Colors.greenAccent;
    } else if (latencyMs <= 150) {
      label = '${latencyMs}ms';
      color = Colors.yellowAccent;
    } else {
      label = '${latencyMs}ms';
      color = Colors.redAccent;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(120), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontFeatures: const []),
      ),
    );
  }
}
