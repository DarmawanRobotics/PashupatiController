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
};

double? _num(Object? value) => value is num && value.isFinite ? value.toDouble() : null;

String _str(Object? value, [String fallback = '']) => value is String ? value : fallback;

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const <String>[];

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

/// The robot's answer to `hello`.
class Welcome {
  const Welcome({
    required this.name,
    required this.commands,
    required this.robotCommands,
    required this.limits,
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
    );
  }

  final String name;
  final List<String> commands;

  /// The robot driver's commands (std_srvs/Trigger), in the order the robot lists them.
  final List<String> robotCommands;

  /// Speed maxima [vx m/s, vy m/s, wz rad/s].
  final List<double> limits;

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

  bool get remote => mode == 'remote';
  bool get localized => localization.isNotEmpty && localization != 'none';
  bool get navPaused => nav == 'PAUSED';
  bool get navActive => !const {'NAV_INACTIVE', 'NO_PATH', 'PAUSED'}.contains(nav);
}

class RoutePoint {
  const RoutePoint(this.x, this.y, this.dwell);

  final double x;
  final double y;

  /// Seconds the robot inspects here; 0 for a plain waypoint.
  final double dwell;

  bool get isStop => dwell > 0;
}
