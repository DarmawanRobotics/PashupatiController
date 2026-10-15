import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../theme.dart';

/// Top-down map in the map frame: the loaded route with its waypoints and stop points, where the
/// robot has been, the lidar returns and the robot itself.
///
/// [follow] keeps a few metres around the robot; otherwise the route and the trail stay in view.
/// Without a pose (not localized) it falls back to the lidar around the robot.
class MapView extends StatelessWidget {
  const MapView({
    super.key,
    required this.points,
    required this.route,
    required this.trail,
    required this.pose,
    required this.modeColor,
    required this.lidar,
    required this.follow,
    required this.notLocalizedText,
    this.marks = const [],
    this.compact = false,
  });

  final ValueListenable<Float32List?> points;
  final ValueListenable<List<RoutePoint>> route;
  final List<Offset> trail;

  /// Stop points marked in the route being recorded (not in the route stream yet).
  final List<Offset> marks;
  final Pose? pose;
  final Color modeColor;
  final bool lidar;
  final bool follow;
  final String notLocalizedText;

  /// Small box: thinner lines, no labels.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Float32List?>(
      valueListenable: points,
      builder: (context, cloud, _) => ValueListenableBuilder<List<RoutePoint>>(
        valueListenable: route,
        builder: (context, path, _) => Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _MapPainter(
                cloud: lidar ? cloud : null,
                route: path,
                trail: trail,
                trailLength: trail.length,
                marks: marks,
                markCount: marks.length,
                pose: pose,
                modeColor: modeColor,
                follow: follow,
                compact: compact,
              ),
            ),
            if (pose == null && !compact)
              Align(
                alignment: const Alignment(0, 0.55),
                child: Text(notLocalizedText, style: Txt.small.copyWith(color: Palette.caution)),
              ),
          ],
        ),
      ),
    );
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.cloud,
    required this.route,
    required this.trail,
    required this.trailLength,
    required this.marks,
    required this.markCount,
    required this.pose,
    required this.modeColor,
    required this.follow,
    required this.compact,
  });

  final Float32List? cloud;
  final List<RoutePoint> route;
  final List<Offset> trail;
  final List<Offset> marks;

  /// The trail and mark lists grow in place; their lengths tell shouldRepaint that they changed.
  final int trailLength;
  final int markCount;
  final Pose? pose;
  final Color modeColor;
  final bool follow;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = Palette.night);
    final pose = this.pose;
    if (pose == null) {
      _robotCentric(canvas, size);
      return;
    }

    // what to show, in map metres
    var minX = pose.x, maxX = pose.x, minY = pose.y, maxY = pose.y;
    if (!follow) {
      for (final p in [for (final r in route) Offset(r.x, r.y), ...trail]) {
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
    }
    final span = follow ? 10.0 : (compact ? 6.0 : 8.0);
    const margin = 1.5;
    final width = math.max(maxX - minX + 2 * margin, span);
    final height = math.max(maxY - minY + 2 * margin, span);
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    final scale = math.min(size.width / width, size.height / height);
    Offset toScreen(double x, double y) =>
        Offset(size.width / 2 + (x - cx) * scale, size.height / 2 - (y - cy) * scale);

    _grid(canvas, size, scale, cx, cy);

    final cloud = this.cloud;
    if (cloud != null) {
      final c = math.cos(pose.yaw), s = math.sin(pose.yaw);
      final xy = <double>[];
      for (var i = 0; i + 2 < cloud.length; i += 3) {
        final z = cloud[i + 2];
        if (z < -0.25 || z > 1.6) continue; // floor and ceiling
        final x = cloud[i], y = cloud[i + 1];
        final o = toScreen(pose.x + c * x - s * y, pose.y + s * x + c * y);
        if (o.dx < 0 || o.dy < 0 || o.dx > size.width || o.dy > size.height) continue;
        xy
          ..add(o.dx)
          ..add(o.dy);
      }
      if (xy.isNotEmpty) {
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(xy),
          Paint()
            ..color = Palette.text.withValues(alpha: 0.55)
            ..strokeWidth = compact ? 1.6 : 2.2
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    if (trail.length > 1) {
      final first = toScreen(trail.first.dx, trail.first.dy);
      final path = Path()..moveTo(first.dx, first.dy);
      for (final p in trail.skip(1)) {
        final o = toScreen(p.dx, p.dy);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = compact ? 1.2 : 1.6
          ..color = Palette.remote.withValues(alpha: 0.55),
      );
    }

    if (route.length > 1) _route(canvas, toScreen);
    for (final m in marks) {
      _stopPoint(canvas, toScreen(m.dx, m.dy));
    }
    _robot(canvas, toScreen(pose.x, pose.y), pose.yaw);
    if (!compact) _scaleBar(canvas, size, scale);
  }

  void _grid(Canvas canvas, Size size, double scale, double cx, double cy) {
    final step = scale > 30 ? 1.0 : (scale > 6 ? 5.0 : 10.0);
    final paint = Paint()
      ..color = const Color(0x14FFFFFF)
      ..strokeWidth = 1;
    final halfW = size.width / 2 / scale, halfH = size.height / 2 / scale;
    for (var x = ((cx - halfW) / step).floor() * step; x <= cx + halfW; x += step) {
      final sx = size.width / 2 + (x - cx) * scale;
      canvas.drawLine(Offset(sx, 0), Offset(sx, size.height), paint);
    }
    for (var y = ((cy - halfH) / step).floor() * step; y <= cy + halfH; y += step) {
      final sy = size.height / 2 - (y - cy) * scale;
      canvas.drawLine(Offset(0, sy), Offset(size.width, sy), paint);
    }
  }

  void _route(Canvas canvas, Offset Function(double, double) toScreen) {
    final points = [for (final p in route) toScreen(p.x, p.y)];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final o in points.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = compact ? 2 : 3
        ..strokeJoin = StrokeJoin.round
        ..color = Palette.auto.withValues(alpha: 0.85),
    );

    final waypoint = Paint()..color = Palette.auto;
    if (!compact && points.length <= 400) {
      for (final o in points) {
        canvas.drawCircle(o, 2.2, waypoint);
      }
    }

    // start ring, then the stop points with their inspection time
    canvas.drawCircle(
      points.first,
      compact ? 4 : 6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Palette.ok,
    );
    for (var i = 0; i < route.length; i++) {
      if (!route[i].isStop) continue;
      _stopPoint(canvas, points[i]);
      if (!compact) _label(canvas, '${route[i].dwell.round()} s', points[i] + const Offset(9, -18));
    }
  }

  void _stopPoint(Canvas canvas, Offset at) {
    final radius = compact ? 3.5 : 6.0;
    canvas.drawCircle(at, radius, Paint()..color = Palette.caution);
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  void _robot(Canvas canvas, Offset at, double yaw) {
    final r = compact ? 7.0 : 10.0;
    // screen y points down, map yaw turns counter-clockwise
    Offset dir(double a, double len) => at + Offset(math.cos(a) * len, -math.sin(a) * len);
    final body = Path()
      ..moveTo(dir(yaw, r * 1.4).dx, dir(yaw, r * 1.4).dy)
      ..lineTo(dir(yaw + 2.5, r).dx, dir(yaw + 2.5, r).dy)
      ..lineTo(dir(yaw + math.pi, r * 0.35).dx, dir(yaw + math.pi, r * 0.35).dy)
      ..lineTo(dir(yaw - 2.5, r).dx, dir(yaw - 2.5, r).dy)
      ..close();
    canvas.drawCircle(at, r * 2.2, Paint()..color = modeColor.withValues(alpha: 0.16));
    canvas.drawPath(body, Paint()..color = modeColor);
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  void _scaleBar(Canvas canvas, Size size, double scale) {
    var metres = 1.0;
    for (final m in const [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]) {
      metres = m;
      if (m * scale >= 60) break;
    }
    final length = metres * scale;
    final left = Offset(14, size.height - 16);
    final paint = Paint()
      ..color = Palette.text.withValues(alpha: 0.8)
      ..strokeWidth = 2;
    canvas.drawLine(left, left.translate(length, 0), paint);
    canvas.drawLine(left.translate(0, -4), left.translate(0, 4), paint);
    canvas.drawLine(left.translate(length, -4), left.translate(length, 4), paint);
    _label(canvas, '${metres.round()} m', left.translate(length + 6, -8));
  }

  void _label(Canvas canvas, String text, Offset at) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: Txt.small.copyWith(color: Palette.text)),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
    painter.dispose();
  }

  /// Not localized: lidar around the robot, robot in the middle looking up.
  void _robotCentric(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.62);
    final scale = center.dy / 6;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..color = Palette.line;
    for (var r = 2.0; r <= 8; r += 2) {
      canvas.drawCircle(center, r * scale, ring);
    }
    final cloud = this.cloud;
    if (cloud != null) {
      final xy = <double>[];
      for (var i = 0; i + 2 < cloud.length; i += 3) {
        final z = cloud[i + 2];
        if (z < -0.25 || z > 1.6) continue;
        xy
          ..add(center.dx - cloud[i + 1] * scale)
          ..add(center.dy - cloud[i] * scale);
      }
      if (xy.isNotEmpty) {
        canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(xy),
          Paint()
            ..color = Palette.text.withValues(alpha: 0.6)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    _robot(canvas, center, math.pi / 2);
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.cloud != cloud ||
      old.route != route ||
      old.trailLength != trailLength ||
      old.markCount != markCount ||
      old.pose?.x != pose?.x ||
      old.pose?.y != pose?.y ||
      old.pose?.yaw != pose?.yaw ||
      old.modeColor != modeColor ||
      old.follow != follow ||
      old.compact != compact;
}
