import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/udp_service.dart';
import 'control_screen.dart';

class ConnectionScreen extends StatefulWidget {
  final UdpService udpService;
  /// false = 只填充上次凭据但不自动连接（手动断开时使用，避免循环）
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
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '8888');
  final _pwdController = TextEditingController();
  bool _pwdVisible = false;
  bool _connecting = false;
  String _statusMsg = '';
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _loadAndAutoConnect();
  }

  Future<void> _loadAndAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('last_ip') ?? '';
    final port = prefs.getString('last_port') ?? '8888';
    final pwd = prefs.getString('last_pwd') ?? '';

    if (!mounted) return;
    _ipController.text = ip;
    _portController.text = port.isEmpty ? '8888' : port;
    _pwdController.text = pwd;

    if (ip.isEmpty || !widget.autoConnect) {
      setState(() => _statusMsg = ip.isEmpty ? '请输入被控端 IP 地址' : '');
      return;
    }

    // 有上次记录且允许自动连接 → 自动尝试
    setState(() {
      _connecting = true;
      _statusMsg = '正在自动连接 $ip...';
      _isError = false;
    });

    final success = await widget.udpService.connect(
      ip,
      port: int.tryParse(port) ?? 8888,
      password: pwd,
    );

    if (!mounted) return;

    if (success) {
      _navigateToControl(ip);
    } else {
      final errMsg = widget.udpService.lastError == ConnectError.wrongPassword
          ? '自动连接失败：密码错误'
          : '自动连接失败，请确认被控端已运行';
      setState(() {
        _connecting = false;
        _statusMsg = errMsg;
        _isError = true;
      });
    }
  }

  Future<void> _connect() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 8888;
    final pwd = _pwdController.text;

    if (ip.isEmpty) {
      setState(() { _statusMsg = '请输入 IP 地址'; _isError = true; });
      return;
    }

    setState(() { _connecting = true; _statusMsg = '正在连接并同步时间...'; _isError = false; });

    final success = await widget.udpService.connect(ip, port: port, password: pwd);

    if (!mounted) return;

    if (success) {
      // 连接成功后保存所有凭据
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_ip', ip);
      await prefs.setString('last_port', _portController.text.trim());
      await prefs.setString('last_pwd', pwd);
      if (!mounted) return;
      _navigateToControl(ip);
    } else {
      final errMsg = widget.udpService.lastError == ConnectError.wrongPassword
          ? '密码错误，请检查后重试'
          : '连接超时，请检查 IP 和被控端是否运行';
      setState(() { _connecting = false; _statusMsg = errMsg; _isError = true; });
    }
  }

  void _navigateToControl(String ip) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ControlScreen(udpService: widget.udpService, serverIp: ip),
      ),
    );
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _pwdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              const _AppLogo(),
              const SizedBox(height: 20),
              const Text(
                '局域网键鼠遥控器',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                '主控端 (iOS)',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white54),
              ),
              const SizedBox(height: 48),
              TextField(
                controller: _ipController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('被控端 IP 地址', '例如：192.168.1.100'),
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('端口', '默认 8888'),
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pwdController,
                obscureText: !_pwdVisible,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('密码', '被控端未设密码则留空').copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(
                      _pwdVisible ? Icons.visibility_off : Icons.visibility,
                      color: Colors.white38,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _pwdVisible = !_pwdVisible),
                  ),
                ),
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: _connecting ? null : _connect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2D6CDF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _connecting
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('连接并同步时间', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 20),
              if (_statusMsg.isNotEmpty)
                Text(
                  _statusMsg,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _isError ? Colors.redAccent : Colors.white54,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, String hint) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: Colors.white60),
      hintStyle: const TextStyle(color: Colors.white30),
      filled: true,
      fillColor: const Color(0xFF16213E),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF2D6CDF), width: 2),
      ),
    );
  }
}

/// 应用 Logo：渐变圆圈 + 键盘/鼠标双图标
class _AppLogo extends StatelessWidget {
  const _AppLogo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 100,
        height: 100,
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
              spreadRadius: 4,
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 键盘图标（偏上偏左）
            Positioned(
              top: 22,
              left: 18,
              child: Icon(Icons.keyboard, size: 36, color: Colors.white.withAlpha(230)),
            ),
            // 鼠标图标（偏下偏右，小一些）
            Positioned(
              bottom: 16,
              right: 16,
              child: Icon(Icons.mouse, size: 26, color: Colors.white.withAlpha(180)),
            ),
          ],
        ),
      ),
    );
  }
}
