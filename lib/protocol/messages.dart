/// JSON messages of the Pashupati teleop protocol v1 (robot_bridge/PROTOCOL.md).
library;

/// Commands that belong to Pashupati itself; everything else in `welcome.commands` is the robot's.
const pashupatiCommands = {
  'set_mode',
  'estop',
  'estop_release',
  'nav_start',
  'nav_stop',
  'nav_pause',
  'nav_resume',
  'record_start',
  'record_stop',
  'mark_stop',
  'load_route',
  'get_route',
  'list_routes',
  'localize',
  'record_tags',
  'inspection_set',
  'inspection_models',
  'people_set',
  'nav_speed',
};

double? _num(Object? value) => value is num && value.isFinite ? value.toDouble() : null;

String _str(Object? value, [String fallback = '']) => value is String ? value : fallback;

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const <String>[];

/// `state.tags`: rows of [id, x0, y0, x1, y1, x2, y2, x3, y3]; broken rows are skipped.
List<Tag> _tags(Object? value) {
  if (value is! List) return const [];
  final out = <Tag>[];
  for (final row in value) {
    if (row is! List || row.length != 9) continue;
    final numbers = [for (final v in row) _num(v)];
    if (numbers.contains(null)) continue;
    out.add(Tag(numbers.first!.round(), [for (final v in numbers.skip(1)) v!]));
  }
  return out;
}

/// A model name as Ollama lists it: `moondream` -> `moondream:latest` (as the robot compares).
String fullModelName(String model) {
  final name = model.trim();
  return name.split('/').last.contains(':') ? name : '$name:latest';
}

/// Answer to a LAN `discover` probe.
class Beacon {
  const Beacon({
    required this.host,
    required this.name,
    required this.secured,
    required this.inUseBy,
    required this.seen,
    this.mode,
    this.battery,
  });

  factory Beacon.fromJson(Map<String, dynamic> json, String host) => Beacon(
    host: host,
    name: _str(json['name'], host),
    secured: json['secured'] == true,
    inUseBy: _str(json['in_use_by']),
    mode: json['mode'] is String ? json['mode'] as String : null,
    battery: _num(json['battery']),
    seen: DateTime.now(),
  );

  final String host;
  final String name;
  final bool secured;
  final String inUseBy;
  final String? mode;
  final double? battery;
  final DateTime seen;
}

/// WebRTC video the robot offers (MediaMTX, WHEP): `http://<robot>:<port>/<path>/whep`.
class VideoOffer {
  const VideoOffer(this.port, this.path);

  /// Null unless `welcome.video` names a valid port and path.
  static VideoOffer? fromJson(Object? json) {
    if (json is! Map) return null;
    final port = json['port'];
    final path = json['path'];
    if (port is! int || port <= 0 || port > 65535) return null;
    if (path is! String || !RegExp(r'^[A-Za-z0-9_.~-]+(/[A-Za-z0-9_.~-]+)*$').hasMatch(path)) {
      return null;
    }
    if (path.split('/').any((segment) => segment == '.' || segment == '..')) return null;
    return VideoOffer(port, path);
  }

  final int port;
  final String path;

  /// The WHEP endpoint on the robot at [host] (the address the teleop link uses).
  Uri whep(String host) =>
      Uri(scheme: 'http', host: host, port: port, pathSegments: [...path.split('/'), 'whep']);
}

/// The robot's answer to `hello`.
class Welcome {
  const Welcome({
    required this.name,
    required this.commands,
    required this.robotCommands,
    required this.limits,
    this.video,
  });

  factory Welcome.fromJson(Map<String, dynamic> json) {
    final commands = _strings(json['commands']);
    final robot = json.containsKey('robot_commands')
        ? _strings(json['robot_commands'])
        : commands.where((c) => !pashupatiCommands.contains(c)).toList();
    final raw = json['limits'];
    final limits = raw is List && raw.length == 3 && raw.every((v) => _num(v) != null)
        ? raw.map((v) => _num(v)!).toList()
        : const [0.5, 0.3, 1.0];
    return Welcome(
      name: _str(json['name']),
      commands: commands,
      robotCommands: robot,
      limits: limits,
      video: VideoOffer.fromJson(json['video']),
    );
  }

