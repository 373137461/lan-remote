import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/udp_service.dart';
import 'screens/connection_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const LanRemoteApp());
}

class LanRemoteApp extends StatelessWidget {
  const LanRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    final udpService = UdpService();
    return MaterialApp(
      title: '键鼠遥控器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D6CDF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1A1A2E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF16213E),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: ConnectionScreen(udpService: udpService),
    );
  }
}
