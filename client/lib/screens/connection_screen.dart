import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/udp_service.dart';
import 'control_screen.dart';

// ── 数据模型 ─────────────────────────────────────────────────────────────────

class DeviceEntry {
  final String ip;
  final String port;
  final String password;
  final int os; // -1=未知, 0=Windows, 1=macOS, 2=Linux
  final String? hostname;
  final List<String> macAddresses;

  const DeviceEntry({
    required this.ip,
    this.port = '8888',
    this.password = '',
    this.os = -1,
    this.hostname,
    this.macAddresses = const [],
  });

  /// 显示名称：连接成功后显示 hostname，否则显示 IP
  String get displayName => (hostname != null && hostname!.isNotEmpty) ? hostname! : ip;

  DeviceEntry copyWith({
    String? ip,
    String? port,
    String? password,
    int? os,
    String? hostname,
    List<String>? macAddresses,
  }) =>
      DeviceEntry(
        ip: ip ?? this.ip,
        port: port ?? this.port,
        password: password ?? this.password,
        os: os ?? this.os,
        hostname: hostname ?? this.hostname,
        macAddresses: macAddresses ?? this.macAddresses,
      );

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'port': port,
        'password': password,
        'os': os,
        'hostname': hostname,
        'macAddresses': macAddresses,
      };

  factory DeviceEntry.fromJson(Map<String, dynamic> j) => DeviceEntry(
        ip: j['ip'] as String? ?? '',
        port: j['port'] as String? ?? '8888',
        password: j['password'] as String? ?? '',
        os: j['os'] as int? ?? -1,
        hostname: j['hostname'] as String?,
        macAddresses: (j['macAddresses'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [],
      );
}

// ── 主页面 ───────────────────────────────────────────────────────────────────

class ConnectionScreen extends StatefulWidget {
  final UdpService udpService;
  final bool autoConnect;
  const ConnectionScreen({
    super.key,
    required this.udpService,
    this.autoConnect = true,
  });

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  List<DeviceEntry> _devices = [];
  String? _connectingIp;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    List<DeviceEntry> devices = [];

    final json = prefs.getString('device_history');
    if (json != null) {
      try {
        final list = jsonDecode(json) as List<dynamic>;
        devices = list
            .map((e) => DeviceEntry.fromJson(e as Map<String, dynamic>))
            .where((d) => d.ip.isNotEmpty)
            .toList();
      } catch (_) {}
    }

    // 迁移旧格式
    if (devices.isEmpty) {
      final oldIp = prefs.getString('last_ip') ?? '';
      if (oldIp.isNotEmpty) {
        devices = [
          DeviceEntry(
            ip: oldIp,
            port: prefs.getString('last_port') ?? '8888',
            password: prefs.getString('last_pwd') ?? '',
          ),
        ];
        await _persist(devices);
        await prefs.remove('last_ip');
        await prefs.remove('last_port');
        await prefs.remove('last_pwd');
      }
    }

    if (!mounted) return;
    setState(() {
      _devices = devices;
      _loaded = true;
    });

    if (devices.isNotEmpty && widget.autoConnect) {
      _connectDevice(devices.first);
    }
  }

  Future<void> _persist(List<DeviceEntry> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'device_history', jsonEncode(list.map((d) => d.toJson()).toList()));
  }

  Future<void> _connectDevice(DeviceEntry device) async {
    if (_connectingIp != null) return;
    setState(() => _connectingIp = device.ip);

    final success = await widget.udpService.connect(
      device.ip,
      port: int.tryParse(device.port) ?? 8888,
      password: device.password,
    );

    if (!mounted) return;

    if (success) {
      final updated = device.copyWith(
        os: widget.udpService.serverOs,
        hostname: widget.udpService.serverHostname.isEmpty
            ? null
            : widget.udpService.serverHostname,
        macAddresses: widget.udpService.serverMacAddresses,
      );
      final newList = [updated, ..._devices.where((d) => d.ip != device.ip)];
      setState(() {
        _devices = newList;
        _connectingIp = null;
      });
      await _persist(newList);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) =>
            ControlScreen(udpService: widget.udpService, serverIp: device.ip),
      ));
    } else {
      setState(() => _connectingIp = null);
      if (!mounted) return;
      if (widget.udpService.lastError == ConnectError.wrongPassword) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('密码错误，请检查后重试'),
          backgroundColor: Colors.red[800],
          behavior: SnackBarBehavior.floating,
        ));
      } else if (device.macAddresses.isNotEmpty) {
        _showWolDialog(device);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('连接超时，请确认被控端已运行'),
          backgroundColor: Colors.red[800],
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  void _showWolDialog(DeviceEntry device) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('连接超时',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
          '设备可能已休眠或关机。\n是否向已知 MAC 地址发送网络唤醒（WoL）魔术包？',
          style: TextStyle(color: Colors.white60, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _sendWol(device.macAddresses);
            },
            child: const Text('发送唤醒',
                style: TextStyle(color: Color(0xFF2D6CDF))),
          ),
        ],
      ),
    );
  }

  Future<void> _sendWol(List<String> macAddresses) async {
    int sent = 0;
    for (final macStr in macAddresses) {
      final parts = macStr.split(':');
      if (parts.length != 6) continue;
      try {
        final mac = parts.map((p) => int.parse(p, radix: 16)).toList();
        final packet = Uint8List(102);
        for (int i = 0; i < 6; i++) {
          packet[i] = 0xFF;
        }
        for (int rep = 0; rep < 16; rep++) {
          for (int b = 0; b < 6; b++) {
            packet[6 + rep * 6 + b] = mac[b];
          }
        }
        final socket =
            await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        socket.broadcastEnabled = true;
        socket.send(packet, InternetAddress('255.255.255.255'), 9);
        await Future.delayed(const Duration(milliseconds: 50));
        socket.close();
        sent++;
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent > 0
          ? '已向 $sent 个 MAC 地址发送唤醒包，稍后再试连接'
          : '发送唤醒包失败'),
      backgroundColor:
          sent > 0 ? Colors.green[800] : Colors.red[800],
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _deleteDevice(DeviceEntry device) async {
    final newList = _devices.where((d) => d.ip != device.ip).toList();
    setState(() => _devices = newList);
    await _persist(newList);
  }

  Future<void> _addAndConnect(DeviceEntry device) async {
    final newList = [device, ..._devices.where((d) => d.ip != device.ip)];
    setState(() => _devices = newList);
    await _persist(newList);
    await _connectDevice(device);
  }

  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16213E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _AddDeviceSheet(
        onConnect: (device) async {
          Navigator.pop(context);
          await _addAndConnect(device);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_devices.isEmpty) {
      return _NoHistoryScreen(onConnect: _addAndConnect);
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 36),
            const _AppLogo(),
            const SizedBox(height: 14),
            const Text(
              '局域网键鼠遥控器',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 4),
            const Text('选择被控设备',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 40),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Wrap(
                  spacing: 28,
                  runSpacing: 28,
                  alignment: WrapAlignment.center,
                  children: _devices
                      .map((d) => _DeviceCard(
                            device: d,
                            isConnecting: _connectingIp == d.ip,
                            enabled: _connectingIp == null,
                            onTap: () => _connectDevice(d),
                            onDelete: () => _deleteDevice(d),
                          ))
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _connectingIp == null ? _showAddSheet : null,
              icon: const Icon(Icons.add, size: 15),
              label: const Text('新增地址'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white30,
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ── 设备卡片 ─────────────────────────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  final DeviceEntry device;
  final bool isConnecting;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _DeviceCard({
    required this.device,
    required this.isConnecting,
    required this.enabled,
    required this.onTap,
    required this.onDelete,
  });

  // 卡片固定宽度，名称严格单行截断（原 80，+20%）
  static const double _cardW = 96.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? () => _confirmDelete(context) : null,
      child: SizedBox(
        width: _cardW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _avatar(),
            const SizedBox(height: 8),
            SizedBox(
              width: _cardW,
              child: Text(
                device.displayName,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: enabled ? Colors.white70 : Colors.white30,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 86,
      height: 86,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF16213E),
        border: Border.all(
          color: isConnecting
              ? const Color(0xFF2D6CDF)
              : enabled
                  ? const Color(0xFF2A2A4A)
                  : const Color(0xFF1E1E35),
          width: 2,
        ),
        boxShadow: isConnecting
            ? [
                BoxShadow(
                    color: const Color(0xFF2D6CDF).withAlpha(90),
                    blurRadius: 14,
                    spreadRadius: 2)
              ]
            : null,
      ),
      child: isConnecting
          ? const Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Color(0xFF2D6CDF)),
              ),
            )
          : Center(child: _OsLogo(os: device.os)),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除记录',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text('移除 ${device.ip}？',
            style: const TextStyle(color: Colors.white60, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onDelete();
            },
            child: const Text('删除',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

// ── OS Logo 组件 ─────────────────────────────────────────────────────────────

class _OsLogo extends StatelessWidget {
  final int os;
  const _OsLogo({required this.os});

  @override
  Widget build(BuildContext context) {
    switch (os) {
      case 0: // Windows：蓝色旗帜图标
        return SvgPicture.asset(
          'assets/windows.svg',
          width: 36,
          height: 36,
        );
      case 1: // macOS：白色苹果轮廓
        return SvgPicture.asset(
          'assets/apple.svg',
          width: 34,
          height: 34,
          colorFilter: const ColorFilter.mode(
            Color(0xFFCCCCCC),
            BlendMode.srcIn,
          ),
        );
      case 2: // Linux：彩色 Tux 企鹅
        return SvgPicture.asset(
          'assets/linux.svg',
          width: 36,
          height: 36,
        );
      default: // 未知：通用 PC 图标
        return const Icon(
          Icons.computer_outlined,
          size: 36,
          color: Color(0xFF666688),
        );
    }
  }
}

// ── 无历史：直接显示表单 ──────────────────────────────────────────────────────

class _NoHistoryScreen extends StatelessWidget {
  final Future<void> Function(DeviceEntry) onConnect;
  const _NoHistoryScreen({required this.onConnect});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              const _AppLogo(),
              const SizedBox(height: 16),
              const Text(
                '局域网键鼠遥控器',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 4),
              const Text('主控端 (iOS)',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.white38)),
              const SizedBox(height: 44),
              _AddDeviceForm(onConnect: onConnect),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 新增地址底部弹窗 ──────────────────────────────────────────────────────────

class _AddDeviceSheet extends StatelessWidget {
  final Future<void> Function(DeviceEntry) onConnect;
  const _AddDeviceSheet({required this.onConnect});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('新增设备',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon:
                    const Icon(Icons.close, color: Colors.white38, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _AddDeviceForm(onConnect: onConnect),
        ],
      ),
    );
  }
}

// ── 新增设备表单（无历史 & 底部弹窗共用） ────────────────────────────────────

class _AddDeviceForm extends StatefulWidget {
  final Future<void> Function(DeviceEntry) onConnect;
  const _AddDeviceForm({required this.onConnect});

  @override
  State<_AddDeviceForm> createState() => _AddDeviceFormState();
}

class _AddDeviceFormState extends State<_AddDeviceForm> {
  final _ipCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '8888');
  final _pwdCtrl = TextEditingController();
  bool _pwdVisible = false;
  bool _connecting = false;

  @override
  void dispose() {
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请输入 IP 地址'),
          behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _connecting = true);
    await widget.onConnect(DeviceEntry(
      ip: ip,
      port: _portCtrl.text.trim().isEmpty ? '8888' : _portCtrl.text.trim(),
      password: _pwdCtrl.text,
    ));
    if (mounted) setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ipCtrl,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white),
          decoration: _deco('被控端 IP 地址', '例如：192.168.1.100'),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _portCtrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white),
          decoration: _deco('端口', '默认 8888'),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwdCtrl,
          obscureText: !_pwdVisible,
          style: const TextStyle(color: Colors.white),
          decoration: _deco('密码', '被控端未设密码则留空').copyWith(
            suffixIcon: IconButton(
              icon: Icon(
                  _pwdVisible ? Icons.visibility_off : Icons.visibility,
                  color: Colors.white38,
                  size: 20),
              onPressed: () =>
                  setState(() => _pwdVisible = !_pwdVisible),
            ),
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _connecting ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2D6CDF),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF1A3D8A),
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: _connecting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('连接并同步时间',
                  style: TextStyle(fontSize: 15)),
        ),
      ],
    );
  }

  InputDecoration _deco(String label, String hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white60),
        hintStyle: const TextStyle(color: Colors.white30),
        filled: true,
        fillColor: const Color(0xFF1A1A2E),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: Color(0xFF2D6CDF), width: 2),
        ),
      );
}

// ── App Logo ─────────────────────────────────────────────────────────────────

class _AppLogo extends StatelessWidget {
  const _AppLogo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
            colors: [Color(0xFF3D7EEF), Color(0xFF1A2D6E)],
            center: Alignment.topLeft,
            radius: 1.4,
          ),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFF2D6CDF).withAlpha(100),
                blurRadius: 24,
                spreadRadius: 4),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 20,
              left: 16,
              child: Icon(Icons.keyboard,
                  size: 32, color: Colors.white.withAlpha(230)),
            ),
            Positioned(
              bottom: 14,
              right: 14,
              child: Icon(Icons.mouse,
                  size: 22, color: Colors.white.withAlpha(180)),
            ),
          ],
        ),
      ),
    );
  }
}
