import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_teleop/input/gamepad_input.dart';
import 'package:flutter_teleop/l10n.dart';
import 'package:flutter_teleop/protocol/messages.dart';
import 'package:flutter_teleop/protocol/streams.dart';
import 'package:flutter_teleop/robot_actions.dart';
import 'package:flutter_test/flutter_test.dart';

/// One datagram as robot_bridge/protocol.py chunk() packs it.
Uint8List datagram(int stream, int frame, int index, int count, List<int> payload) {
  final header = ByteData(9)
    ..setUint8(0, stream)
    ..setUint32(1, frame, Endian.little)
    ..setUint16(5, index, Endian.little)
    ..setUint16(7, count, Endian.little);
  return Uint8List.fromList([
    ...ascii.encode('PSH1'),
    ...header.buffer.asUint8List(),
    ...payload,
  ]);
}

void main() {
  group('Reassembler', () {
    test('joins chunks that arrive out of order', () {
      final r = Reassembler();
      expect(r.push(datagram(1, 7, 1, 3, [4, 5])), isNull);
      expect(r.push(datagram(1, 7, 0, 3, [1, 2, 3])), isNull);
      final frame = r.push(datagram(1, 7, 2, 3, [6]));
      expect(frame, isNotNull);
      expect(frame!.stream, 1);
      expect(frame.payload, [1, 2, 3, 4, 5, 6]);
    });

    test('drops a late chunk of an older frame', () {
      final r = Reassembler();
      expect(r.push(datagram(2, 10, 0, 2, [1])), isNull);
      expect(r.push(datagram(2, 11, 0, 2, [9])), isNull);
      expect(r.push(datagram(2, 10, 1, 2, [2])), isNull);
      expect(r.push(datagram(2, 11, 1, 2, [8]))!.payload, [9, 8]);
    });

    test('handles the frame counter wrapping around', () {
      final r = Reassembler();
      expect(r.push(datagram(3, 0xFFFFFFFF, 0, 2, [1])), isNull);
      expect(r.push(datagram(3, 0, 0, 1, [5]))!.payload, [5]);
    });

    test('ignores junk', () {
      final r = Reassembler();
      expect(r.push(Uint8List.fromList(utf8.encode('{"t":"state"}'))), isNull);
      expect(r.push(datagram(1, 1, 3, 2, [1])), isNull);
    });
  });

  test('lidar points are int16 centimetres', () {
    final bytes = ByteData(12)
      ..setInt16(0, 150, Endian.little)
      ..setInt16(2, -20, Endian.little)
      ..setInt16(4, 5, Endian.little)
      ..setInt16(6, -300, Endian.little)
      ..setInt16(8, 0, Endian.little)
      ..setInt16(10, 100, Endian.little);
    final points = decodePoints(bytes.buffer.asUint8List());
    expect(points.length, 6);
    expect(points[0], closeTo(1.5, 1e-6));
    expect(points[1], closeTo(-0.2, 1e-6));
    expect(points[3], closeTo(-3.0, 1e-6));
  });

  test('route payload', () {
    final route = decodeRoute(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            't': 'route',
            'points': [
              [0, 0, 0],
              [2.5, 1, 10],
              ['bad'],
            ],
          }),
        ),
      ),
    );
    expect(route.length, 2);
    expect(route[1].isStop, isTrue);
    expect(decodeRoute(Uint8List.fromList([1, 2, 3])), isEmpty);
  });

  test('state tolerates missing and broken fields', () {
    final state = RobotState.fromJson({
      't': 'state',
      'seq': 4,
      'mode': 'remote',
      'pose': [1.0, 2.0, 0.5],
      'battery': {'pct': 77.0, 'v': 25.1},
      'health': {'ok': false, 'issues': ['odometry lost']},
      'cmd': [0.2, 'x', 0.1],
      'estop': true,
      'field': 'limited',
    });
    expect(state.remote, isTrue);
    expect(state.pose!.yaw, 0.5);
    expect(state.battery!.percent, 77.0);
    expect(state.cmd, [0.2, 0.0, 0.1]);
    expect(state.healthIssues, ['odometry lost']);
    expect(RobotState.fromJson({'pose': null}).pose, isNull);
    final tags = RobotState.fromJson({
      'tags': [
        [3, 0.1, 0.2, 0.3, 0.2, 0.3, 0.4, 0.1, 0.4],
        [4, 'x'],
      ],
    }).tags;
    expect(tags.length, 1);
    expect(tags.first.id, 3);
    expect(tags.first.corners[2], closeTo(0.3, 1e-9));
  });

  test('localization source kinds', () {
    RobotState loc(String v) => RobotState.fromJson({'localization': v});
    expect(loc('none').localizationKind, 'none');
    expect(loc('start position').localizationKind, 'start');
    expect(loc('RViz 2D Pose Estimate').localizationKind, 'pose');
    final tag = loc('apriltag "base_map" (auto start)');
    expect(tag.localizationKind, 'tag');
    expect(tag.localizationTag, 'base_map');
    expect(loc('start position').localizationTag, isNull);
  });

  test('welcome without robot_commands derives them from commands', () {
    final welcome = Welcome.fromJson({
      'commands': ['estop', 'nav_start', 'stand_up', 'sit_down', 'list_routes'],
      'limits': [1.0, 0.5, 1.5],
    });
    expect(welcome.robotCommands, ['stand_up', 'sit_down']);
    expect(welcome.limits, [1.0, 0.5, 1.5]);
    final explicit = Welcome.fromJson({
      'commands': ['stand_up', 'sdk_control_right'],
      'robot_commands': ['sdk_control_right', 'stand_up'],
    });
    expect(explicit.robotCommands.first, 'sdk_control_right');
    expect(explicit.video, isNull); // an older robot: JPEG frames only
  });

  test('welcome offers the WebRTC video of the robot', () {
    final welcome = Welcome.fromJson({
      'commands': ['estop'],
      'video': {'port': 8890, 'path': 'camera'},
    });
    expect(
      welcome.video!.whep('192.168.234.234').toString(),
      'http://192.168.234.234:8890/camera/whep',
    );
    expect(welcome.video!.whep('robot.local').path, '/camera/whep');
    for (final bad in [
      {'port': 0, 'path': 'camera'},
      {'port': '8890', 'path': 'camera'},
      {'port': 8890, 'path': ''},
      {'port': 8890, 'path': '../admin'},
      {'port': 8890, 'path': 'cam?x=1'},
      'camera',
    ]) {
      expect(Welcome.fromJson({'video': bad}).video, isNull, reason: '$bad');
    }
  });

  test('stick dead zone and rescale', () {
    expect(GamepadInput.shaped(0.05), 0);
    expect(GamepadInput.shaped(1.0), 1.0);
    expect(GamepadInput.shaped(-1.0), -1.0);
    expect(GamepadInput.shaped(0.56), closeTo(0.5, 1e-9));
  });

  test('labels: both languages, unknown commands get a readable name', () {
    expect(tr('id', 'retry'), 'Coba lagi');
    expect(tr('en', 'in_use_by', {'who': 'Retroid'}), 'In use by Retroid');
    expect(tr('id', 'port'), 'Port');
    expect(robotAction('stand_up').label('id'), 'Berdiri');
    expect(robotAction('front_flip').label('en'), 'Front flip');
    expect(robotAction('damp').confirm, isTrue);
    expect(tr('id', 'nav_FOLLOWING'), 'Patroli');
  });
}
