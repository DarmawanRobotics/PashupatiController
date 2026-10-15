import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../theme.dart';

/// Robot camera with the AprilTags it sees. Frames are decoded one at a time, newest first,
/// outside the image cache (a cache entry per video frame would only fill memory).
class CameraView extends StatefulWidget {
  const CameraView({
    super.key,
    required this.frames,
    required this.enabled,
    required this.offText,
    required this.waitText,
    this.tags = const [],
  });

  final ValueListenable<Uint8List?> frames;
  final bool enabled;
  final String offText;
  final String waitText;
  final List<Tag> tags;

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  ui.Image? _image;
  bool _decoding = false;
  Uint8List? _queued;

  /// Bumped when the video stops, so a decode still running then is thrown away.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.frames.addListener(_onFrame);
  }

  @override
  void didUpdateWidget(CameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames) {
      oldWidget.frames.removeListener(_onFrame);
      widget.frames.addListener(_onFrame);
    }
  }

  @override
  void dispose() {
    widget.frames.removeListener(_onFrame);
    _image?.dispose();
    super.dispose();
  }

  void _onFrame() {
    final jpeg = widget.frames.value;
    if (jpeg == null) {
      _generation++;
      _queued = null;
      setState(() {
        _image?.dispose();
        _image = null;
      });
      return;
    }
    if (_decoding) {
      _queued = jpeg;
      return;
    }
    unawaited(_decode(jpeg));
  }

  Future<void> _decode(Uint8List jpeg) async {
    _decoding = true;
    final generation = _generation;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      if (!mounted || generation != _generation) {
        frame.image.dispose(); // the video stopped meanwhile
      } else {
        setState(() {
          _image?.dispose();
          _image = frame.image;
        });
      }
    } on Exception {
      // a broken JPEG: skip the frame
    } finally {
      codec?.dispose();
      _decoding = false;
    }
    final next = _queued;
    _queued = null;
    if (next != null && mounted) unawaited(_decode(next));
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (!widget.enabled || image == null) {
      return _Backdrop(text: widget.enabled ? widget.waitText : widget.offText);
    }
    final size = Size(image.width.toDouble(), image.height.toDouble());
    return Stack(
      fit: StackFit.expand,
      children: [
        RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.low),
        if (widget.tags.isNotEmpty) CustomPaint(painter: _TagPainter(widget.tags, size)),
      ],
    );
  }
}

/// AprilTag outlines and ids over the video, cropped the way BoxFit.cover crops the frame.
class _TagPainter extends CustomPainter {
  _TagPainter(this.tags, this.imageSize);

  final List<Tag> tags;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || imageSize.isEmpty) return;
    final fitted = applyBoxFit(BoxFit.cover, imageSize, size);
    final source = Alignment.center.inscribe(fitted.source, Offset.zero & imageSize);
    final shown = Alignment.center.inscribe(fitted.destination, Offset.zero & size);
    Offset toView(double fx, double fy) => Offset(
      shown.left + (fx * imageSize.width - source.left) * shown.width / source.width,
      shown.top + (fy * imageSize.height - source.top) * shown.height / source.height,
    );
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeJoin = StrokeJoin.round
      ..color = Palette.auto;
    for (final tag in tags) {
      final c = tag.corners;
      final corners = [for (var i = 0; i < 4; i++) toView(c[2 * i], c[2 * i + 1])];
      canvas.drawPath(Path()..addPolygon(corners, true), outline);
      final top = corners.reduce((a, b) => a.dy <= b.dy ? a : b);
      final bottom = corners.reduce((a, b) => a.dy >= b.dy ? a : b);
      _label(canvas, 'ID ${tag.id}', top, bottom);
    }
  }

  /// The id above the tag, or under it when the tag is at the top edge.
  void _label(Canvas canvas, String text, Offset top, Offset bottom) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: Txt.label.copyWith(color: Palette.night)),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width + 10, height = painter.height + 4;
    var box = Rect.fromLTWH(top.dx, top.dy - height - 4, width, height);
    if (box.top < 4) box = Rect.fromLTWH(bottom.dx, bottom.dy + 4, width, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(4)),
      Paint()..color = Palette.auto,
    );
    painter.paint(canvas, box.topLeft + const Offset(5, 2));
    painter.dispose();
  }

  @override
  bool shouldRepaint(_TagPainter old) => old.tags != tags || old.imageSize != imageSize;
}

/// Dark floor grid shown when there is no video.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GridPainter(),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_rounded, color: Palette.muted, size: 28),
            const SizedBox(height: 8),
            Text(text, style: Txt.small),
          ],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Palette.night);
    final line = Paint()
      ..color = const Color(0x12FFFFFF)
      ..strokeWidth = 1;
    const step = 48.0;
    for (var x = size.width / 2 % step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = size.height / 2 % step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}
