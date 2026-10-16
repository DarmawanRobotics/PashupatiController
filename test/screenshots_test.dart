// Renders the app's screens with its real fonts at Retroid Pocket size and saves them as PNG in
// build/screenshots, for the user manual (Pashupati docs/manual). Off in normal test runs:
//   flutter test --dart-define=SCREENSHOTS=true test/screenshots_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_teleop/input/gamepad_input.dart';
import 'package:flutter_teleop/net/discovery.dart';
import 'package:flutter_teleop/net/teleop_client.dart';
import 'package:flutter_teleop/net/webrtc_video.dart';
import 'package:flutter_teleop/protocol/messages.dart';
import 'package:flutter_teleop/screens/connect_screen.dart';
import 'package:flutter_teleop/screens/drive_screen.dart';
import 'package:flutter_teleop/screens/patrol_screen.dart';
import 'package:flutter_teleop/screens/routes_screen.dart';
import 'package:flutter_teleop/screens/settings_screen.dart';
import 'package:flutter_teleop/settings.dart';
import 'package:flutter_teleop/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _enabled = bool.fromEnvironment('SCREENSHOTS');
final _frame = GlobalKey();

/// The robot commands the Genisom L1W offers on the action rail (its site.yaml).
const _l1wCommands = [
  'stand_up',
  'sit_down',
  'balance_stand_mode',
  'move_mode',
  'lock_mode',
  'slow_speed',
  'normal_speed',
  'fast_speed',
  'sdk_control_right',
  'emergency_stop',
];

/// A mall loop: 12 x 7 m with rounded corners, three inspection stops.
List<RoutePoint> _route() {
  final points = <RoutePoint>[];
  void line(double x0, double y0, double x1, double y1) {
    final n = (math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2)) / 0.25).round();
    for (var i = 0; i < n; i++) {
      points.add(RoutePoint(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n, 0));
    }
  }

  line(0, 0, 12, 0);
  line(12, 0, 12, 7);
  line(12, 7, 0, 7);
  line(0, 7, 0, 0);
  points.add(const RoutePoint(0, 0, 0));
  const stops = [Offset(6, 0), Offset(12, 3.5), Offset(6, 7)];
  return [
    for (final p in points)
      stops.any((s) => (s - Offset(p.x, p.y)).distance < 0.13) ? RoutePoint(p.x, p.y, 10) : p,
  ];
}

/// Shop fronts and the outer walls as the lidar sees them from the robot at (x, y, yaw).
Float32List _lidar(double x, double y, double yaw) {
  final walls = <Offset>[];
  void wall(double x0, double y0, double x1, double y1) {
    final n = (math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2)) / 0.12).round();
    for (var i = 0; i <= n; i++) {
      walls.add(Offset(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n));
    }
  }

  wall(-2, -2, 14, -2);
  wall(14, -2, 14, 9);
  wall(14, 9, -2, 9);
  wall(-2, 9, -2, -2);
  wall(2, 2, 10, 2);
  wall(10, 2, 10, 5);
  wall(10, 5, 2, 5);
  wall(2, 5, 2, 2);
  final c = math.cos(-yaw), s = math.sin(-yaw);
  final out = <double>[];
  for (final w in walls) {
    final dx = w.dx - x, dy = w.dy - y;
    if (dx * dx + dy * dy > 64) continue;
    out
      ..add(c * dx - s * dy)
      ..add(s * dx + c * dy)
      ..add(0.4);
  }
  return Float32List.fromList(out);
}

Map<String, dynamic> _state({
  String mode = 'auto',
  String nav = 'FOLLOWING',
  bool estop = false,
  bool recording = false,
}) => {
  'mode': mode,
  'nav': nav,
  'nav_msg': 'lap 1',
  'mission': 'lap 1',
  'localization': 'apriltag "base_map" (auto start)',
  'recording': recording,
  'estop': estop,
  'field': 'clear',
  'pose': [9.0, 0.05, 0.0],
  'battery': {'pct': 0.78, 'v': 50.2, 'a': -3.1, 'temp': 34.0},
  'health': {
    'ok': true,
    'issues': [],
    'cpu': 31.0,
    'gpu': 44.0,
    'ram': 47.0,
    'ram_used': 7.2,
    'ram_total': 15.3,
    'temp': 56.0,
  },
  'inspection': {
    'on': true,
    'state': 'running',
    'model': 'qwen3-vl:2b-instruct',
    'interval': 2,
    'count': 214,
    'reports': 3,
    'queue': 1,
    'queue_max': 50,
    'last': {'cat': 'none', 'ms': 1350, 'age': 2, 'source': 'periodic'},
  },
  'people': {'on': true, 'state': 'running', 'count': 2, 'ms': 18, 'backend': 'onnxruntime-cuda'},
  'speed': {'target': 0.4, 'min': 0.1, 'max': 0.6},
};

