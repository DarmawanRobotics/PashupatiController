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
    if (name == 'inspection_categories') {
      return const CommandResult(true, '', [
        {'name': 'trash', 'desc': 'loose items', 'report': true, 'builtin': true},
        {'name': 'stain', 'desc': 'a dry mark', 'report': false, 'builtin': true},
      ]);
    }
    return const CommandResult(true, '');
  }
}

TeleopClient robotClient(Map<String, dynamic> state) => TeleopClient()
  ..welcome = Welcome.fromJson({
    'commands': [
      'inspection_set',
      'inspection_models',
      'inspection_categories',
      'people_set',
      'nav_speed',
    ],
  })
  ..state = RobotState.fromJson(state);

/// The switch of the inspection (left column) or of the person detection (right column).
Finder switchOf(String key) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Switch));

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
      'people': {
        'on': true,
        'state': 'running',
        'count': 3,
        'ms': 80,
        'backend': 'onnxruntime-cpu',
      },
      'speed': {'target': 0.4, 'min': 0.1, 'max': 0.6},
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    expect(find.text('Running'), findsOneWidget);
    expect(find.text('0.40 m/s'), findsOneWidget);
    expect(find.textContaining('Trash'), findsOneWidget);
    expect(find.text('3 in view · 80 ms · onnxruntime-cpu'), findsOneWidget);

    await tapInColumn(tester, switchOf('inspection-switch'));
    expect(robot.sent['inspection_set'], {'enabled': false});

    await tester.tap(switchOf('people-switch'));
    await tester.pumpAndSettle();
    expect(robot.sent['people_set'], {'enabled': false});

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

    await tester.ensureVisible(find.byType(Slider));
    await tester.pumpAndSettle();
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
    expect(tester.widget<Switch>(switchOf('inspection-switch')).onChanged, isNull);
    expect(tester.widget<Switch>(switchOf('people-switch')).onChanged, isNull);
    expect(find.textContaining('PEOPLE=true'), findsOneWidget);
  });

  testWidgets('the interval slider sets the seconds between frames; the queue shows', (
    tester,
  ) async {
    final client = robotClient({
      'inspection': {
        'on': true,
        'state': 'running',
        'model': 'moondream',
        'interval': 10,
        'queue': 3,
        'queue_max': 50,
        'last': {'cat': 'none', 'age': 2, 'waited': 14},
      },
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);
    expect(find.text('Queue: 3 of 50 frames waiting'), findsOneWidget);
    expect(find.textContaining('waited 14 s'), findsOneWidget);

    // further down the column, built once scrolled to
    final slider = find.byKey(const ValueKey('interval-slider'));
    await tester.scrollUntilVisible(slider, 80, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Every 10 s'), findsOneWidget);
    await tester.drag(slider, const Offset(60, 0));
    await tester.pumpAndSettle();
    final sent = robot.sent['inspection_set']!['interval'] as double;
    expect(sent, greaterThan(10.0));
    expect(const [15.0, 20.0, 30.0, 45.0, 60.0, 90.0, 120.0, 180.0, 300.0], contains(sent));
  });

  testWidgets('finding types: report one more, and add an own type with its description', (
    tester,
  ) async {
    final client = robotClient({
      'inspection': {'on': true, 'state': 'running', 'model': 'moondream', 'interval': 0},
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);
    final add = find.byKey(const ValueKey('type-add'));
    await tester.scrollUntilVisible(add, 80, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('a dry mark'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('type-stain')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(robot.sent['inspection_set'], {
      'categories': [
        {'name': 'trash', 'desc': '', 'report': true},
        {'name': 'stain', 'desc': '', 'report': true},
      ],
    });

    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('type-save')));
    await tester.pumpAndSettle();
    expect(find.text('Letters a-z, digits and _, starting with a letter'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('type-name')), 'Tas Tertinggal');
    await tester.enterText(find.byKey(const ValueKey('type-desc')), ' a bag  left alone ');
    await tester.tap(find.byKey(const ValueKey('type-save')));
    await tester.pumpAndSettle();
    final types = robot.sent['inspection_set']!['categories'] as List;
    expect(types.last, {'name': 'tas_tertinggal', 'desc': 'a bag left alone', 'report': true});
    expect(types, hasLength(3));
    expect(find.text('tas tertinggal'), findsOneWidget);
  });
}
