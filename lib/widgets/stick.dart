import 'package:flutter/material.dart';

import '../theme.dart';

/// Floating thumb stick: it appears where the thumb lands anywhere in its zone.
///
/// Reports x right and y up, inside the unit circle; zero when released.
class StickZone extends StatefulWidget {
  const StickZone({
    super.key,
    required this.onChanged,
    required this.home,
    required this.icon,
    this.horizontalOnly = false,
    this.color = Palette.text,
  });

  final ValueChanged<Offset> onChanged;

  /// Where the idle hint sits in the zone.
  final Alignment home;
  final IconData icon;

  /// Turn stick: only x counts.
  final bool horizontalOnly;
  final Color color;

  @override
  State<StickZone> createState() => _StickZoneState();
}

class _StickZoneState extends State<StickZone> {
  static const _radius = 54.0;

  int? _pointer;
  Offset? _origin;
  Offset _knob = Offset.zero;

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    setState(() {
      _pointer = event.pointer;
      _origin = event.localPosition;
      _knob = Offset.zero;
    });
    widget.onChanged(Offset.zero);
  }

  void _move(PointerMoveEvent event) {
    final origin = _origin;
    if (event.pointer != _pointer || origin == null) return;
    var delta = event.localPosition - origin;
    if (widget.horizontalOnly) delta = Offset(delta.dx, 0);
    if (delta.distance > _radius) delta = delta / delta.distance * _radius;
    setState(() => _knob = delta);
    widget.onChanged(Offset(delta.dx / _radius, -delta.dy / _radius));
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    setState(() {
      _pointer = null;
      _origin = null;
      _knob = Offset.zero;
    });
    widget.onChanged(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: CustomPaint(
        painter: _StickPainter(
          origin: _origin,
          knob: _knob,
          home: widget.home,
          icon: widget.icon,
          color: widget.color,
          horizontalOnly: widget.horizontalOnly,
          radius: _radius,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _StickPainter extends CustomPainter {
  _StickPainter({
    required this.origin,
    required this.knob,
    required this.home,
    required this.icon,
    required this.color,
    required this.horizontalOnly,
    required this.radius,
  });

  final Offset? origin;
  final Offset knob;
  final Alignment home;
  final IconData icon;
  final Color color;
  final bool horizontalOnly;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final active = origin != null;
    final center = origin ?? home.alongSize(size);
    final base = Paint()..color = const Color(0x40000000);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = active ? color.withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.22);

    if (horizontalOnly) {
      final track = RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: radius * 2 + 36, height: 40),
        const Radius.circular(20),
      );
      canvas.drawRRect(track, base);
      canvas.drawRRect(track, ring);
    } else {
      canvas.drawCircle(center, radius + 18, base);
      canvas.drawCircle(center, radius + 18, ring);
    }

    final knobCenter = center + knob;
    canvas.drawCircle(
      knobCenter,
      18,
      Paint()..color = active ? color.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.16),
    );

    final glyph = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: 20,
          color: active ? Palette.night : Colors.white.withValues(alpha: 0.7),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    glyph.paint(canvas, knobCenter - Offset(glyph.width / 2, glyph.height / 2));
    glyph.dispose();
  }

  @override
  bool shouldRepaint(_StickPainter old) =>
      old.origin != origin || old.knob != knob || old.color != color || old.home != home;
}
