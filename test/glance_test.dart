import 'package:flutter/material.dart';
import 'package:flutter_teleop/protocol/messages.dart';
import 'package:flutter_teleop/theme.dart';
import 'package:flutter_teleop/widgets/glance.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> show(WidgetTester tester, Map<String, dynamic> state, {bool showLoad = true}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          // as wide as the small view on a Retroid Pocket
          child: SizedBox(
            width: 180,
            child: GlancePanel(
              state: RobotState.fromJson(state),
              language: 'id',
              showLoad: showLoad,
            ),
          ),
        ),
      ),
    ),
  );
}

const _running = {'on': true, 'state': 'running', 'model': 'moondream'};

void main() {
  testWidgets('a clear floor, the people and the load at a glance', (tester) async {
    await show(tester, {
      'inspection': {
        ..._running,
        'last': {'cat': 'none', 'age': 3},
      },
      'people': {'on': true, 'state': 'running', 'count': 4},
      'health': {
        'ok': true,
        'cpu': 23.0,
        'gpu': 41.0,
        'ram': 33.0,
        'ram_used': 5.1,
        'ram_total': 15.3,
        'temp': 53.0,
      },
    });
    expect(find.text('Bersih · 3 dtk lalu'), findsOneWidget);
    expect(find.text('4 orang'), findsOneWidget);
    expect(find.text('CPU 23%  GPU 41%'), findsOneWidget);
    expect(find.text('RAM 5.1/15.3 GB  53°C'), findsOneWidget);
  });

  testWidgets('a finding stands out; off and no-GPU states read plainly', (tester) async {
    await show(tester, {
      'inspection': {
        ..._running,
        'last': {'cat': 'trash', 'reported': true, 'age': 75},
      },
      'people': {'on': false, 'state': 'off'},
      'health': {'ok': true, 'cpu': 95.0, 'ram': 40.0},
    });
    expect(find.text('Sampah · 1 mnt lalu'), findsOneWidget);
    expect(find.text('Orang: mati'), findsOneWidget);
    expect(find.text('CPU 95%  GPU –'), findsOneWidget);
    expect(find.text('RAM 40%'), findsOneWidget);

    await show(tester, {'health': {'ok': true, 'cpu': 10.0}}, showLoad: false);
    expect(find.byType(GlancePanel), findsOneWidget);
    expect(find.textContaining('CPU'), findsNothing);
  });

  testWidgets('nearly full memory stands out in red', (tester) async {
    await show(tester, {
      'health': {'ok': false, 'cpu': 20.0, 'ram': 98.7, 'ram_used': 15.1, 'ram_total': 15.3},
    });
    final text = tester.widget<Text>(find.text('RAM 15.1/15.3 GB'));
    expect(text.style?.color, Palette.stop);
  });

  testWidgets('without inspection, people or load figures nothing shows', (tester) async {
    await show(tester, {
      'health': {'ok': true, 'issues': []},
    });
    expect(find.byType(Text), findsNothing);
  });
}
