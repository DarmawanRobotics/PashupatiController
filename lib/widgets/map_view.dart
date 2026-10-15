import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../theme.dart';

/// What the map shows.
enum MapMode {
  /// The loaded route, where the robot has been and the robot.
  fit,

  /// A fixed span around the robot, moving with it.
  follow,

  /// Where the operator dragged and zoomed it.
  free,
}

/// The map's view, shared by the big and the small map and the buttons under the small one.
class MapViewport extends ChangeNotifier {
  static const minSpan = 2.0;
  static const maxSpan = 5000.0;

  MapMode _mode = MapMode.fit;
  Offset _center = Offset.zero;
  double _span = 12;

  MapMode get mode => _mode;

  /// Middle of the view in map metres (free mode).
  Offset get center => _center;

  /// Metres across the shorter side of the view (follow and free mode).
  double get span => _span;

  static double clampSpan(double span) => math.min(maxSpan, math.max(minSpan, span));

  void fit() => _set(MapMode.fit, _center, _span);

  void follow() => _set(MapMode.follow, _center, _span);

  /// Zoom while following the robot.
  void zoom(double span) => _set(MapMode.follow, _center, span);

  /// Show [center] with [span] metres across the shorter side.
  void moveTo(Offset center, double span) => _set(MapMode.free, center, span);

  void _set(MapMode mode, Offset center, double span) {
    _mode = mode;
    _center = center;
    _span = clampSpan(span);
    notifyListeners();
  }
}

/// Top-down map in the map frame: the loaded route with its waypoints and stop points, where the
/// robot has been, the lidar returns and the robot itself.
///
/// The big map zooms with a pinch and moves with a drag; a double tap follows the robot again.
/// The small one only shows. Without a pose (not localized) it shows the lidar around the robot.
class MapView extends StatefulWidget {
  const MapView({
    super.key,
    required this.viewport,
    required this.points,
    required this.route,
    required this.trail,
    required this.pose,
    required this.modeColor,
    required this.lidar,
    required this.notLocalizedText,
    this.marks = const [],
    this.compact = false,
  });

  final MapViewport viewport;
  final ValueListenable<Float32List?> points;
  final ValueListenable<List<RoutePoint>> route;
  final List<Offset> trail;

  /// Stop points marked in the route being recorded (not in the route stream yet).
  final List<Offset> marks;
  final Pose? pose;
  final Color modeColor;
  final bool lidar;
  final String notLocalizedText;

  /// Small box: thinner lines, no labels, no gestures (a tap there swaps the views).
  final bool compact;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  late Listenable _changes = _merge();
  Size _size = Size.zero;

  // where a pinch or drag started
  Offset _startFocal = Offset.zero;
  Offset _startCenter = Offset.zero;
  double _startScale = 1;

