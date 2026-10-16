import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../net/teleop_client.dart';
import '../protocol/messages.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/hud.dart';
import 'drive_screen.dart';
import 'settings_screen.dart';

const appVersion = '2.6.1'; // the version in pubspec.yaml (test/version_test.dart)

/// Robot picker: the main robot from the settings plus every robot that answers on the LAN.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.services});

  final Services services;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );
  String? _target;
  int _versionTaps = 0;
  DateTime _firstTap = DateTime.fromMillisecondsSinceEpoch(0);

  Services get s => widget.services;

  @override
  void initState() {
    super.initState();
    s.client.addListener(_onClient);
    _startScan();
  }

  @override
  void dispose() {
    s.client.removeListener(_onClient);
    s.discovery.stop();
    _sweep.dispose();
    super.dispose();
  }

  void _startScan() {
    s.discovery.start(port: s.settings.port, directHost: s.settings.host);
    _sweep.repeat();
  }

  void _stopScan() {
    s.discovery.stop();
    _sweep.stop();
  }

  void _connect(String host) {
    final settings = s.settings;
    final client = s.client
      ..handheldName = settings.handheldName
      ..setStreams(camera: settings.video, lidar: settings.lidar, fps: settings.cameraFps);
    setState(() => _target = host);
    client.connect(host: host, port: settings.port, token: settings.token);
  }

  void _onClient() {
    if (_target == null || !mounted) return;
    switch (s.client.status) {
      case LinkStatus.connected:
        _target = null;
        _stopScan();
        Navigator.of(context)
            .push(
              PageRouteBuilder<void>(
                transitionDuration: const Duration(milliseconds: 260),
                pageBuilder: (context, animation, secondary) => DriveScreen(services: s),
                transitionsBuilder: (context, animation, secondary, child) =>
                    FadeTransition(opacity: animation, child: child),
              ),
            )
            .then((_) {
              if (mounted) setState(_startScan);
            });
      case LinkStatus.denied:
      case LinkStatus.busy:
      case LinkStatus.unreachable:
        setState(() => _target = null);
      case LinkStatus.idle:
      case LinkStatus.connecting:
      case LinkStatus.lost:
        break;
    }
  }

  void _onVersionTap() {
    if (_target != null) return; // connecting: the drive screen opens next
    final now = DateTime.now();
    if (now.difference(_firstTap) > const Duration(milliseconds: 1500)) {
      _firstTap = now;
      _versionTaps = 0;
    }
    _versionTaps++;
    if (_versionTaps < 3) return;
    _versionTaps = 0;
    _stopScan();
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (context) => SettingsScreen(services: s, admin: true),
          ),
        )
        .then((_) {
          if (mounted) setState(_startScan);
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.night,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([s.discovery, s.client, s.settings]),
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: _brand(context)),
                const SizedBox(width: 20),
                Expanded(flex: 6, child: _robots()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _brand(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Image.asset('assets/images/logo.png', width: 44, height: 44),
            const SizedBox(width: 12),
            Flexible(child: Text('PASHUPATI', style: Txt.display.copyWith(letterSpacing: 3))),
          ],
        ),
        const SizedBox(height: 4),
        Text(s.t('tagline'), style: Txt.body.copyWith(color: Palette.muted)),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: AnimatedBuilder(
                animation: _sweep,
                builder: (context, _) => CustomPaint(
                  painter: _RadarPainter(
                    angle: still ? null : _sweep.value * 2 * math.pi,
                    blips: s.discovery.robots.length,
                  ),
                ),
              ),
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onVersionTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(s.t('version', {'v': appVersion}), style: Txt.small),
          ),
        ),
      ],
    );
  }

  Widget _robots() {
    final settings = s.settings;
    final client = s.client;
    final mainHost = settings.host;
    final others = s.discovery.robots.where((b) => b.host != mainHost).toList();
    final error = switch (client.status) {
      LinkStatus.denied => '${s.t('denied')}. ${s.t('denied_hint')}',
      LinkStatus.busy =>
        client.statusDetail.isEmpty ? s.t('busy') : '${s.t('busy')}: ${client.statusDetail}',
      LinkStatus.unreachable =>
        '${s.t('unreachable')}. ${s.t('unreachable_hint', {'host': client.host})}',
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(s.t('robots'), style: Txt.title)),
            if (s.discovery.scanning)
              Text(s.t('scanning'), style: Txt.small)
            else
              TextButton.icon(
                onPressed: () => setState(_startScan),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(s.t('retry')),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            children: [
              _RobotTile(
                title: s.discovery.beaconOf(mainHost)?.name ?? s.t('main_robot'),
                beacon: s.discovery.beaconOf(mainHost),
                host: mainHost,
                inUseLabel: _inUse,
                connecting: _target == mainHost,
                onTap: _target == null ? () => _connect(mainHost) : null,
              ),
              for (final beacon in others) ...[
                const SizedBox(height: 8),
                _RobotTile(
                  title: beacon.name,
                  beacon: beacon,
                  host: beacon.host,
                  inUseLabel: _inUse,
                  connecting: _target == beacon.host,
                  onTap: _target == null ? () => _connect(beacon.host) : null,
                ),
              ],
              if (others.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(s.t('no_robots'), style: Txt.small),
                ),
            ],
          ),
        ),
        if (error != null)
          Glass(
            color: Palette.glassHigh,
            border: Palette.stop.withValues(alpha: 0.6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, color: Palette.stop, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(error, style: Txt.small.copyWith(color: Palette.text))),
              ],
            ),
          ),
      ],
    );
  }

  String _inUse(String who) => s.t('in_use_by', {'who': who});
}

