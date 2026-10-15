import 'package:flutter/material.dart';
import 'package:flutter_teleop/net/teleop_client.dart';
import 'package:flutter_teleop/protocol/messages.dart';
import 'package:flutter_teleop/screens/patrol_screen.dart';
import 'package:flutter_teleop/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// The robot's answers to the page's commands, and every command the page sent.
class FakeRobot {
  final sent = <String, Map<String, Object?>>{};

  Future<CommandResult> run(
    String name, {
    Map<String, Object?> args = const {},
    String? label,
    bool quiet = false,
  }) async {
    sent[name] = args;
    if (name == 'inspection_models') {
      return const CommandResult(true, '', [
        {'name': 'qwen3-vl:2b-instruct', 'installed': true, 'active': true},
        {'name': 'moondream:latest', 'installed': true, 'active': false},
        {'name': 'ahmadwaqar/smolvlm2-2.2b-instruct:latest', 'installed': false, 'active': false},
      ]);
    }
    return const CommandResult(true, '');
  }
}

TeleopClient robotClient(Map<String, dynamic> state) => TeleopClient()
  ..welcome = Welcome.fromJson({
    'commands': ['inspection_set', 'inspection_models', 'nav_speed'],
  })
  ..state = RobotState.fromJson(state);

/// Scrolls the inspection column until [finder] shows, then taps it.
Future<void> tapInColumn(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 80, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<FakeRobot> openPage(WidgetTester tester, TeleopClient client) async {
  // a Retroid Pocket in landscape
  tester.view.physicalSize = const Size(1334, 750);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final robot = FakeRobot();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: PatrolScreen(client: client, language: 'en', onRun: robot.run),
    ),
  );
  await tester.pumpAndSettle();
  return robot;
}

void main() {
  testWidgets('shows the inspection and switches it, its model and the patrol speed', (
    tester,
  ) async {
    final client = robotClient({
      'inspection': {
        'on': true,
        'state': 'running',
        'model': 'qwen3-vl:2b-instruct',
        'interval': 0,
        'count': 12,
        'reports': 1,
        'last': {'cat': 'trash', 'reported': true, 'ms': 1800, 'age': 3},
      },
      'speed': {'target': 0.4, 'min': 0.1, 'max': 0.6},
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    expect(find.text('Running'), findsOneWidget);
    expect(find.text('0.40 m/s'), findsOneWidget);
    expect(find.textContaining('Trash'), findsOneWidget);

    await tapInColumn(tester, find.byType(Switch));
    expect(robot.sent['inspection_set'], {'enabled': false});

    await tapInColumn(tester, find.text('Stop points'));
    expect(robot.sent['inspection_set'], {'interval': -1.0});

    // the model in use is marked; tap another one to switch
    final column = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('In use'), 80, scrollable: column);
    expect(find.text('In use'), findsOneWidget);
    await tapInColumn(tester, find.text('moondream:latest'));
    expect(robot.sent['inspection_set'], {'model': 'moondream:latest'});
    await tester.scrollUntilVisible(
      find.textContaining('ollama pull ahmadwaqar'),
      80,
      scrollable: column,
    );
    expect(find.textContaining('ollama pull ahmadwaqar'), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pumpAndSettle();
    final speed = robot.sent['nav_speed']!['speed']! as double;
    expect(speed, greaterThan(0.4));
    expect(speed, lessThanOrEqualTo(0.6));
  });

  testWidgets('without inspection or navigation on the robot it says so', (tester) async {
    final client = robotClient({});
    addTearDown(client.dispose);
    await openPage(tester, client);
    expect(find.text('Not running'), findsOneWidget);
    expect(find.textContaining('INSPECTION=true'), findsOneWidget);
    expect(find.textContaining('Navigation is not running'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
  });

  testWidgets('the interval pace offers the seconds between inspections', (tester) async {
    final client = robotClient({
      'inspection': {'on': true, 'state': 'running', 'model': 'moondream', 'interval': 10},
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);
    await tapInColumn(tester, find.text('30 s'));
    expect(robot.sent['inspection_set'], {'interval': 30.0});
  });
}
