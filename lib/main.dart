import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'input/gamepad_input.dart';
import 'net/discovery.dart';
import 'net/teleop_client.dart';
import 'net/webrtc_video.dart';
import 'screens/connect_screen.dart';
import 'settings.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final services = Services(
    settings: await AppSettings.load(),
    client: TeleopClient(),
    discovery: Discovery(),
    gamepad: GamepadInput()..start(),
    video: WebRtcVideo(),
  );
  runApp(TeleopApp(services: services));
}

class TeleopApp extends StatelessWidget {
  const TeleopApp({super.key, required this.services});

  final Services services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pashupati Teleop',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ConnectScreen(services: services),
    );
  }
}