/// The robot's answers to the pages' own commands.
Future<CommandResult> _robot(
  String name, {
  Map<String, Object?> args = const {},
  String? label,
  bool quiet = false,
}) async {
  return switch (name) {
    'inspection_models' => const CommandResult(true, '', [
      {'name': 'qwen3-vl:2b-instruct', 'installed': true, 'active': true},
      {'name': 'moondream:latest', 'installed': true, 'active': false},
      {'name': 'ahmadwaqar/smolvlm2-2.2b-instruct:latest', 'installed': true, 'active': false},
    ]),
    'inspection_categories' => const CommandResult(true, '', [
      {
        'name': 'trash',
        'desc': 'any loose item lying on the floor that should not be there',
        'report': true,
        'builtin': true,
      },
      {'name': 'spill', 'desc': 'liquid, a wet patch or a puddle', 'report': true, 'builtin': true},
      {'name': 'stain', 'desc': 'a dry dirty mark or smear', 'report': false, 'builtin': true},
    ]),
    'list_routes' => const CommandResult(true, '', [
      '/home/robot/dev/Pashupati/map/2026-10-15/093012_path.csv',
      '/home/robot/dev/Pashupati/map/2026-10-15/141508_path.csv',
      '/home/robot/dev/Pashupati/map/2026-10-16/061744_path.csv',
    ]),
    _ => const CommandResult(true, ''),
  };
}

Future<Services> _services(WidgetTester tester, {String mainView = 'map'}) async {
  SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.withData({
    'language': 'en',
    'main_view': mainView,
    'token': 'demo',
  });
  final settings = (await tester.runAsync(AppSettings.load))!;
  final client = TeleopClient()
    ..welcome = Welcome.fromJson({
      'name': 'genisom-l1w-01',
      'commands': pashupatiCommands.toList(),
      'robot_commands': _l1wCommands,
      'limits': [1.0, 0.5, 1.5],
    })
    ..status = LinkStatus.connected
    ..rttMs = 18;
  final route = _route();
  client.routePoints.value = route;
  client.trail.addAll([
    for (final p in route.where((p) => p.y < 0.01 && p.x <= 9.0)) Offset(p.x, p.y + 0.03),
  ]);
  client.lidarPoints.value = _lidar(9.0, 0.05, 0.0);
  return Services(
    settings: settings,
    client: client,
    discovery: Discovery(),
    gamepad: GamepadInput()
      ..connected = true
      ..name = 'Retroid Pocket Controller',
    video: WebRtcVideo(),
  );
}

Future<void> _show(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(1334, 750); // Retroid Pocket in landscape
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _frame,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(), home: home),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _save(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(() async {
    final boundary = _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.5);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screenshots/$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    if (!_enabled) return;
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(family['family'] as String);
      for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
  });

  testWidgets('start screen', skip: !_enabled, (tester) async {
    final services = await _services(tester);
    await _show(tester, ConnectScreen(services: services));
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/images/logo.png'),
        tester.element(find.byType(ConnectScreen)),
      ),
    );
    await _save(tester, '01_start');
  });

  testWidgets('connection settings', skip: !_enabled, (tester) async {
    final services = await _services(tester);
    await _show(tester, SettingsScreen(services: services, admin: true));
    await _save(tester, '02_connection');
  });

  testWidgets('main screen: patrol in AUTO', skip: !_enabled, (tester) async {
    final services = await _services(tester);
    services.client.state = RobotState.fromJson(_state());
    await _show(tester, DriveScreen(services: services));
    await _save(tester, '03_main_patrol');
  });

  testWidgets('main screen: teaching a route in REMOTE', skip: !_enabled, (tester) async {
    final services = await _services(tester);
    services.client.state = RobotState.fromJson(
      _state(mode: 'remote', nav: 'NAV_INACTIVE', recording: true),
    );
    await _show(tester, DriveScreen(services: services));
    await _save(tester, '04_main_teach');
  });

  testWidgets('main screen: e-stop engaged', skip: !_enabled, (tester) async {
    final services = await _services(tester);
    services.client.state = RobotState.fromJson(_state(nav: 'EMERGENCY_STOP', estop: true));
    await _show(tester, DriveScreen(services: services));
    await _save(tester, '05_main_estop');
  });

  testWidgets('routes', skip: !_enabled, (tester) async {
    final services = await _services(tester);
    await _show(tester, RoutesScreen(services: services, onRun: _robot));
    await _save(tester, '06_routes');
  });

  testWidgets('inspection page and a new finding type', skip: !_enabled, (tester) async {
    final services = await _services(tester);
    services.client.state = RobotState.fromJson(_state());
    await _show(
      tester,
      PatrolScreen(client: services.client, language: 'en', onRun: _robot),
    );
    await _save(tester, '07_inspection');
    final add = find.byKey(const ValueKey('type-add'));
    await tester.scrollUntilVisible(add, 80, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    await _save(tester, '08_finding_types');
    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byKey(const ValueKey('type-name')), 'unattended_bag');
    await tester.enterText(
      find.byKey(const ValueKey('type-desc')),
      'a bag, backpack or suitcase standing alone on the floor',
    );
    await _save(tester, '09_add_type');
  });

  testWidgets('settings', skip: !_enabled, (tester) async {
    final services = await _services(tester);
    await _show(tester, SettingsScreen(services: services));
    await _save(tester, '10_settings');
  });
}
