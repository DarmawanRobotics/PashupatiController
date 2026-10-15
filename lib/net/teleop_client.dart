import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../protocol/messages.dart';
import '../protocol/streams.dart';

enum LinkStatus {
  /// Not connected and not trying.
  idle,

  /// Sending `hello` until the robot answers.
  connecting,

  /// Session up, telemetry arriving.
  connected,

  /// Was connected, telemetry stopped; reconnecting on its own.
  lost,

  /// The robot rejected the token.
  denied,

  /// Another handheld is driving.
  busy,

  /// No answer, or the address cannot be reached.
  unreachable,
}

class CommandResult {
  const CommandResult(this.ok, this.message, [this.data]);

  final bool ok;
  final String message;
  final Object? data;
}

/// Runs a command from the UI: tracks it as busy and reports the result (quiet: failures only).
typedef RunCommand =
    Future<CommandResult> Function(
      String name, {
      Map<String, Object?> args,
      String? label,
      bool quiet,
    });

class _Pending {
  _Pending(this.id, this.name, this.args);

  final int id;
  final String name;
  final Map<String, Object?> args;
  final completer = Completer<CommandResult>();
  final started = DateTime.now();
  DateTime lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// The robot answered `ok: null`: it is running the command.
  bool accepted = false;
}

/// UDP client of one robot: session, telemetry, commands, joystick and streams.
class TeleopClient extends ChangeNotifier {
  static const _tick = Duration(milliseconds: 50);
  static const _helloConnecting = Duration(milliseconds: 300);
  static const _helloLost = Duration(seconds: 1);
  static const _connectTimeout = Duration(seconds: 6);
  static const _stateTimeout = Duration(milliseconds: 1500);
  /// No answer at all; once the robot answered `pending`, slow actions get [_runTimeout].
  static const _commandTimeout = Duration(seconds: 8);
  static const _runTimeout = Duration(seconds: 90);

  RawDatagramSocket? _socket;
  InternetAddress? _address;
  String _host = '';
  int _port = 9870;
  String _token = '';
  String handheldName = 'handheld';
  Timer? _timer;
  final _reassembler = Reassembler();
  final _pending = <int, _Pending>{};
  int _nextId = Random().nextInt(1 << 30) + 1;
  int _attempt = 0;
  Future<RawDatagramSocket>? _binding;

  DateTime _connectStarted = DateTime.now();
  DateTime _lastHello = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPing = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastState = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSeq = 0;

  LinkStatus status = LinkStatus.idle;

  /// Robot message for busy / unreachable.
  String statusDetail = '';
  Welcome? welcome;
  RobotState state = const RobotState();
  String get host => _host;

  /// Round trip in ms (smoothed), null before the first pong.
  double? rttMs;

  /// Share of telemetry messages lost recently, 0..1.
  double loss = 0;

  /// Where the robot has been in this session (map frame), for the map.
  final trail = <Offset>[];

  final cameraFrame = ValueNotifier<Uint8List?>(null);
  final lidarPoints = ValueNotifier<Float32List?>(null);
  final routePoints = ValueNotifier<List<RoutePoint>>(const []);

  bool cameraEnabled = true;
  bool lidarEnabled = true;
  double cameraFps = 8;

  double _vx = 0, _vy = 0, _wz = 0;

  bool get isLive => status == LinkStatus.connected || status == LinkStatus.lost;

  /// Signal strength 0..3 from latency and loss, for the link indicator.
  int get signal {
    if (status != LinkStatus.connected) return 0;
    final rtt = rttMs ?? 999;
    var bars = rtt < 60 ? 3 : (rtt < 150 ? 2 : 1);
    if (loss > 0.2) bars = min(bars, 1);
    return bars;
  }

  /// Starts a session with the robot at host:port (IP address or name).
  Future<void> connect({
    required String host,
    required int port,
    required String token,
  }) async {
    disconnect();
    final attempt = ++_attempt;
    _host = host;
    _port = port;
    _token = token;
    _setStatus(LinkStatus.connecting);
    try {
      final address = await _resolve(host);
      final socket = await (_binding ??= _bind());
      if (attempt != _attempt || status != LinkStatus.connecting) return; // superseded
      _address = address;
      _socket = socket;
    } on SocketException catch (error) {
      if (attempt == _attempt) _setStatus(LinkStatus.unreachable, detail: error.message);
      return;
    }
    _connectStarted = DateTime.now();
    _lastHello = DateTime.fromMillisecondsSinceEpoch(0);
    _timer?.cancel();
    _timer = Timer.periodic(_tick, _onTick);
  }

