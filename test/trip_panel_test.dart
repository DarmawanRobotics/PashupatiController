import 'package:flutter/material.dart';
import 'package:flutter_teleop/protocol/messages.dart';
import 'package:flutter_teleop/theme.dart';
import 'package:flutter_teleop/widgets/trip_panel.dart';
import 'package:flutter_test/flutter_test.dart';

const _trip = TripStatus(
  distance: 1284.6,
  movingSeconds: 3412,
  speed: 0.38,
  average: 0.36,
  top: 0.61,
);

Future<void> show(WidgetTester tester, TripStatus trip, {VoidCallback? onReset}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          // as wide as the small view on a Retroid Pocket
          child: SizedBox(
            width: 180,
            child: TripPanel(trip: trip, language: 'id', onReset: onReset),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('distance, moving time and the speeds of the robot', (tester) async {
    await show(tester, _trip, onReset: () {});
    expect(find.text('1.28 km · jalan 56:52'), findsOneWidget);
    expect(find.text('Sekarang 0.38 m/s'), findsOneWidget);
    expect(find.text('Rata² 0.36 · maks 0.61 m/s'), findsOneWidget);
    expect(find.text('Tahan untuk nol-kan'), findsOneWidget);
  });

  testWidgets('holding the panel asks the robot to reset; a tap does not', (tester) async {
    var resets = 0;
    await show(tester, _trip, onReset: () => resets++);
    await tester.tap(find.byKey(const ValueKey('trip')));
    expect(resets, 0);
    await tester.longPress(find.byKey(const ValueKey('trip')));
    expect(resets, 1);
  });

  testWidgets('a robot that cannot reset shows no hint', (tester) async {
    const zero = TripStatus(distance: 0, movingSeconds: 0, speed: 0, average: 0, top: 0);
    await show(tester, zero);
    expect(find.text('0.0 m · jalan 0:00'), findsOneWidget);
    expect(find.text('Tahan untuk nol-kan'), findsNothing);
  });
}