  final String name;
  final List<String> commands;

  /// The robot driver's commands (std_srvs/Trigger), in the order the robot lists them.
  final List<String> robotCommands;

  /// Speed maxima [vx m/s, vy m/s, wz rad/s].
  final List<double> limits;

  /// WebRTC video, when the robot runs MediaMTX; else the camera comes as JPEG frames only.
  final VideoOffer? video;

  bool has(String command) => commands.contains(command);
}

class Pose {
  const Pose(this.x, this.y, this.yaw);

  final double x;
  final double y;
  final double yaw;
}

class Battery {
  const Battery({this.percent, this.voltage, this.current, this.temperature});

  final double? percent;
  final double? voltage;
  final double? current;
  final double? temperature;
}

/// One `state` telemetry message (10 Hz).
class RobotState {
  const RobotState({
    this.seq = 0,
    this.pose,
    this.mode = 'auto',
    this.nav = 'NAV_INACTIVE',
    this.navMessage = '',
    this.mission = '',
    this.localization = 'none',
    this.recording = false,
    this.battery,
    this.driverLevel,
    this.driverMessage = '',
    this.cmd = const [0.0, 0.0, 0.0],
    this.healthOk,
    this.healthIssues = const [],
    this.estop = false,
    this.field,
    this.tags = const [],
    this.inspection,
    this.people,
    this.load,
    this.speed,
  });

  factory RobotState.fromJson(Map<String, dynamic> json) {
    final pose = json['pose'];
    final battery = json['battery'];
    final driver = json['driver'];
    final health = json['health'];
    final cmd = json['cmd'];
    return RobotState(
      seq: json['seq'] is int ? json['seq'] as int : 0,
      pose: pose is List && pose.length == 3 && pose.every((v) => _num(v) != null)
          ? Pose(_num(pose[0])!, _num(pose[1])!, _num(pose[2])!)
          : null,
      mode: _str(json['mode'], 'auto'),
      nav: _str(json['nav'], 'NAV_INACTIVE'),
      navMessage: _str(json['nav_msg']),
      mission: _str(json['mission']),
      localization: _str(json['localization'], 'none'),
      recording: json['recording'] == true,
      battery: battery is Map
          ? Battery(
              percent: _num(battery['pct']),
              voltage: _num(battery['v']),
              current: _num(battery['a']),
              temperature: _num(battery['temp']),
            )
          : null,
      driverLevel: driver is Map && driver['level'] is int ? driver['level'] as int : null,
      driverMessage: driver is Map ? _str(driver['msg']) : '',
      cmd: cmd is List && cmd.length == 3
          ? cmd.map((v) => _num(v) ?? 0.0).toList()
          : const [0.0, 0.0, 0.0],
      healthOk: health is Map ? health['ok'] == true : null,
      healthIssues: health is Map ? _strings(health['issues']) : const [],
      estop: json['estop'] == true,
      field: json['field'] is String ? json['field'] as String : null,
      tags: _tags(json['tags']),
      inspection: InspectionStatus.fromJson(json['inspection']),
      people: PeopleStatus.fromJson(json['people']),
      load: SystemLoad.fromJson(health),
      speed: PatrolSpeed.fromJson(json['speed']),
    );
  }

  final int seq;
  final Pose? pose;

  /// `auto` (navigation drives) or `remote` (the handheld drives).
  final String mode;
  final String nav;
  final String navMessage;
  final String mission;
  final String localization;
  final bool recording;
  final Battery? battery;
  final int? driverLevel;
  final String driverMessage;

  /// Velocity actually sent to the robot [vx, vy, wz].
  final List<double> cmd;
  final bool? healthOk;
  final List<String> healthIssues;
  final bool estop;

  /// Protective field: clear, limited, stop, stale, off, or null.
  final String? field;

  /// AprilTags the robot sees in the camera image now.
  final List<Tag> tags;

  /// The VLM floor inspection; null when the robot runs none.
  final InspectionStatus? inspection;