  Listenable _merge() => Listenable.merge([widget.viewport, widget.points, widget.route]);

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewport != widget.viewport ||
        oldWidget.points != widget.points ||
        oldWidget.route != widget.route) {
      _changes = _merge();
    }
  }

  /// Middle of the view (map metres) and pixels per metre.
  ({Offset center, double scale}) _view() {
    final viewport = widget.viewport;
    final shorter = math.max(1.0, _size.shortestSide);
    final pose = widget.pose;
    if (pose == null) return (center: Offset.zero, scale: shorter / viewport.span);
    switch (viewport.mode) {
      case MapMode.follow:
        return (center: Offset(pose.x, pose.y), scale: shorter / viewport.span);
      case MapMode.free:
        return (center: viewport.center, scale: shorter / viewport.span);
      case MapMode.fit:
        var minX = pose.x, maxX = pose.x, minY = pose.y, maxY = pose.y;
        void include(double x, double y) {
          minX = math.min(minX, x);
          maxX = math.max(maxX, x);
          minY = math.min(minY, y);
          maxY = math.max(maxY, y);
        }

        for (final p in widget.route.value) {
          include(p.x, p.y);
        }
        for (final p in widget.trail) {
          include(p.dx, p.dy);
        }
        const margin = 1.5;
        final least = widget.compact ? 6.0 : 8.0;
        final width = math.max(maxX - minX + 2 * margin, least);
        final height = math.max(maxY - minY + 2 * margin, least);
        return (
          center: Offset((minX + maxX) / 2, (minY + maxY) / 2),
          scale: math.min(math.max(1.0, _size.width) / width, math.max(1.0, _size.height) / height),
        );
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    final view = _view();
    _startFocal = details.localFocalPoint;
    _startCenter = view.center;
    _startScale = view.scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final viewport = widget.viewport;
    final shorter = math.max(1.0, _size.shortestSide);
    final span = MapViewport.clampSpan(shorter / (_startScale * details.scale));
    final moved = (details.localFocalPoint - _startFocal).distance;
    if (widget.pose == null || (viewport.mode == MapMode.follow && moved < 24)) {
      viewport.zoom(span); // around the robot
      return;
    }
    // the map point that was under the fingers stays under them
    final scale = shorter / span;
    final half = _size.center(Offset.zero);
    final from = _startFocal - half;
    final to = details.localFocalPoint - half;
    final anchor = Offset(
      _startCenter.dx + from.dx / _startScale,
      _startCenter.dy - from.dy / _startScale,
    );
    viewport.moveTo(Offset(anchor.dx - to.dx / scale, anchor.dy + to.dy / scale), span);
  }

  @override
  Widget build(BuildContext context) {
    final interactive = !widget.compact;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return GestureDetector(
          onScaleStart: interactive ? _onScaleStart : null,
          onScaleUpdate: interactive ? _onScaleUpdate : null,
          onDoubleTap: interactive ? widget.viewport.follow : null,
          child: ListenableBuilder(
            listenable: _changes,
            builder: (context, _) {
              final view = _view();
              final pose = widget.pose;
              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _MapPainter(
                      cloud: widget.lidar ? widget.points.value : null,
                      route: widget.route.value,
                      trail: widget.trail,
                      trailLength: widget.trail.length,
                      marks: widget.marks,
                      markCount: widget.marks.length,
                      pose: pose,
                      center: view.center,
                      scale: view.scale,
                      modeColor: widget.modeColor,
                      compact: widget.compact,
                    ),
                  ),
                  if (pose == null && !widget.compact)
                    Align(
                      alignment: const Alignment(0, 0.55),
                      child: Text(
                        widget.notLocalizedText,
                        style: Txt.small.copyWith(color: Palette.caution),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
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
    required this.center,
    required this.scale,
    required this.modeColor,
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

  /// Middle of the view in map metres, and pixels per metre.
  final Offset center;
  final double scale;
  final Color modeColor;
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
    final cx = center.dx, cy = center.dy;
    Offset toScreen(double x, double y) =>
        Offset(size.width / 2 + (x - cx) * scale, size.height / 2 - (y - cy) * scale);

    _grid(canvas, size, cx, cy);

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
      _points(canvas, xy, 0.55);
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
    if (!compact) _scaleBar(canvas, size);
  }

  void _points(Canvas canvas, List<double> xy, double alpha) {
    if (xy.isEmpty) return;
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(xy),
      Paint()
        ..color = Palette.text.withValues(alpha: alpha)
        ..strokeWidth = compact ? 1.6 : 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  /// Grid lines at least ~28 px apart, in round metres.
  double get _step {
    for (final step in const [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0]) {
      if (step * scale >= 28) return step;
    }
    return 1000;
  }

  void _grid(Canvas canvas, Size size, double cx, double cy) {
    final step = _step;
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

  void _scaleBar(Canvas canvas, Size size) {
    var metres = 1.0;
    for (final m in const [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0]) {
      metres = m;
      if (m * scale >= 60) break;
    }
    final length = metres * scale;
    final left = Offset(14, size.height - 86); // above the icons at the bottom
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

  /// Not localized: lidar around the robot, robot low in the middle looking up.
  void _robotCentric(Canvas canvas, Size size) {
    final at = Offset(size.width / 2, size.height * 0.62);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..color = Palette.line;
    final step = _step * 2;
    final reach = size.longestSide / scale;
    for (var r = step; r <= reach; r += step) {
      canvas.drawCircle(at, r * scale, ring);
    }
    final cloud = this.cloud;
    if (cloud != null) {
      final xy = <double>[];
      for (var i = 0; i + 2 < cloud.length; i += 3) {
        final z = cloud[i + 2];
        if (z < -0.25 || z > 1.6) continue;
        xy
          ..add(at.dx - cloud[i + 1] * scale)
          ..add(at.dy - cloud[i] * scale);
      }
      _points(canvas, xy, 0.6);
    }
    _robot(canvas, at, math.pi / 2);
    if (!compact) _scaleBar(canvas, size);
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
      old.center != center ||
      old.scale != scale ||
      old.modeColor != modeColor ||
      old.compact != compact;
}
