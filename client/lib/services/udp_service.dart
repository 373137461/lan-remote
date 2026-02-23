import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 连接错误类型
enum ConnectError { none, timeout, wrongPassword }

/// UDP 通信服务
class UdpService {
  static const int defaultPort = 8888;
  static const int syncTimeoutMs = 3000;
  static const int _pingIntervalMs = 15000;  // 15 秒发一次 ping
  static const int _checkIntervalMs = 5000;  // 5 秒检查一次超时
  static const int _pongTimeoutMs = 45000;   // 45 秒没收到 pong 则断开（允许漏 2 个 ping）

  RawDatagramSocket? _socket;
  InternetAddress? _targetIp;
  int _targetPort = defaultPort;

  /// 时间偏移量（毫秒），后续发包 timestamp = now + timeOffset
  int timeOffset = 0;

  /// 服务端 OS：0=Windows, 1=macOS, 2=Linux, -1=未知
  int serverOs = -1;

  /// 上次连接的错误原因
  ConnectError lastError = ConnectError.none;

  bool _connected = false;
  bool get isConnected => _connected;

  StreamSubscription? _socketSub;

  // ── 心跳 ──
  Timer? _pingTimer;
  Timer? _pongCheckTimer;
  int _lastPongMs = 0;   // 上次收到 pong 的时间戳
  int _pingSentTime = 0; // 上次发送 ping 的时间戳

  // ── 网络延迟 ──
  int latencyMs = -1;
  final _latencyController = StreamController<int>.broadcast();
  Stream<int> get latencyStream => _latencyController.stream;

  // ── 断开通知流 ──
  final _disconnectController = StreamController<void>.broadcast();
  Stream<void> get disconnectStream => _disconnectController.stream;

  /// 连接到指定 IP，可选密码
  Future<bool> connect(String ip, {int port = defaultPort, String password = ''}) async {
    await disconnect();
    lastError = ConnectError.none;
    serverOs = -1;

    try {
      _targetIp = InternetAddress(ip);
      _targetPort = port;
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.broadcastEnabled = false;

      final success = await _syncTime(password: password);
      _connected = success;
      if (success) _startHeartbeat();
      return success;
    } catch (_) {
      _connected = false;
      return false;
    }
  }

  Future<void> disconnect() async {
    _connected = false;
    _stopHeartbeat();
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    timeOffset = 0;
    latencyMs = -1;
    _latencyController.add(-1);
  }

  // ── 心跳管理 ──