  /// Person detection; null when the robot runs none.
  final PeopleStatus? people;

  /// CPU, GPU and memory use of the robot's computer, from its health monitor.
  final SystemLoad? load;

  /// Patrol speed of the navigation; null when navigation does not run.
  final PatrolSpeed? speed;

  bool get remote => mode == 'remote';
  bool get localized => localization.isNotEmpty && localization != 'none';

  /// Where map->odom comes from: none, start (identity at the start pose), tag, pose (RViz), other.
  String get localizationKind {
    if (!localized) return 'none';
    if (localization.startsWith('apriltag')) return 'tag';
    if (localization.startsWith('start')) return 'start';
    if (localization.contains('Pose Estimate')) return 'pose';
    return 'other';
  }

  /// The tag frame of a tag localization ('base_map' from 'apriltag "base_map" (auto start)').
  String? get localizationTag => RegExp(r'"([^"]+)"').firstMatch(localization)?.group(1);
  bool get navPaused => nav == 'PAUSED';
  bool get navActive => !const {'NAV_INACTIVE', 'NO_PATH', 'PAUSED'}.contains(nav);
}

/// An AprilTag in the camera image.
class Tag {
  const Tag(this.id, this.corners);

  final int id;

  /// x0, y0, ... x3, y3 as fractions of the image width and height.
  final List<double> corners;
}

class RoutePoint {
  const RoutePoint(this.x, this.y, this.dwell);

  final double x;
  final double y;

  /// Seconds the robot inspects here; 0 for a plain waypoint.
  final double dwell;

  bool get isStop => dwell > 0;
}

/// `state.inspection`: the robot's VLM floor inspection (anomaly_detector_node).
class InspectionStatus {
  const InspectionStatus({
    required this.on,
    required this.state,
    this.model = '',
    this.interval = 0,
    this.error = '',
    this.count = 0,
    this.reports = 0,
    this.last,
  });

  /// Null unless the robot sent an inspection object.
  static InspectionStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final last = json['last'];
    return InspectionStatus(
      on: json['on'] == true,
      state: _str(json['state'], 'offline'),
      model: _str(json['model']),
      interval: _num(json['interval']) ?? 0,
      error: _str(json['error']),
      count: _num(json['count'])?.round() ?? 0,
      reports: _num(json['reports'])?.round() ?? 0,
      last: last is Map ? InspectionResult.fromJson(last) : null,
    );
  }

  final bool on;

  /// loading, running, off, error, or offline (the robot stopped hearing from the detector).
  final String state;
  final String model;

  /// Seconds between inspections: 0 back to back, > 0 every N s, < 0 only at stop points.
  final double interval;
  final String error;

  /// Inspections since the detector started.
  final int count;

  /// Findings sent to NETRA since the detector started.
  final int reports;
  final InspectionResult? last;

  /// continuous, interval or stops.
  String get pace => interval < 0 ? 'stops' : (interval == 0 ? 'continuous' : 'interval');
}

/// The latest inspection the robot made.
class InspectionResult {
  const InspectionResult({
    required this.category,
    this.reported = false,
    this.latencyMs = 0,
    this.age,
    this.description = '',
    this.source = '',
  });

  factory InspectionResult.fromJson(Map<dynamic, dynamic> json) => InspectionResult(
    category: _str(json['cat'], 'none'),
    reported: json['reported'] == true,
    latencyMs: _num(json['ms'])?.round() ?? 0,
    age: _num(json['age'])?.round(),
    description: _str(json['desc']),
    source: _str(json['source']),
  );

  /// What the model saw: none for a clean floor, else a category such as trash or spill.
  final String category;

  /// Sent to NETRA as a finding.
  final bool reported;
  final int latencyMs;

  /// Seconds since this inspection; null when unknown.
  final int? age;
  final String description;

  /// periodic or stop_point.
  final String source;

  bool get clear => category.isEmpty || category == 'none';
}

/// A model the robot can inspect with (`inspection_models`).
class InspectionModel {
  const InspectionModel(this.name, {this.installed, this.active = false});

