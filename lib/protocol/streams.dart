/// Binary streams of the teleop protocol: camera JPEG, lidar points and the loaded route.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'messages.dart';

const streamCamera = 1;
const streamLidar = 2;
const streamRoute = 3;

/// `PSH1` magic, u8 stream, u32 frame, u16 chunk index, u16 chunk count (little-endian).
const headerSize = 13;
const _magic = [0x50, 0x53, 0x48, 0x31];

class StreamFrame {
  const StreamFrame(this.stream, this.frame, this.payload);

  final int stream;
  final int frame;
  final Uint8List payload;
}

class _Partial {
  _Partial(this.frame, int count) : chunks = List<Uint8List?>.filled(count, null);

  final int frame;
  final List<Uint8List?> chunks;
  int received = 0;
}

/// Rebuilds chunked payloads per stream; an incomplete frame is dropped once a newer one starts.
class Reassembler {
  final _frames = <int, _Partial>{};

  /// Forgets unfinished frames (a new session starts its frame counters at 0 again).
  void reset() => _frames.clear();

  /// Adds one datagram; returns the payload once its frame is complete.
  StreamFrame? push(Uint8List datagram) {
    if (datagram.length < headerSize) return null;
    for (var i = 0; i < _magic.length; i++) {
      if (datagram[i] != _magic[i]) return null;
    }
    final header = ByteData.sublistView(datagram, 0, headerSize);
    final stream = header.getUint8(4);
    final frame = header.getUint32(5, Endian.little);
    final index = header.getUint16(9, Endian.little);
    final count = header.getUint16(11, Endian.little);
    if (count == 0 || index >= count) return null;

    var partial = _frames[stream];
    if (partial == null || partial.frame != frame) {
      if (partial != null && _isOlder(frame, partial.frame)) return null;
      partial = _Partial(frame, count);
      _frames[stream] = partial;
    }
    if (partial.chunks.length != count) return null;
    if (partial.chunks[index] == null) {
      partial.chunks[index] = Uint8List.sublistView(datagram, headerSize);
      partial.received++;
    }
    if (partial.received < count) return null;

    _frames.remove(stream);
    final builder = BytesBuilder(copy: false);
    for (final chunk in partial.chunks) {
      builder.add(chunk!);
    }
    return StreamFrame(stream, frame, builder.takeBytes());
  }

  /// True when [frame] is before [current] (u32 counters, wrap-around safe).
  static bool _isOlder(int frame, int current) {
    final distance = (current - frame) & 0xFFFFFFFF;
    return distance != 0 && distance < 0x80000000;
  }
}

/// Lidar payload: int16 x, y, z in centimetres per point, robot frame (base_link).
Float32List decodePoints(Uint8List payload) {
  final count = payload.length ~/ 6;
  final view = ByteData.sublistView(payload);
  final out = Float32List(count * 3);
  for (var i = 0; i < count * 3; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 100.0;
  }
  return out;
}

/// Route payload: JSON {"t": "route", "points": [[x, y, dwell_sec], ...]} in the map frame.
List<RoutePoint> decodeRoute(Uint8List payload) {
  try {
    final json = jsonDecode(utf8.decode(payload));
    final points = json is Map ? json['points'] : null;
    if (points is! List) return const [];
    final route = <RoutePoint>[];
    for (final p in points) {
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
        final dwell = p.length > 2 && p[2] is num ? (p[2] as num).toDouble() : 0.0;
        route.add(RoutePoint((p[0] as num).toDouble(), (p[1] as num).toDouble(), dwell));
      }
    }
    return route;
  } on FormatException {
    return const [];
  }
}
