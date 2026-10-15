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

  test('inspection and patrol speed in the state', () {
    final state = RobotState.fromJson({
      'inspection': {
        'on': true,
        'state': 'running',
        'model': 'moondream',
        'interval': 0,
        'count': 12,
        'reports': 2,
        'last': {
          'cat': 'trash',
          'reported': true,
          'ms': 1800,
          'age': 3,
          'desc': 'a cup',
          'source': 'periodic',
        },
      },
      'speed': {'target': 0.4, 'min': 0.1, 'max': 0.6},
    });
    final inspection = state.inspection!;
    expect(inspection.pace, 'continuous');
    expect(inspection.reports, 2);
    expect(inspection.last!.category, 'trash');
    expect(inspection.last!.clear, isFalse);
    expect(inspection.last!.age, 3);
    expect(state.speed!.max, 0.6);
    expect(RobotState.fromJson({'inspection': null}).inspection, isNull);
    expect(RobotState.fromJson({'speed': {'target': 'x', 'min': 0.1, 'max': 0.6}}).speed, isNull);
    expect(RobotState.fromJson({'speed': {'target': 0.4, 'min': 0.7, 'max': 0.6}}).speed, isNull);
    expect(InspectionStatus.fromJson({'interval': -1})!.pace, 'stops');
    expect(InspectionStatus.fromJson({'interval': 5})!.pace, 'interval');
    expect(InspectionStatus.fromJson({})!.state, 'offline');
    expect(InspectionStatus.fromJson({'last': {}})!.last!.clear, isTrue);
  });

  test('the inspection queue and how long a frame waited', () {
    final status = InspectionStatus.fromJson({
      'on': true,
      'state': 'running',
      'interval': 5,
      'queue': 4,
      'queue_max': 50,
      'last': {'cat': 'none', 'waited': 12},
    })!;
    expect((status.queue, status.queueMax, status.last!.waited), (4, 50, 12));
    expect(InspectionStatus.fromJson({'on': true})!.queue, 0);
  });

  test('people and the robot load in the state', () {
    final state = RobotState.fromJson({
      'people': {'on': true, 'state': 'running', 'count': 2, 'ms': 90, 'age': 1, 'backend': 'cpu',
        'boxes': [[0.1, 0.2, 0.3, 0.9, 0.87], [1, 2], 'x']},
      'health': {'ok': true, 'issues': [], 'cpu': 12.0, 'gpu': null, 'ram_used': 4.2},
    });
    expect(state.people!.count, 2);
    expect(state.people!.boxes.single.y2, 0.9);
    expect(state.people!.boxes.single.score, 0.87);
    expect(state.people!.latencyMs, 90);
    expect(state.load!.cpu, 12.0);
    expect(state.load!.gpu, isNull);
    expect(state.load!.ramUsed, 4.2);
    expect(state.healthOk, isTrue);
    expect(RobotState.fromJson({'health': {'ok': true, 'issues': []}}).load, isNull);
    expect(PeopleStatus.fromJson({})!.state, 'offline');
    expect(PeopleStatus.fromJson({'state': 'loading'})!.count, isNull);
  });

  test('inspection models and their names', () {
    final models = InspectionModel.listFromJson([
      {'name': 'moondream:latest', 'installed': true, 'active': true},
      {'name': 'x', 'installed': null},
      {'installed': true},
      'junk',
    ]);
    expect(models.map((m) => m.name).toList(), ['moondream:latest', 'x']);
    expect(models.first.active, isTrue);
    expect(models[1].installed, isNull);
    expect(InspectionModel.listFromJson('junk'), isEmpty);
    expect(fullModelName('moondream'), 'moondream:latest');
    expect(fullModelName(' qwen3-vl:2b-instruct '), 'qwen3-vl:2b-instruct');
    expect(
      fullModelName('ahmadwaqar/smolvlm2-2.2b-instruct'),
      'ahmadwaqar/smolvlm2-2.2b-instruct:latest',
    );
    expect(categoryLabel('id', 'trash'), 'Sampah');
    expect(categoryLabel('en', 'wet_floor'), 'wet floor');
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
