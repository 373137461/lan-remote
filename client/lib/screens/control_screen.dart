import 'dart:async';
import 'package:flutter/material.dart';
import '../services/udp_service.dart';
import 'touchpad_screen.dart';
import 'gyro_screen.dart';
import 'keyboard_screen.dart';
import 'connection_screen.dart';

/// 主控制界面：底部 Tab 切换触摸板、空中飞鼠、键盘三种模式
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

  @override
  void initState() {
    super.initState();
    _pages = [
      TouchpadScreen(udpService: widget.udpService),
      GyroScreen(udpService: widget.udpService),
      KeyboardScreen(udpService: widget.udpService),
    ];

    // 订阅服务端断开事件
    _disconnectSub = widget.udpService.disconnectStream.listen((_) {
      if (mounted) _onServerDisconnected();
    });
  }

  @override
  void dispose() {
    _disconnectSub?.cancel();
    super.dispose();
  }

  void _onServerDisconnected() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ConnectionScreen(udpService: widget.udpService),
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('与服务端失去连接，已自动断开'),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 3),
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

  /// 从 serverOs 获取友好的操作系统名称
  String get _osLabel {
    switch (widget.udpService.serverOs) {
      case 0: return 'Windows';
      case 1: return 'macOS';
      case 2: return 'Linux';
      default: return widget.serverIp;
    }
  }

  IconData get _osIcon {
    switch (widget.udpService.serverOs) {
      case 0: return Icons.window;
      case 1: return Icons.laptop_mac;
      case 2: return Icons.computer;
      default: return Icons.wifi;
    }
  }

  Color get _osColor {
    switch (widget.udpService.serverOs) {
      case 0: return Colors.lightBlueAccent;
      case 1: return Colors.white70;
      case 2: return Colors.orangeAccent;
      default: return Colors.greenAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(_osIcon, size: 16, color: _osColor),
            const SizedBox(width: 6),
            Text(
              _osLabel,
              style: const TextStyle(fontSize: 15),
            ),
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
        backgroundColor: const Color(0xFF16213E),
        indicatorColor: const Color(0xFF2D6CDF),
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.touch_app_outlined),
            selectedIcon: Icon(Icons.touch_app),
            label: '触摸板',
          ),
          NavigationDestination(
            icon: Icon(Icons.screen_rotation_outlined),
            selectedIcon: Icon(Icons.screen_rotation),
            label: '空中飞鼠',
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