  void _startHeartbeat() {
    _lastPongMs = DateTime.now().millisecondsSinceEpoch;
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(milliseconds: _pingIntervalMs),
      (_) => _sendPing(),
    );
    _pongCheckTimer?.cancel();
    _pongCheckTimer = Timer.periodic(
      const Duration(milliseconds: _checkIntervalMs),
      (_) {
        if (!_connected) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastPongMs > _pongTimeoutMs) {
          _onServerDisconnected();
        }
      },
    );
  }

  void _stopHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _pongCheckTimer?.cancel();
    _pongCheckTimer = null;
  }

  void _sendPing() {
    if (_socket == null || _targetIp == null || !_connected) return;
    try {
      // 新格式：[0x10][timestamp 8B]，服务端 echo 回来后可计算 RTT
      _pingSentTime = DateTime.now().millisecondsSinceEpoch;
      final packet = ByteData(9);
      packet.setUint8(0, 0x10);
      packet.setUint64(1, _pingSentTime, Endian.big);
      _socket!.send(packet.buffer.asUint8List(), _targetIp!, _targetPort);
    } catch (_) {}
  }

  void _onServerDisconnected() {
    _connected = false;
    _stopHeartbeat();
    _disconnectController.add(null);
  }

  /// 时间同步握手
  /// 请求: [0x00] + [pwd_len 1B] + [password UTF-8]
  /// 响应: [0x00] + [timestamp 8B] + [os 1B] + [auth 1B]
  Future<bool> _syncTime({String password = ''}) async {
    final completer = Completer<bool>();
    final sendTime = DateTime.now().millisecondsSinceEpoch;

    // 持久化 socket 监听器：处理所有来自服务端的包
    _socketSub = _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null || dg.data.isEmpty) return;

      final data = dg.data;
      final cmd = data[0];

      if (cmd == 0x00) {
        // 时间同步响应（仅在握手期间处理）
        if (!completer.isCompleted) {
          if (data.length >= 11) {
            final bd = ByteData.sublistView(data, 1, 9);
            final pcTime = bd.getUint64(0, Endian.big);
            final nowTime = DateTime.now().millisecondsSinceEpoch;
            final rtt = nowTime - sendTime;
            timeOffset = (pcTime.toInt() + rtt ~/ 2) - nowTime;
            serverOs = data[9];
            final auth = data[10];
            if (auth != 0x00) {
              lastError = ConnectError.wrongPassword;
              completer.complete(false);
              return;
            }
            completer.complete(true);
          } else if (data.length >= 9) {
            // 兼容旧服务端（无 OS/auth 字节）
            final bd = ByteData.sublistView(data, 1, 9);
            final pcTime = bd.getUint64(0, Endian.big);
            final nowTime = DateTime.now().millisecondsSinceEpoch;
            final rtt = nowTime - sendTime;
            timeOffset = (pcTime.toInt() + rtt ~/ 2) - nowTime;
            completer.complete(true);
          }
        }
      } else if (cmd == 0x10) {
        // Pong：刷新心跳时间戳
        _lastPongMs = DateTime.now().millisecondsSinceEpoch;
        // 新格式 pong（9字节）：服务端 echo 了发送时间戳，可计算 RTT
        if (data.length >= 9) {
          final sentTs = ByteData.sublistView(data, 1, 9).getUint64(0, Endian.big);
          final rtt = _lastPongMs - sentTs.toInt();
          if (rtt >= 0 && rtt < 5000) {
            latencyMs = rtt;
            _latencyController.add(rtt);
          }
        }
      }
    });

    // 构建握手包：[0x00] + [pwd_len 1B] + [password UTF-8]
    final pwdBytes = _encodeUtf8(password);
    final packet = Uint8List(2 + pwdBytes.length);
    packet[0] = 0x00;
    packet[1] = pwdBytes.length;
    for (int i = 0; i < pwdBytes.length; i++) {
      packet[2 + i] = pwdBytes[i];
    }
    _socket!.send(packet, _targetIp!, _targetPort);

    return completer.future.timeout(
      const Duration(milliseconds: syncTimeoutMs),
      onTimeout: () {
        lastError = ConnectError.timeout;
        return false;
      },
    );
  }

  /// 构建并发送标准控制包：[cmd 1B] + [timestamp 8B] + [payload]
  void sendCommand(int cmd, List<int> payload) {
    if (_socket == null || _targetIp == null || !_connected) return;
    final builder = BytesBuilder();
    builder.addByte(cmd);
    final ts = DateTime.now().millisecondsSinceEpoch + timeOffset;
    final tsData = ByteData(8)..setUint64(0, ts, Endian.big);
    builder.add(tsData.buffer.asUint8List());
    builder.add(payload);
    try {
      _socket!.send(builder.toBytes(), _targetIp!, _targetPort);
    } catch (_) {}
  }

  // ── 鼠标控制 ──

  void sendMouseMove(int dx, int dy) {
    final p = ByteData(4)
      ..setInt16(0, dx.clamp(-32768, 32767), Endian.big)
      ..setInt16(2, dy.clamp(-32768, 32767), Endian.big);
    sendCommand(0x01, p.buffer.asUint8List());
  }

  /// button: 0=左键, 1=右键, 2=中键
  void sendMouseClick(int button) => sendCommand(0x02, [button & 0xFF]);
  void sendMouseScroll(int scrollY) {
    final p = ByteData(2)..setInt16(0, scrollY.clamp(-32768, 32767), Endian.big);
    sendCommand(0x03, p.buffer.asUint8List());
  }

  /// 鼠标按下不松开（拖拽开始）
  void sendMouseDown(int button) => sendCommand(0x06, [button & 0xFF]);

  /// 松开鼠标键（拖拽结束）
  void sendMouseUp(int button) => sendCommand(0x07, [button & 0xFF]);

  /// 双击
  void sendMouseDoubleClick(int button) => sendCommand(0x08, [button & 0xFF]);

  // ── 键盘控制 ──

  void sendKeyTap(int keycode) => sendCommand(0x04, [keycode & 0xFF]);

  /// 剪贴板粘贴模式（服务端写剪贴板再触发 Cmd/Ctrl+V）
  void sendTextInput(String text) {
    final utf8Bytes = _encodeUtf8(text);
    final lenData = ByteData(2)..setUint16(0, utf8Bytes.length, Endian.big);
    sendCommand(0x05, [...lenData.buffer.asUint8List(), ...utf8Bytes]);
  }

  /// 逐字输入模式（服务端调用 TypeStr，适合不支持粘贴的场景）
  void sendTextInputDirect(String text) {
    final utf8Bytes = _encodeUtf8(text);
    final lenData = ByteData(2)..setUint16(0, utf8Bytes.length, Endian.big);
    sendCommand(0x09, [...lenData.buffer.asUint8List(), ...utf8Bytes]);
  }

  // ── 系统操作 ──
  // action: 0x01=锁屏, 0x02=睡眠, 0x03=关机, 0x04=重启
  //         0x05=切换应用, 0x06=截图
  void sendSysAction(int action) => sendCommand(0x0A, [action & 0xFF]);

  List<int> _encodeUtf8(String s) {
    final out = <int>[];
    for (final r in s.runes) {
      if (r < 0x80) {
        out.add(r);
      } else if (r < 0x800) {
        out.add(0xC0 | (r >> 6));
        out.add(0x80 | (r & 0x3F));
      } else if (r < 0x10000) {
        out.add(0xE0 | (r >> 12));
        out.add(0x80 | ((r >> 6) & 0x3F));
        out.add(0x80 | (r & 0x3F));
      } else {
        out.add(0xF0 | (r >> 18));
        out.add(0x80 | ((r >> 12) & 0x3F));
        out.add(0x80 | ((r >> 6) & 0x3F));
        out.add(0x80 | (r & 0x3F));
      }
    }
    return out;
  }
}
