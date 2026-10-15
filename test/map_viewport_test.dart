import 'dart:math' as math;

import 'package:flutter_teleop/widgets/map_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('angles wrap into (-pi, pi]', () {
    expect(wrapAngle(0), 0);
    expect(wrapAngle(3 * math.pi / 2), closeTo(-math.pi / 2, 1e-9));
    expect(wrapAngle(-5 * math.pi / 2), closeTo(-math.pi / 2, 1e-9));
  });

  test('heading up turns the map so the robot drives up the screen', () {
    final view = MapViewport();
    expect(view.rotationFor(1.0), 0); // north up by default
    view.trackHeading();
    expect(view.mode, MapMode.follow);
    expect(view.headingUp, isTrue);
    expect(view.rotationFor(0), closeTo(math.pi / 2, 1e-9)); // facing map +x: +x points up
    expect(view.rotationFor(math.pi / 2), closeTo(0, 1e-9));
    expect(view.rotationFor(null), 0); // not localized: nothing to turn with

    view.zoom(20); // a pinch keeps it
    expect(view.headingUp, isTrue);
    view.zoom(20, rotation: 0.3); // a twist takes over
    expect(view.headingUp, isFalse);
    expect(view.rotationFor(1.0), closeTo(0.3, 1e-9));
  });

  test('a turned map keeps its turn until north up; the whole route ends heading up', () {
    final view = MapViewport()..moveTo(const Offset(3, 4), 30, 2 * math.pi + 0.5);
    expect(view.mode, MapMode.free);
    expect(view.rotation, closeTo(0.5, 1e-9));
    view.follow();
    expect(view.rotation, closeTo(0.5, 1e-9));
    view.northUp();
    expect(view.rotation, 0);
    expect(view.mode, MapMode.follow);
    view
      ..trackHeading()
      ..fit();
    expect(view.headingUp, isFalse);
    expect(view.mode, MapMode.fit);
  });
}
