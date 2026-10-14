import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../theme.dart';

/// Top-down view around the robot: lidar returns, the loaded route and its stops.
///
/// The robot sits low in the frame looking up (forward), so more of what is ahead is visible.
class LidarMap extends StatelessWidget {
  const LidarMap({
    super.key,
    required this.points,
    required this.route,
    required this.pose,
    required this.modeColor,
    this.range = 6,
  });

  final ValueListenable<Float32List?> points;
  final ValueListenable<List<RoutePoint>> route;
  final Pose? pose;
  final Color modeColor;

  /// Metres from the robot to the top edge.
  final double range;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Palette.glassHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Palette.line),
        ),
        child: ValueListenableBuilder<Float32List?>(
          valueListenable: points,
          builder: (context, cloud, _) => ValueListenableBuilder<List<RoutePoint>>(
            valueListenable: route,
            builder: (context, path, _) => CustomPaint(
              painter: _MapPainter(cloud, path, pose, modeColor, range),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter(this.cloud, this.route, this.pose, this.modeColor, this.range);

  final Float32List? cloud;
  final List<RoutePoint> route;
  final Pose? pose;
  final Color modeColor;
  final double range;

  @override
  void paint(Canvas canvas, Size size) {
    final robot = Offset(size.width / 2, size.height * 0.68);
    final scale = robot.dy / range;
    Offset toScreen(double x, double y) => Offset(robot.dx - y * scale, robot.dy - x * scale);

    final rings = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Palette.line;
    for (var r = 2.0; r <= range * 1.5; r += 2) {
      canvas.drawCircle(robot, r * scale, rings);
    }

    final pose = this.pose;
    if (pose != null && route.length > 1) {
      final c = math.cos(-pose.yaw), s = math.sin(-pose.yaw);
      Offset local(RoutePoint p) {
        final dx = p.x - pose.x, dy = p.y - pose.y;
        return toScreen(c * dx - s * dy, s * dx + c * dy);
      }

      final path = Path()..moveTo(local(route.first).dx, local(route.first).dy);
      for (final p in route.skip(1)) {
        final o = local(p);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Palette.auto.withValues(alpha: 0.75),
      );
      final stop = Paint()..color = Palette.auto;
      for (final p in route.where((p) => p.isStop)) {
        canvas.drawCircle(local(p), 3.5, stop);
      }
    }

    final cloud = this.cloud;
    if (cloud != null) {
      // obstacles only: drop the floor and the ceiling (z relative to base_link)
      final near = <double>[], mid = <double>[], far = <double>[];
      for (var i = 0; i + 2 < cloud.length; i += 3) {
        final x = cloud[i], y = cloud[i + 1], z = cloud[i + 2];
        if (z < -0.25 || z > 1.6) continue;
        final o = toScreen(x, y);
        if (o.dx < 0 || o.dy < 0 || o.dx > size.width || o.dy > size.height) continue;
        final d = math.sqrt(x * x + y * y);
        (d < 0.8 ? near : (d < 2.0 ? mid : far))
          ..add(o.dx)
          ..add(o.dy);
      }
      void dots(List<double> xy, Color color) {
        if (xy.isEmpty) return;
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(xy),
          Paint()
            ..color = color
            ..strokeWidth = 2.4
            ..strokeCap = StrokeCap.round,
        );
      }

      dots(far, Palette.text.withValues(alpha: 0.75));
      dots(mid, Palette.caution);
      dots(near, Palette.stop);
    }

    final body = Path()
      ..moveTo(robot.dx, robot.dy - 11)
      ..lineTo(robot.dx + 7, robot.dy + 7)
      ..lineTo(robot.dx, robot.dy + 3)
      ..lineTo(robot.dx - 7, robot.dy + 7)
      ..close();
    canvas.drawPath(body, Paint()..color = modeColor);
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.cloud != cloud ||
      old.route != route ||
      old.pose?.x != pose?.x ||
      old.pose?.y != pose?.y ||
      old.pose?.yaw != pose?.yaw ||
      old.modeColor != modeColor;
}