  /// Entries without a name are skipped.
  static List<InspectionModel> listFromJson(Object? data) {
    if (data is! List) return const [];
    final out = <InspectionModel>[];
    for (final item in data) {
      if (item is! Map) continue;
      final name = item['name'];
      if (name is! String || name.isEmpty) continue;
      final installed = item['installed'];
      out.add(
        InspectionModel(
          name,
          installed: installed is bool ? installed : null,
          active: item['active'] == true,
        ),
      );
    }
    return out;
  }

  final String name;

  /// Pulled into Ollama on the robot; null when the robot could not ask Ollama.
  final bool? installed;

  /// The model in use when the list was fetched.
  final bool active;
}

/// `state.speed`: the patrol speed and the range the handheld may set, m/s.
class PatrolSpeed {
  const PatrolSpeed(this.target, this.min, this.max);

  /// Null unless all three are numbers and 0 < min <= max.
  static PatrolSpeed? fromJson(Object? json) {
    if (json is! Map) return null;
    final target = _num(json['target']);
    final low = _num(json['min']);
    final high = _num(json['max']);
    if (target == null || low == null || high == null || low <= 0 || high < low) return null;
    return PatrolSpeed(target, low, high);
  }

  final double target;
  final double min;
  final double max;
}

/// `state.people`: the robot's person detection (person_detector_node).
class PeopleStatus {
  const PeopleStatus({
    required this.on,
    required this.state,
    this.count,
    this.latencyMs = 0,
    this.age,
    this.backend = '',
    this.error = '',
    this.boxes = const [],
  });

  /// Null unless the robot sent a people object.
  static PeopleStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return PeopleStatus(
      on: json['on'] == true,
      state: _str(json['state'], 'offline'),
      count: _num(json['count'])?.round(),
      latencyMs: _num(json['ms'])?.round() ?? 0,
      age: _num(json['age'])?.round(),
      backend: _str(json['backend']),
      error: _str(json['error']),
      boxes: _personBoxes(json['boxes']),
    );
  }

  static List<PersonBox> _personBoxes(Object? json) {
    if (json is! List) return const [];
    final boxes = <PersonBox>[];
    for (final row in json) {
      if (row is! List || row.length != 5) continue;
      final v = [for (final x in row) _num(x)];
      if (v.contains(null)) continue;
      boxes.add(PersonBox(v[0]!, v[1]!, v[2]!, v[3]!, v[4]!));
    }
    return boxes;
  }

  final bool on;

  /// People in the last frame, as fractions of the image; empty when that frame is old.
  final List<PersonBox> boxes;

  /// loading, running, off, error, or offline (the robot stopped hearing from the detector).
  final String state;

  /// People in the last frame the robot looked at; null before the first.
  final int? count;
  final int latencyMs;

  /// Seconds since that frame; null when unknown.
  final int? age;

  /// What runs the model, e.g. onnxruntime-cpu.
  final String backend;
  final String error;
}

/// The robot computer's load (`state.health`): percentages, memory in GB, hottest zone in C.
class SystemLoad {
  const SystemLoad({this.cpu, this.gpu, this.ram, this.ramUsed, this.ramTotal, this.temp});

  /// Null unless the health object carries at least one figure.
  static SystemLoad? fromJson(Object? json) {
    if (json is! Map) return null;
    final load = SystemLoad(
      cpu: _num(json['cpu']),
      gpu: _num(json['gpu']),
      ram: _num(json['ram']),
      ramUsed: _num(json['ram_used']),
      ramTotal: _num(json['ram_total']),
      temp: _num(json['temp']),
    );
    final figures = [load.cpu, load.gpu, load.ram, load.ramUsed, load.temp];
    return figures.every((v) => v == null) ? null : load;
  }

  final double? cpu;

  /// Null on a computer without a Jetson GPU.
  final double? gpu;
  final double? ram;
  final double? ramUsed;
  final double? ramTotal;
  final double? temp;
}

/// A detected person: corners as fractions of the camera image, and the detector's score.
class PersonBox {
  const PersonBox(this.x1, this.y1, this.x2, this.y2, this.score);

  final double x1, y1, x2, y2, score;
}
