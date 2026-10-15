import 'package:flutter/material.dart';
import 'package:gamepads/gamepads.dart';

import '../net/webrtc_video.dart';
import '../robot_actions.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/hud.dart';

/// Settings. Control, display and patrol apply at once (the gear while driving); the robot
/// connection and the gamepad test only in [admin] mode (three taps on the version).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.services, this.admin = false});

  final Services services;
  final bool admin;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _dwells = [5.0, 10.0, 30.0, 60.0];

  late final AppSettings _settings = widget.services.settings;
  late final _host = TextEditingController(text: _settings.host);
  late final _port = TextEditingController(text: '${_settings.port}');
  late final _token = TextEditingController(text: _settings.token);
  late final _name = TextEditingController(text: _settings.handheldName);
  late double _fps = _settings.cameraFps;
  bool _showToken = false;

  String t(String key, [Map<String, Object> args = const {}]) => widget.services.t(key, args);

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Keeps the connection fields: on Save and when leaving the page.
  Future<void> _saveConnection() async {
    final host = _host.text.trim().isEmpty ? AppSettings.defaultHost : _host.text.trim();
    final parsed = int.tryParse(_port.text.trim());
    final port = parsed != null && parsed > 0 && parsed < 65536 ? parsed : AppSettings.defaultPort;
    final name = _name.text.trim().isEmpty ? 'Retroid' : _name.text.trim();
    final token = _token.text;
    if (host == _settings.host &&
        port == _settings.port &&
        token == _settings.token &&
        name == _settings.handheldName) {
      return;
    }
    await _settings.update(host: host, port: port, token: token, handheldName: name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('saved'))));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && widget.admin) _saveConnection();
      },
      child: Scaffold(
        backgroundColor: Palette.night,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _settings,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      Expanded(child: Text(t('settings'), style: Txt.title)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 6, child: _form()),
                        const SizedBox(width: 16),
                        Expanded(flex: 5, child: _controls()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form() {
    final gear = _settings.gear;
    final share = AppSettings.speedScale[gear - 1];
    final limits = widget.services.client.welcome?.limits;
    final dwell = _dwells.reduce(
      (a, b) => (a - _settings.stopDwell).abs() <= (b - _settings.stopDwell).abs() ? a : b,
    );
    return ListView(
      padding: const EdgeInsets.only(left: 8, right: 4, bottom: 16),
      children: [
        _section(t('section_control')),
        _choice(
          t('speed'),
          SegmentedButton<int>(
            segments: [
              for (var level = 1; level <= 3; level++)
                ButtonSegment(value: level, label: Text('$level  ${t('speed_$level')}')),
            ],
            selected: {gear},
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            onSelectionChanged: (selection) => _settings.update(gear: selection.first),
          ),
          hint: limits == null
              ? t('speed_share', {'p': (share * 100).round()})
              : t('speed_max', {'v': (limits[0] * share).toStringAsFixed(2)}),
        ),
        _switch(t('deadman'), _settings.deadman, (value) => _settings.update(deadman: value)),

        _section(t('section_display')),
        _switch(t('video'), _settings.video, (value) => _settings.update(video: value)),
        _videoStatus(),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            t('camera_rate', {'n': _fps.round()}),
            style: Txt.body.copyWith(color: _settings.video ? Palette.text : Palette.muted),
          ),
        ),
        Slider(
          value: _fps,
          min: 2,
          max: 15,
          divisions: 13,
          label: '${_fps.round()}',
          onChanged: _settings.video ? (value) => setState(() => _fps = value) : null,
          onChangeEnd: (value) => _settings.update(cameraFps: value),
        ),
        _switch(t('lidar_on_map'), _settings.lidar, (value) => _settings.update(lidar: value)),
        _switch(t('show_load'), _settings.showLoad, (value) => _settings.update(showLoad: value)),
        _choice(
          t('language'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'id', label: Text('Indonesia')),
              ButtonSegment(value: 'en', label: Text('English')),
            ],
            selected: {_settings.language},
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            onSelectionChanged: (selection) => _settings.update(language: selection.first),
          ),
        ),

        _section(t('section_patrol')),
        _choice(
          t('stop_dwell'),
          SegmentedButton<double>(
            segments: [
              for (final value in _dwells)
                ButtonSegment(value: value, label: Text('${value.round()} s')),
            ],
            selected: {dwell},
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            onSelectionChanged: (selection) => _settings.update(stopDwell: selection.first),
          ),
          hint: t('stop_dwell_hint'),
        ),

        if (widget.admin) ..._connection(),
      ],
    );
  }

  List<Widget> _connection() {
    InputDecoration field(String label, {Widget? suffix}) => InputDecoration(
      labelText: label,
      isDense: true,
      suffixIcon: suffix,
      border: const OutlineInputBorder(),
    );
    return [
      _section(t('section_connection')),
      Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: field(t('robot_address')),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: field(t('port')),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _token,
        obscureText: !_showToken,
        autocorrect: false,
        enableSuggestions: false,
        decoration: field(
          t('token'),
          suffix: IconButton(
            onPressed: () => setState(() => _showToken = !_showToken),
            icon: Icon(_showToken ? Icons.visibility_off_rounded : Icons.visibility_rounded),
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(controller: _name, decoration: field(t('handheld_name'))),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: _saveConnection,
          icon: const Icon(Icons.check_rounded),
          label: Text(t('save')),
        ),
      ),
    ];
  }

  /// How the camera arrives now: WebRTC, or JPEG frames over the teleop link.
  Widget _videoStatus() {
    final video = widget.services.video;
    final client = widget.services.client;
    return ListenableBuilder(
      listenable: Listenable.merge([video, client]),
      builder: (context, _) {
        final String? text = !_settings.video || !client.isLive
            ? null
            : switch (video.link) {
                VideoLink.playing => t('video_webrtc'),
                VideoLink.connecting => t('video_connecting'),
                VideoLink.failed => t('video_failed', {'why': video.error}),
                VideoLink.off => client.welcome?.video == null ? t('video_jpeg') : null,
              };
        if (text == null) return const SizedBox.shrink();
        final color = video.link == VideoLink.failed ? Palette.caution : Palette.muted;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(text, style: Txt.small.copyWith(color: color)),
        );
      },
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        title.toUpperCase(),
        style: Txt.small.copyWith(
          color: Palette.auto,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _choice(String label, Widget control, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Txt.body),
          const SizedBox(height: 6),
          control,
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint, style: Txt.small),
          ],
        ],
      ),
    );
  }

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: Txt.body),
      value: value,
      onChanged: onChanged,
    );
  }

  /// Gamepad controls; with the gamepad test in admin mode (pressing buttons here while
  /// connected would drive the robot).
  Widget _controls() {
    final language = _settings.language;
    final help = [
      ('L stick', t('help_left')),
      ('R stick', t('help_right')),
      ('B', t('help_b')),
      ('Start', t('help_start')),
      ('Select', t('help_select')),
      ('D-pad', t('help_dpad')),
      ('L1 + A', robotAction('stand_up').label(language)),
      ('L1 + Y', robotAction('sit_down').label(language)),
      ('R1', t('help_r1')),
    ];
    return Glass(
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          if (widget.admin) ...[
            _gamepadTest(),
            const SizedBox(height: 14),
          ],
          Text(t('controls'), style: Txt.title),
          const SizedBox(height: 8),
          for (final (control, meaning) in help)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  SizedBox(width: 64, child: Text(control, style: Txt.label)),
                  Expanded(child: Text(meaning, style: Txt.small)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _gamepadTest() {
    final pad = widget.services.gamepad;
    return ListenableBuilder(
      listenable: pad,
      builder: (context, _) {
        final pressed = GamepadButton.values.where(pad.pressed).map((b) => b.name).join('  ');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('gamepad_test'), style: Txt.title),
            const SizedBox(height: 8),
            SizedBox(
              height: 74,
              child: Row(
                children: [
                  _StickDot(
                    x: pad.axis(GamepadAxis.leftStickX),
                    y: pad.axis(GamepadAxis.leftStickY),
                  ),
                  const SizedBox(width: 12),
                  _StickDot(
                    x: pad.axis(GamepadAxis.rightStickX),
                    y: pad.axis(GamepadAxis.rightStickY),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      pressed.isEmpty ? t('gamepad_none') : pressed,
                      style: Txt.small.copyWith(color: Palette.text),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(pad.lastEvent, style: Txt.small),
          ],
        );
      },
    );
  }
}

/// One stick of the physical gamepad as a dot in a circle.
class _StickDot extends StatelessWidget {
  const _StickDot({required this.x, required this.y});

  final double x;
  final double y;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 70,
      child: CustomPaint(painter: _StickDotPainter(x, y)),
    );
  }
}

class _StickDotPainter extends CustomPainter {
  _StickDotPainter(this.x, this.y);

  final double x;
  final double y;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 4;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Palette.line,
    );
    canvas.drawCircle(
      center + Offset(x * radius, -y * radius),
      6,
      Paint()..color = Palette.remote,
    );
  }

  @override
  bool shouldRepaint(_StickDotPainter oldDelegate) => oldDelegate.x != x || oldDelegate.y != y;
}
