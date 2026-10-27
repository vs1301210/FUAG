import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/menu_screen.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Erro ao listar câmeras disponíveis: $e');
  }
  runApp(const MobileControllerApp());
}

class MobileControllerApp extends StatelessWidget {
  const MobileControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Controle de Acessibilidade IA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E0E12),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00FF66),
          secondary: Color(0xFF00D4FF),
          surface: Color(0xFF16161E),
        ),
      ),
      home: MenuScreen(cameras: cameras),
    );
  }
}
