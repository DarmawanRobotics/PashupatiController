import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../protocol/messages.dart';

/// Finds robots on the LAN: broadcasts `discover` and collects the `beacon` answers.
class Discovery extends ChangeNotifier {
  static const _every = Duration(seconds: 2);
  static const _forget = Duration(seconds: 7);

  RawDatagramSocket? _socket;
  Future<void>? _binding;
  Timer? _timer;
  bool _wanted = false;
  int _port = 9870;
  String _directHost = '';
  final _robots = <String, Beacon>{};

  /// Robots heard recently, by name.
  List<Beacon> get robots => _robots.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  Beacon? beaconOf(String host) => _robots[host];

  bool get scanning => _timer != null;

  /// Probes every 2 s; [directHost] also gets a unicast probe (networks that drop broadcasts).
  Future<void> start({required int port, String directHost = ''}) async {
    _wanted = true;
    _port = port;
    _directHost = directHost;
    await (_binding ??= _bind());
    if (!_wanted || _socket == null) return; // stopped while binding, or no network
    _timer?.cancel();
    _timer = Timer.periodic(_every, (_) => _probe());
    _probe();
    notifyListeners();
  }

  Future<void> _bind() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.listen(_onEvent, onError: (Object _) {});
      _socket = socket;
    } on SocketException {
      _binding = null; // try again on the next start
    }
  }

  void stop() {
    _wanted = false;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _socket?.close();
    super.dispose();
  }

  void _probe() {
    final socket = _socket;
    if (socket == null) return;
    final probe = utf8.encode(jsonEncode({'t': 'discover'}));
    final targets = [InternetAddress('255.255.255.255', type: InternetAddressType.IPv4)];
    final direct = InternetAddress.tryParse(_directHost);
    if (direct != null) targets.add(direct);
    for (final target in targets) {
      try {
        socket.send(probe, target, _port);
      } on SocketException {
        // no network yet
      }
    }
    final now = DateTime.now();
    final before = _robots.length;
    _robots.removeWhere((_, beacon) => now.difference(beacon.seen) > _forget);
    if (_robots.length != before) notifyListeners();
  }

  void _onEvent(RawSocketEvent event) {
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
      Object? message;
      try {
        message = jsonDecode(utf8.decode(datagram.data));
      } on FormatException {
        continue;
      }
      if (message is Map<String, dynamic> && message['t'] == 'beacon') {
        final host = datagram.address.address;
        _robots[host] = Beacon.fromJson(message, host);
        notifyListeners();
      }
    }
  }
}