  Future<RawDatagramSocket> _bind() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _growReceiveBuffer(socket);
      socket.listen(_onSocketEvent, onError: (Object _) {});
      return socket;
    } on SocketException {
      _binding = null; // try again on the next connect
      rethrow;
    }
  }

  /// Room for a whole camera frame, which arrives as one burst of datagrams (the default buffer
  /// overflows and one lost datagram loses the frame).
  static void _growReceiveBuffer(RawDatagramSocket socket) {
    if (!Platform.isAndroid && !Platform.isLinux) return;
    const soRcvbuf = 8; // SO_RCVBUF on Linux and Android
    try {
      socket.setRawOption(RawSocketOption.fromInt(RawSocketOption.levelSocket, soRcvbuf, 1 << 20));
    } on Exception {
      // keep the system default
    }
  }

  /// Retries the last robot after denied / busy / unreachable.
  Future<void> retry() => connect(host: _host, port: _port, token: _token);

  /// Leaves the session; the robot zeroes the remote velocity at once.
  void disconnect() {
    if (isLive) {
      _send({'t': 'joy', 'vx': 0.0, 'vy': 0.0, 'wz': 0.0});
      _send({'t': 'bye'});
    }
    _attempt++;
    _timer?.cancel();
    _timer = null;
    _failPending('disconnected');
    _reassembler.reset();
    _vx = _vy = _wz = 0;
    welcome = null;
    state = const RobotState();
    rttMs = null;
    loss = 0;
    trail.clear();
    cameraFrame.value = null;
    lidarPoints.value = null;
    routePoints.value = const [];
    _address = null; // late datagrams of this robot are ignored from now on
    _setStatus(LinkStatus.idle);
  }

  @override
  void dispose() {
    disconnect();
    _socket?.close();
    cameraFrame.dispose();
    lidarPoints.dispose();
    routePoints.dispose();
    super.dispose();
  }

  /// Joystick velocity in m/s and rad/s; sent at 20 Hz while the robot is in REMOTE mode.
  void drive(double vx, double vy, double wz) {
    _vx = vx;
    _vy = vy;
    _wz = wz;
  }

  /// Runs a named command and completes with the robot's acknowledgement.
  Future<CommandResult> command(String name, [Map<String, Object?> args = const {}]) {
    if (status != LinkStatus.connected) {
      return Future.value(const CommandResult(false, 'not connected'));
    }
    final pending = _Pending(_nextId++, name, args);
    _pending[pending.id] = pending;
    _sendCommand(pending);
    return pending.completer.future;
  }

  Future<CommandResult> setMode(String mode) => command('set_mode', {'mode': mode});

  /// Latches the software e-stop on the robot (only zero velocity reaches it).
  Future<CommandResult> estop() {
    drive(0, 0, 0);
    return command('estop');
  }

  /// Forgets where the robot has been (a new route recording starts); shown on the next state.
  void clearTrail() => trail.clear();

  /// Turns the camera / lidar streams on or off, and sets the camera rate.
  void setStreams({bool? camera, bool? lidar, double? fps}) {
    cameraEnabled = camera ?? cameraEnabled;
    lidarEnabled = lidar ?? lidarEnabled;
    cameraFps = fps ?? cameraFps;
    if (!cameraEnabled) cameraFrame.value = null;
    if (!lidarEnabled) lidarPoints.value = null;
    if (isLive) _send({'t': 'streams', ..._streams()});
    notifyListeners();
  }

  // ---------------------------------------------------------------- internals

  Map<String, Object?> _streams() => {
    'camera': cameraEnabled,
    'lidar': lidarEnabled,
    'camera_fps': cameraFps,
  };

  Future<InternetAddress> _resolve(String host) async {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return ip;
    final found = await InternetAddress.lookup(host);
    if (found.isEmpty) throw SocketException('cannot resolve $host');
    return found.firstWhere(
      (a) => a.type == InternetAddressType.IPv4,
      orElse: () => found.first,
    );
  }

  void _setStatus(LinkStatus value, {String detail = ''}) {
    status = value;
    statusDetail = detail;
    notifyListeners();
  }

  void _send(Map<String, Object?> message) {
    final socket = _socket;
    final address = _address;
    if (socket == null || address == null) return;
    message['k'] = _token;
    try {
      socket.send(utf8.encode(jsonEncode(message)), address, _port);
    } on SocketException {
      // Wi-Fi gone: the link check reports it, the next tick tries again.
    }
  }

  void _sendHello() {
    _lastHello = DateTime.now();
    _send({'t': 'hello', 'name': handheldName, 'streams': _streams()});
  }

  void _sendCommand(_Pending pending) {
    pending.lastSent = DateTime.now();
    _send({'t': 'cmd', 'id': pending.id, 'name': pending.name, 'args': pending.args});
  }

  void _failPending(String reason) {
    for (final pending in _pending.values) {
      pending.completer.complete(CommandResult(false, reason));
    }
    _pending.clear();
  }

  void _onTick(Timer timer) {
    final now = DateTime.now();
    switch (status) {
      case LinkStatus.connecting:
        if (now.difference(_lastHello) >= _helloConnecting) _sendHello();
        if (now.difference(_connectStarted) > _connectTimeout) {
          _timer?.cancel();
          _timer = null;
          _setStatus(LinkStatus.unreachable, detail: _host);
        }
      case LinkStatus.lost:
        if (now.difference(_lastHello) >= _helloLost) _sendHello();
        _resendCommands(now);
      case LinkStatus.connected:
        if (now.difference(_lastState) > _stateTimeout) {
          _setStatus(LinkStatus.lost);
          return;
        }
        if (now.difference(_lastPing) >= const Duration(seconds: 1)) {
          _lastPing = now;
          _send({'t': 'ping', 'ts': now.millisecondsSinceEpoch});
        }
        if (state.remote && !state.estop) {
          _send({'t': 'joy', 'vx': _vx, 'vy': _vy, 'wz': _wz});
        }
        _resendCommands(now);
      case LinkStatus.idle:
      case LinkStatus.denied:
      case LinkStatus.busy:
      case LinkStatus.unreachable:
        break;
    }
  }

  void _resendCommands(DateTime now) {
    for (final pending in _pending.values.toList()) {
      if (now.difference(pending.started) > (pending.accepted ? _runTimeout : _commandTimeout)) {
        _pending.remove(pending.id);
        pending.completer.complete(const CommandResult(false, 'timeout'));
        continue;
      }
      final every = pending.accepted
          ? const Duration(seconds: 1)
          : const Duration(milliseconds: 250);
      if (now.difference(pending.lastSent) >= every) _sendCommand(pending);
    }
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    while (true) {
      final Datagram? datagram;
      try {
        datagram = socket.receive();
      } on SocketException {
        break;
      }
      if (datagram == null) break;
      if (datagram.address.address != _address?.address || datagram.port != _port) continue;
      _onDatagram(datagram.data);
    }
  }

  void _onDatagram(Uint8List data) {
    if (data.isEmpty || !(isLive || status == LinkStatus.connecting)) return;
    if (data[0] != 0x7B) {
      final frame = _reassembler.push(data);
      if (frame != null && isLive) _onFrame(frame);
      return;
    }
    Object? message;
    try {
      message = jsonDecode(utf8.decode(data));
    } on FormatException {
      return;
    }
    if (message is Map<String, dynamic>) _onMessage(message);
  }

  void _onMessage(Map<String, dynamic> message) {
    final now = DateTime.now();
    switch (message['t']) {
      case 'welcome':
        welcome = Welcome.fromJson(message);
        _lastState = now;
        if (status != LinkStatus.connected) {
          // A new session: the robot forgot the old command ids and restarts its frame counters.
          _failPending('connection reset');
          _reassembler.reset();
          _lastSeq = 0;
          _setStatus(LinkStatus.connected);
        } else {
          notifyListeners();
        }
      case 'state':
        if (!isLive) return;
        final next = RobotState.fromJson(message);
        _trackLoss(next.seq);
        _trackTrail(next.pose);
        state = next;
        _lastState = now;
        if (status == LinkStatus.lost) {
          _setStatus(LinkStatus.connected);
        } else {
          notifyListeners();
        }
      case 'ack':
        final pending = _pending[message['id']];
        if (pending == null) return;
        final ok = message['ok'];
        if (ok == null) {
          pending.accepted = true;
          return;
        }
        _pending.remove(pending.id);
        final text = message['msg'];
        pending.completer.complete(
          CommandResult(ok == true, text is String ? text : '', message['data']),
        );
      case 'pong':
        final ts = message['ts'];
        if (ts is int) {
          final rtt = (now.millisecondsSinceEpoch - ts).toDouble();
          rttMs = rttMs == null ? rtt : rttMs! * 0.7 + rtt * 0.3;
        }
      case 'busy':
        if (status == LinkStatus.connecting || status == LinkStatus.lost) {
          _timer?.cancel();
          _timer = null;
          _failPending('busy');
          final text = message['msg'];
          _setStatus(LinkStatus.busy, detail: text is String ? text : '');
        }
      case 'denied':
        _timer?.cancel();
        _timer = null;
        _failPending('denied');
        _setStatus(LinkStatus.denied);
      case 'bye':
        if (status == LinkStatus.connected) _setStatus(LinkStatus.lost);
    }
  }

  void _trackTrail(Pose? pose) {
    if (pose == null) return;
    final here = Offset(pose.x, pose.y);
    if (trail.isNotEmpty && (trail.last - here).distance < 0.1) return;
    trail.add(here);
    if (trail.length > 3000) trail.removeRange(0, 1000);
  }

  void _trackLoss(int seq) {
    if (_lastSeq > 0 && seq > _lastSeq) {
      final missed = min(seq - _lastSeq - 1, 50);
      loss = loss * 0.9 + (missed / (missed + 1)) * 0.1;
    }
    _lastSeq = seq;
  }

  void _onFrame(StreamFrame frame) {
    switch (frame.stream) {
      case streamCamera:
        if (cameraEnabled) cameraFrame.value = frame.payload;
      case streamLidar:
        if (lidarEnabled) lidarPoints.value = decodePoints(frame.payload);
      case streamRoute:
        routePoints.value = decodeRoute(frame.payload);
    }
  }
}
