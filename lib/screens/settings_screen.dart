import 'package:flutter/material.dart';
import 'package:gamepads/gamepads.dart';

import '../robot_actions.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/hud.dart';

/// Hidden settings (three taps on the version): robot address, token, language, controls.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.services});

  final Services services;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppSettings _settings = widget.services.settings;
  late final _host = TextEditingController(text: _settings.host);
  late final _port = TextEditingController(text: '${_settings.port}');
  late final _token = TextEditingController(text: _settings.token);
  late final _name = TextEditingController(text: _settings.handheldName);
  late String _language = _settings.language;
  late double _fps = _settings.cameraFps;
  late bool _deadman = _settings.deadman;
  late bool _camera = _settings.cameraOnStart;
  late bool _map = _settings.mapOnStart;
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

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim());
    await _settings.update(
      host: _host.text.trim().isEmpty ? AppSettings.defaultHost : _host.text,
      port: port != null && port > 0 && port < 65536 ? port : AppSettings.defaultPort,
      token: _token.text,
      handheldName: _name.text.trim().isEmpty ? 'Retroid' : _name.text,
      language: _language,
      cameraFps: _fps,
      deadman: _deadman,
      cameraOnStart: _camera,
      mapOnStart: _map,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('saved'))));
    Navigator.of(context).pop();
  }

  InputDecoration _field(String label, {Widget? suffix}) => InputDecoration(
    labelText: label,
    isDense: true,
    suffixIcon: suffix,
    border: const OutlineInputBorder(),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.night,
      body: SafeArea(
        child: Padding(
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
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check_rounded),
                    label: Text(t('save')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 6, child: _form()),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: _gamepadTest()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _form() {
    return ListView(
      padding: const EdgeInsets.only(left: 8, right: 4, bottom: 16),
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                decoration: _field(t('robot_address')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: _field(t('port')),
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
          decoration: _field(
            t('token'),
            suffix: IconButton(
              onPressed: () => setState(() => _showToken = !_showToken),
              icon: Icon(_showToken ? Icons.visibility_off_rounded : Icons.visibility_rounded),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(controller: _name, decoration: _field(t('handheld_name'))),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: Text(t('language'), style: Txt.label)),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'id', label: Text('Indonesia')),
                ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {_language},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => setState(() => _language = selection.first),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(t('camera_rate', {'n': _fps.round()}), style: Txt.label),
        Slider(
          value: _fps,
          min: 2,
          max: 15,
          divisions: 13,
          label: '${_fps.round()}',
          onChanged: (value) => setState(() => _fps = value),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(t('camera_start'), style: Txt.body),
          value: _camera,
          onChanged: (value) => setState(() => _camera = value),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(t('map_start'), style: Txt.body),
          value: _map,
          onChanged: (value) => setState(() => _map = value),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(t('deadman'), style: Txt.body),
          value: _deadman,
          onChanged: (value) => setState(() => _deadman = value),
        ),
      ],
    );
  }

  Widget _gamepadTest() {
    final pad = widget.services.gamepad;
    final help = [
      ('L stick', t('help_left')),
      ('R stick', t('help_right')),
      ('B', t('help_b')),
      ('Start', t('help_start')),
      ('Select', t('help_select')),
      ('D-pad', t('help_dpad')),
      ('L1 + A', robotAction('stand_up').label(_settings.language)),
      ('L1 + Y', robotAction('sit_down').label(_settings.language)),
      ('R1', t('help_r1')),
    ];
    return Glass(
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: ListenableBuilder(
        listenable: pad,
        builder: (context, _) {
          final pressed = GamepadButton.values.where(pad.pressed).map((b) => b.name).join('  ');
          return ListView(
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
              const SizedBox(height: 12),
              Text(t('controls'), style: Txt.label),
              const SizedBox(height: 6),
              for (final (control, meaning) in help)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      SizedBox(width: 64, child: Text(control, style: Txt.label)),
                      Expanded(child: Text(meaning, style: Txt.small)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
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
