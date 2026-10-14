import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import '../input/gamepad_input.dart';
import '../net/teleop_client.dart';
import '../robot_actions.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/actions_panel.dart';
import '../widgets/camera_view.dart';
import '../widgets/hud.dart';
import '../widgets/lidar_map.dart';
import '../widgets/patrol_panel.dart';
import '../widgets/stick.dart';

enum _Panel { none, actions, patrol }

/// Live driving: camera, sticks, mode, e-stop, robot actions and patrol controls.
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key, required this.services});

  final Services services;

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  /// Share of the robot's speed limits per gear.
  static const _gearScale = [0.3, 0.6, 1.0];

  Services get s => widget.services;
  TeleopClient get client => widget.services.client;

  Offset _move = Offset.zero;
  Offset _turn = Offset.zero;
  late int _gear = widget.services.settings.gear;
  late bool _showMap = widget.services.settings.mapOnStart;
  _Panel _panel = _Panel.none;
  final Set<String> _busy = {};
  Toast? _toast;
  Timer? _toastTimer;
  Timer? _loop;
  bool _hinted = false;
  bool _suspended = false;
  StreamSubscription<GamepadButton>? _buttons;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _loop = Timer.periodic(const Duration(milliseconds: 50), (_) => _drive());
    _buttons = s.gamepad.presses.listen(_onButton);
    _lifecycle = AppLifecycleListener(onPause: _suspend, onResume: _resume);
  }

  @override
  void dispose() {
    _loop?.cancel();
    _toastTimer?.cancel();
    _buttons?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- input

  /// 20 Hz: touch sticks win over the gamepad; the client only sends in REMOTE mode.
  void _drive() {
    var x = _move.dx, y = _move.dy, r = _turn.dx;
    if (_move == Offset.zero && _turn == Offset.zero) {
      final pad = s.gamepad;
      if (!s.settings.deadman || pad.pressed(GamepadButton.rightBumper)) {
        x = GamepadInput.shaped(pad.axis(GamepadAxis.leftStickX));
        y = GamepadInput.shaped(pad.axis(GamepadAxis.leftStickY));
        r = GamepadInput.shaped(pad.axis(GamepadAxis.rightStickX));
      }
    }
    final limits = client.welcome?.limits ?? const [0.5, 0.3, 1.0];
    final scale = _gearScale[_gear - 1];
    // stick up = forward (+x), stick right = right (-y), turn right = clockwise (-z)
    client.drive(y * limits[0] * scale, -x * limits[1] * scale, -r * limits[2] * scale);

    final pushing = math.max(math.max(x.abs(), y.abs()), r.abs()) > 0.4;
    if (pushing &&
        !_hinted &&
        client.status == LinkStatus.connected &&
        !client.state.remote &&
        !client.state.estop) {
      _hinted = true;
      _show(Toast(s.t('auto_hint'), color: Palette.auto, icon: Icons.info_outline_rounded));
    }
    if (!pushing) _hinted = false;
  }

  void _onButton(GamepadButton button) {
    final shift = s.gamepad.pressed(GamepadButton.leftBumper);
    switch (button) {
      case GamepadButton.b:
        _estop();
      case GamepadButton.start:
        _setMode(client.state.remote ? 'auto' : 'remote');
      case GamepadButton.back:
        _toggle(_Panel.actions);
      case GamepadButton.dpadUp:
        _setGear(_gear + 1);
      case GamepadButton.dpadDown:
        _setGear(_gear - 1);
      case GamepadButton.a when shift:
        _robotAction('stand_up');
      case GamepadButton.y when shift:
        _robotAction('sit_down');
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- actions

  Future<CommandResult> _run(
    String name, {
    Map<String, Object?> args = const {},
    String? label,
    bool quiet = false,
  }) async {
    setState(() => _busy.add(name));
    final result = await client.command(name, args);
    if (!mounted) return result;
    setState(() => _busy.remove(name));
    if (!result.ok || !quiet) {
      final text = label ?? name;
      _show(
        result.ok
            ? Toast(text, color: Palette.ok, icon: Icons.check_circle_rounded)
            : Toast(
                '$text: ${result.message.isEmpty ? s.t('failed') : result.message}',
                color: Palette.stop,
                icon: Icons.error_rounded,
              ),
      );
    }
    return result;
  }

  void _estop() {
    HapticFeedback.heavyImpact();
    _show(Toast(s.t('estop_sent'), color: Palette.stop, icon: Icons.pan_tool_rounded));
    client.estop().then((result) {
      if (mounted && !result.ok) {
        _show(Toast('E-stop: ${result.message}', color: Palette.stop, icon: Icons.error_rounded));
      }
    });
  }

  void _setMode(String mode) {
    if (_busy.contains('set_mode')) return;
    _run('set_mode', args: {'mode': mode}, label: mode.toUpperCase(), quiet: true);
  }

  void _setGear(int gear) {
    final next = math.min(3, math.max(1, gear));
    if (next == _gear) return;
    HapticFeedback.selectionClick();
    setState(() => _gear = next);
    s.settings.update(gear: next);
  }

  void _toggle(_Panel panel) => setState(() => _panel = _panel == panel ? _Panel.none : panel);

  void _toggleMap() {
    setState(() => _showMap = !_showMap);
    client.setStreams(lidar: _showMap);
  }

  void _robotAction(String name) {
    final commands = client.welcome?.robotCommands ?? const <String>[];
    if (commands.contains(name)) _runAction(robotAction(name));
  }

  Future<void> _runAction(RobotAction action) async {
    final label = action.label(s.settings.language);
    if (action.confirm) {
      final ok = await _confirm(
        s.t('confirm_action', {'action': label}),
        s.t('confirm_action_body'),
        s.t('run'),
      );
      if (!ok) return;
    }
    await _run(action.name, label: label);
  }

  void _show(Toast toast) {
    _toastTimer?.cancel();
    setState(() => _toast = toast);
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Palette.panel,
        title: Text(title, style: Txt.title),
        content: Text(body, style: Txt.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _leave() async {
    final ok = await _confirm(s.t('leave'), s.t('leave_body'), s.t('disconnect'));
    if (!ok || !mounted) return;
    _exit();
  }

  void _exit() {
    client.disconnect();
    Navigator.of(context).pop();
  }

  /// The app went to the background: let the robot go rather than hold a session.
  void _suspend() {
    if (client.status == LinkStatus.idle) return;
    _suspended = true;
    client.disconnect();
  }

  void _resume() {
    if (!_suspended) return;
    _suspended = false;
    client.retry();
  }

  // ---------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: Palette.night,
        body: ListenableBuilder(
          listenable: Listenable.merge([client, s.settings]),
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) => _layout(constraints.biggest),
          ),
        ),
      ),
    );
  }

  Widget _layout(Size size) {
    final state = client.state;
    final modeColor = Palette.forMode(state.mode);
    final robotCommands = client.welcome?.robotCommands ?? const <String>[];
    final overlay = _linkOverlay();
    const scrim = [Color(0xA6000000), Color(0x00000000)];

    return Stack(
      children: [
        Positioned.fill(
          key: const ValueKey('camera'),
          child: CameraView(
            frames: client.cameraFrame,
            enabled: client.cameraEnabled,
            offText: s.t('camera_off'),
            waitText: s.t('camera_wait'),
          ),
        ),
        const Positioned(
          key: ValueKey('scrim-top'),
          left: 0,
          right: 0,
          top: 0,
          height: 96,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: scrim,
                ),
              ),
            ),
          ),
        ),
        const Positioned(
          key: ValueKey('scrim-bottom'),
          left: 0,
          right: 0,
          bottom: 0,
          height: 120,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: scrim,
                ),
              ),
            ),
          ),
        ),

        // thumb zones: left drives and strafes, right turns
        Positioned(
          key: const ValueKey('stick-move'),
          left: 0,
          top: 52,
          bottom: 0,
          width: size.width * 0.46,
          child: StickZone(
            home: const Alignment(-0.2, 0.5),
            icon: Icons.open_with_rounded,
            color: modeColor,
            onChanged: (value) => _move = value,
          ),
        ),
        Positioned(
          key: const ValueKey('stick-turn'),
          right: 0,
          top: 52,
          bottom: 0,
          width: size.width * 0.46,
          child: StickZone(
            home: const Alignment(0.15, 0.72),
            icon: Icons.threesixty_rounded,
            horizontalOnly: true,
            color: modeColor,
            onChanged: (value) => _turn = value,
          ),
        ),

        Positioned(key: const ValueKey('top'), left: 8, right: 8, top: 6, child: _topBar()),
        Positioned(key: const ValueKey('left'), left: 10, top: 60, child: _leftRail()),
        if (_showMap)
          Positioned(
            key: const ValueKey('map'),
            left: 64,
            top: 60,
            width: 184,
            height: 138,
            child: LidarMap(
              points: client.lidarPoints,
              route: client.routePoints,
              pose: state.pose,
              modeColor: modeColor,
            ),
          ),
        Positioned(
          key: const ValueKey('right'),
          right: 10,
          top: 58,
          child: _rightRail(robotCommands),
        ),
        Positioned(
          key: const ValueKey('gear'),
          left: 0,
          right: 0,
          bottom: 10,
          child: Center(child: _gearBar(modeColor)),
        ),

        if (state.estop)
          Positioned(
            key: const ValueKey('estop'),
            top: 56,
            left: size.width * 0.22,
            right: size.width * 0.22,
            child: _estopBanner(),
          ),
        Positioned(
          key: const ValueKey('toast'),
          top: state.estop ? 106 : 58,
          left: size.width * 0.2,
          right: size.width * 0.2,
          child: IgnorePointer(
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _toast == null
                    ? const SizedBox.shrink()
                    : ToastView(key: ValueKey(_toast), toast: _toast!),
              ),
            ),
          ),
        ),

        if (_panel != _Panel.none)
          Positioned(
            key: const ValueKey('barrier'),
            left: 0,
            top: 52,
            right: 76,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _panel = _Panel.none),
            ),
          ),
        if (_panel == _Panel.actions)
          Positioned(
            key: const ValueKey('actions'),
            right: 80,
            top: 58,
            bottom: 10,
            width: math.min(340.0, size.width * 0.52),
            child: ActionsPanel(
              title: s.t('actions'),
              emptyText: s.t('no_actions'),
              commands: robotCommands,
              language: s.settings.language,
              busy: _busy,
              onRun: _runAction,
              onClose: () => _toggle(_Panel.actions),
            ),
          ),
        if (_panel == _Panel.patrol)
          Positioned(
            key: const ValueKey('patrol'),
            left: 64,
            top: 58,
            bottom: 10,
            width: math.min(330.0, size.width * 0.5),
            child: PatrolPanel(
              services: s,
              busy: _busy,
              onRun: _run,
              onClose: () => _toggle(_Panel.patrol),
            ),
          ),

        if (overlay != null) Positioned.fill(key: const ValueKey('overlay'), child: overlay),
      ],
    );
  }

  Widget _topBar() {
    final state = client.state;
    final welcome = client.welcome;
    final name = welcome != null && welcome.name.isNotEmpty ? welcome.name : client.host;
    final signal = client.signal;
    final rtt = client.rttMs;
    final field = _fieldChip(state.field);

    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                HudButton(
                  icon: Icons.close_rounded,
                  size: 36,
                  label: s.t('disconnect'),
                  onPressed: _leave,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: HudChip(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SignalBars(
                          level: signal,
                          color: signal >= 2 ? Palette.ok : Palette.caution,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(name, style: Txt.label, overflow: TextOverflow.ellipsis),
                        ),
                        if (rtt != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${rtt.round()} ms',
                            style: Txt.figure.copyWith(fontSize: 12, color: Palette.muted),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        ModeSwitch(
          mode: state.mode,
          autoLabel: s.t('mode_auto'),
          remoteLabel: s.t('mode_remote'),
          busy: _busy.contains('set_mode'),
          onSelect: _setMode,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.healthOk == false) ...[
                  HudChip(
                    border: Palette.caution.withValues(alpha: 0.5),
                    onTap: () => _show(
                      Toast(
                        state.healthIssues.isEmpty
                            ? s.t('health_issues')
                            : state.healthIssues.join(', '),
                        color: Palette.caution,
                        icon: Icons.health_and_safety_rounded,
                      ),
                    ),
                    child: const Icon(
                      Icons.health_and_safety_rounded,
                      size: 16,
                      color: Palette.caution,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (field != null) ...[
                  Flexible(child: field),
                  const SizedBox(width: 6),
                ],
                BatteryChip(battery: state.battery),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget? _fieldChip(String? field) {
    if (field == null) return null;
    final (color, key) = switch (field) {
      'clear' => (Palette.ok, 'field_clear'),
      'limited' => (Palette.caution, 'field_limited'),
      'stop' => (Palette.stop, 'field_stop'),
      'stale' => (Palette.caution, 'field_stale'),
      _ => (Palette.muted, 'field_off'),
    };
    return HudChip(
      border: color.withValues(alpha: 0.5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_rounded, size: 15, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              s.t(key),
              style: Txt.label.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _leftRail() {
    return Column(
      children: [
        HudButton(
          icon: Icons.route_rounded,
          label: s.t('patrol'),
          tint: Palette.auto,
          active: _panel == _Panel.patrol,
          onPressed: () => _toggle(_Panel.patrol),
        ),
        const SizedBox(height: 10),
        HudButton(
          icon: Icons.radar_rounded,
          label: s.t('map'),
          active: _showMap,
          onPressed: _toggleMap,
        ),
        const SizedBox(height: 10),
        HudButton(
          icon: client.cameraEnabled ? Icons.videocam_rounded : Icons.videocam_off_rounded,
          label: s.t('camera'),
          active: client.cameraEnabled,
          onPressed: () => client.setStreams(camera: !client.cameraEnabled),
        ),
      ],
    );
  }

  Widget _rightRail(List<String> robotCommands) {
    return Column(
      children: [
        StopButton(engaged: client.state.estop, onPressed: _estop),
        const SizedBox(height: 12),
        HudButton(
          icon: Icons.apps_rounded,
          label: s.t('actions'),
          active: _panel == _Panel.actions,
          tint: Palette.remote,
          onPressed: () => _toggle(_Panel.actions),
        ),
        for (final name in quickActions(robotCommands)) ...[
          const SizedBox(height: 10),
          HudButton(
            icon: robotAction(name).icon,
            label: robotAction(name).label(s.settings.language),
            busy: _busy.contains(name),
            onPressed: () => _runAction(robotAction(name)),
          ),
        ],
      ],
    );
  }

  Widget _gearBar(Color modeColor) {
    final cmd = client.state.cmd;
    final speed = math.sqrt(cmd[0] * cmd[0] + cmd[1] * cmd[1]);
    return Glass(
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Tooltip(
              message: s.t('gear'),
              child: const Icon(Icons.speed_rounded, size: 18, color: Palette.muted),
            ),
          ),
          for (var gear = 1; gear <= 3; gear++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _setGear(gear),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 36,
                height: 28,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: gear == _gear ? modeColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '$gear',
                  style: Txt.figure.copyWith(
                    color: gear == _gear ? Palette.night : Palette.muted,
                  ),
                ),
              ),
            ),
          SizedBox(
            width: 74,
            child: Text(
              '${speed.toStringAsFixed(2)} m/s',
              textAlign: TextAlign.right,
              style: Txt.figure.copyWith(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _estopBanner() {
    return Glass(
      color: Palette.stop.withValues(alpha: 0.9),
      border: Colors.white.withValues(alpha: 0.55),
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          const Icon(Icons.pan_tool_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.t('estop_on'),
              style: Txt.label.copyWith(color: Colors.white),
              maxLines: 2,
            ),
          ),
          const SizedBox(width: 8),
          HoldButton(
            label: s.t('estop_release'),
            busy: _busy.contains('estop_release'),
            onHeld: () => _run('estop_release', label: s.t('estop_released')),
          ),
        ],
      ),
    );
  }

  Widget? _linkOverlay() {
    final name = client.welcome?.name ?? client.host;
    switch (client.status) {
      case LinkStatus.connected:
        return null;
      case LinkStatus.lost:
      case LinkStatus.connecting:
      case LinkStatus.idle:
        final text = client.status == LinkStatus.lost
            ? s.t('link_lost')
            : s.t('connecting_to', {'robot': name});
        return IgnorePointer(
          child: Center(
            child: Glass(
              color: Palette.glassHigh,
              radius: 16,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Palette.caution),
                  ),
                  const SizedBox(width: 12),
                  Text(text, style: Txt.label),
                ],
              ),
            ),
          ),
        );
      case LinkStatus.denied:
      case LinkStatus.busy:
      case LinkStatus.unreachable:
        final (title, hint) = switch (client.status) {
          LinkStatus.denied => (s.t('denied'), s.t('denied_hint')),
          LinkStatus.busy => (s.t('busy'), client.statusDetail),
          _ => (s.t('unreachable'), s.t('unreachable_hint', {'host': client.host})),
        };
        return ColoredBox(
          color: const Color(0xB3000000),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Glass(
                color: Palette.glassHigh,
                radius: 16,
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Txt.title),
                    if (hint.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(hint, style: Txt.body.copyWith(color: Palette.muted)),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: _exit, child: Text(s.t('disconnect'))),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: client.retry, child: Text(s.t('retry'))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    }
  }
}

/// Press and hold to confirm (releasing the e-stop must be deliberate).
class HoldButton extends StatefulWidget {
  const HoldButton({super.key, required this.label, required this.onHeld, this.busy = false});

  final String label;
  final VoidCallback onHeld;
  final bool busy;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            HapticFeedback.mediumImpact();
            widget.onHeld();
            _hold.value = 0;
          }
        });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.busy ? null : (_) => _hold.forward(),
      onTapUp: (_) => _hold.reverse(),
      onTapCancel: () => _hold.reverse(),
      child: AnimatedBuilder(
        animation: _hold,
        builder: (context, child) => Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            gradient: LinearGradient(
              colors: const [Colors.white, Colors.white, Color(0x33FFFFFF), Color(0x33FFFFFF)],
              stops: [0, _hold.value, _hold.value, 1],
            ),
            border: Border.all(color: Colors.white),
          ),
          child: widget.busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Palette.stop),
                )
              : Text(
                  widget.label,
                  style: Txt.label.copyWith(
                    color: _hold.value > 0.5 ? Palette.stop : Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}
