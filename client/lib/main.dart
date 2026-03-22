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

  static ThemeData _buildTheme(Brightness brightness) {
    const seed = Color(0xFF2D6CDF);
    final isDark = brightness == Brightness.dark;
    final surfaceColor = isDark ? const Color(0xFF16213E) : Colors.white;
    final scaffoldBg = isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF0F4FF);
    final fillColor = isDark ? const Color(0xFF0F1A2E) : const Color(0xFFE8EFFF);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
      ).copyWith(surface: surfaceColor),
      scaffoldBackgroundColor: scaffoldBg,
      appBarTheme: AppBarTheme(
        backgroundColor: surfaceColor,
        foregroundColor: isDark ? Colors.white : Colors.black87,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceColor,
        indicatorColor: seed.withAlpha(isDark ? 80 : 50),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fillColor,
        labelStyle: TextStyle(color: isDark ? Colors.white60 : Colors.black54),
        hintStyle: TextStyle(color: isDark ? Colors.white30 : Colors.black38),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2D6CDF), width: 2),
        ),
      ),
      dividerColor: isDark ? Colors.white10 : Colors.black12,
    );
  }

  @override
  Widget build(BuildContext context) {
    final udpService = UdpService();
    return MaterialApp(
      title: '键鼠遥控器',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: ConnectionScreen(udpService: udpService),
    );
  }
}