class _RobotTile extends StatelessWidget {
  const _RobotTile({
    required this.title,
    required this.beacon,
    required this.host,
    required this.inUseLabel,
    required this.connecting,
    required this.onTap,
  });

  final String title;
  final Beacon? beacon;
  final String host;
  final String Function(String who) inUseLabel;
  final bool connecting;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final beacon = this.beacon;
    final online = beacon != null;
    final inUseBy = beacon?.inUseBy ?? '';
    final inUse = inUseBy.isNotEmpty;
    final battery = beacon?.battery;
    final mode = beacon?.mode;
    return Material(
      color: Palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: connecting ? Palette.remote : Palette.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online ? (inUse ? Palette.caution : Palette.ok) : Palette.line,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Txt.label.copyWith(fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      inUse ? '$host   ${inUseLabel(inUseBy)}' : host,
                      style: Txt.small,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (beacon?.secured ?? false)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Icon(Icons.lock_outline_rounded, size: 16, color: Palette.muted),
                ),
              if (mode != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    mode.toUpperCase(),
                    style: Txt.small.copyWith(
                      color: Palette.forMode(mode),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (battery != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text('${battery.round()}%', style: Txt.figure.copyWith(fontSize: 13)),
                ),
              if (connecting)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Palette.remote),
                )
              else
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 20,
                  color: onTap == null ? Palette.line : Palette.text,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rings with a sweeping beam while the handheld looks for robots.
class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.angle, required this.blips});

  final double? angle;
  final int blips;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 * 0.92;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Palette.line;
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(center, radius * i / 3, ring);
    }
    canvas.drawLine(center.translate(-radius, 0), center.translate(radius, 0), ring);
    canvas.drawLine(center.translate(0, -radius), center.translate(0, radius), ring);

    final angle = this.angle;
    if (angle != null) {
      final beam = Paint()
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: math.pi / 2,
          colors: [Palette.auto.withValues(alpha: 0), Palette.auto.withValues(alpha: 0.35)],
          transform: GradientRotation(angle - math.pi / 2),
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        angle - math.pi / 2,
        math.pi / 2,
        true,
        beam,
      );
    }

    // one blip per robot heard, at fixed spots so they do not jump around
    final blip = Paint()..color = Palette.auto;
    for (var i = 0; i < math.min(blips, 6); i++) {
      final a = 0.9 + i * 1.7;
      final r = radius * (0.35 + 0.1 * (i % 4));
      canvas.drawCircle(center + Offset(math.cos(a) * r, math.sin(a) * r), 4, blip);
    }
    canvas.drawCircle(center, 5, Paint()..color = Palette.remote);
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) =>
      oldDelegate.angle != angle || oldDelegate.blips != blips;
}
