import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import '../input/gamepad_input.dart';
import '../l10n.dart' show categoryLabel;
import '../net/teleop_client.dart';
import '../protocol/messages.dart' show RobotState;
import '../robot_actions.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/camera_view.dart';
import '../widgets/glance.dart';
import '../widgets/hud.dart';
import '../widgets/map_view.dart';
import 'patrol_screen.dart';
import 'routes_screen.dart';
import 'settings_screen.dart';

/// Home while connected: the camera and the map (tap the small box to swap them), STOP and the
/// robot's own actions on the right, mapping and patrol icons at the bottom. Driving is on the
/// gamepad; touch is for the views (pinch and drag the big map).
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key, required this.services});

  final Services services;

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  /// Navigation states in which no patrol is under way (Start shows instead of Pause).
  static const _idleNav = {'NAV_INACTIVE', 'NO_PATH', 'PAUSED', 'GOAL_REACHED'};

  Services get s => widget.services;
  TeleopClient get client => widget.services.client;

  final Set<String> _busy = {};
  Toast? _toast;
  Timer? _toastTimer;
  Timer? _loop;
  bool _hinted = false;
  bool _suspended = false;

  /// Pages and dialogs open over this screen; the sticks rest meanwhile.
  int _covers = 0;

  /// What the map shows, for both views and the buttons under the small one.
  final _viewport = MapViewport();

  /// The route being recorded: since when, and the stop points marked in it.
  DateTime? _recordingSince;
  final List<Offset> _marks = [];

  /// Inspection findings already seen, so only a new one raises a toast.
  int? _seenReports;

  StreamSubscription<GamepadButton>? _buttons;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _loop = Timer.periodic(const Duration(milliseconds: 50), (_) => _drive());
    _buttons = s.gamepad.presses.listen(_onButton);
    _lifecycle = AppLifecycleListener(onPause: _suspend, onResume: _resume);
    client.addListener(_onClient);
    s.settings.addListener(_syncStreams);
    s.video.addListener(_syncStreams);
    s.gamepad.refresh(); // the plugin may not have listed the controls yet at app start
    // after the first frame: setting the streams notifies the screens below while this one builds
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onClient();
    });
  }

  @override
  void dispose() {
    _loop?.cancel();
    _toastTimer?.cancel();
    _buttons?.cancel();
    _lifecycle.dispose();
    client.removeListener(_onClient);
    s.settings.removeListener(_syncStreams);
    s.video.removeListener(_syncStreams);
    s.video.want(null, '');
    _viewport.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- input

  /// 20 Hz from the gamepad sticks; the client only sends in REMOTE mode.
  void _drive() {
    final pad = s.gamepad;
    if (_covers > 0 || (s.settings.deadman && !pad.pressed(GamepadButton.rightBumper))) {
      client.drive(0, 0, 0);
      _hinted = false;
      return;
    }
    final x = GamepadInput.shaped(pad.axis(GamepadAxis.leftStickX));
    final y = GamepadInput.shaped(pad.axis(GamepadAxis.leftStickY));
    final r = GamepadInput.shaped(pad.axis(GamepadAxis.rightStickX));
    final limits = client.welcome?.limits ?? const [0.5, 0.3, 1.0];
    final scale = AppSettings.speedScale[s.settings.gear - 1];
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
    if (button == GamepadButton.b) {
      _estop(); // STOP works from every page
      return;
    }
    if (_covers > 0) return; // settings, routes or a dialog is open
    final shift = s.gamepad.pressed(GamepadButton.leftBumper);
    switch (button) {
      case GamepadButton.start:
        _setMode(client.state.remote ? 'auto' : 'remote');
      case GamepadButton.back:
        _swapViews();
      case GamepadButton.dpadUp:
        _setGear(s.settings.gear + 1);
      case GamepadButton.dpadDown:
        _setGear(s.settings.gear - 1);
      case GamepadButton.a when shift:
        _robotAction('stand_up');
      case GamepadButton.y when shift:
        _robotAction('sit_down');
      default:
        break;
    }
  }

  /// Follows the robot's recording flag and inspection findings; a reconnect (no telemetry yet)
  /// changes nothing.
  void _onClient() {
    _syncStreams();
    final state = client.state;
    if (client.status != LinkStatus.connected || state.seq == 0) {
      _seenReports = null;
      return;
    }
    if (state.recording) {
      _recordingSince ??= DateTime.now();
    } else {
      _recordingSince = null;
    }
    _noticeFinding();
  }

  /// A new finding of the robot's inspection: a toast with what it saw.
  void _noticeFinding() {
    final inspection = client.state.inspection;
    if (inspection == null) return;
    final seen = _seenReports;
    _seenReports = inspection.reports;
    final last = inspection.last;
    if (seen == null || inspection.reports <= seen || last == null || last.clear) return;
    HapticFeedback.mediumImpact();
    final what = categoryLabel(s.settings.language, last.category);
    _show(
      Toast(s.t('finding', {'what': what}), color: Palette.caution, icon: Icons.report_rounded),
    );
  }

  /// Streams for the settings (here or on the settings page) and the link. The camera comes over
  /// WebRTC when the robot offers it, as JPEG frames until that plays and whenever it fails.
  void _syncStreams() {
    final settings = s.settings;
    final offer = client.welcome?.video;
    final whep = settings.video && client.isLive && offer != null ? offer.whep(client.host) : null;
    s.video.want(whep, client.token);
    final jpeg = settings.video && s.video.renderer == null; // what the camera view can show
    final webrtc = whep != null;
    if (client.cameraEnabled != jpeg ||
        client.videoEnabled != webrtc ||
        client.lidarEnabled != settings.lidar ||
        client.cameraFps != settings.cameraFps) {
      client.setStreams(
        camera: jpeg,
        video: webrtc,
        lidar: settings.lidar,
        fps: settings.cameraFps,
      );
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
    if (next == s.settings.gear) return;
    HapticFeedback.selectionClick();
    s.settings.update(gear: next);
    _show(
      Toast(s.t('speed_toast', {'n': next, 'name': s.t('speed_$next')}), icon: Icons.speed_rounded),
    );
  }

  void _swapViews() {
    HapticFeedback.selectionClick();
    s.settings.update(mainView: s.settings.mainView == 'map' ? 'camera' : 'map');
  }

  Future<void> _toggleRecording() async {
    if (client.state.recording) {
      await _run('record_stop', label: s.t('record_saved'));
      return;
    }
    final result = await _run('record_start', label: s.t('record_started'));
    if (!result.ok || !mounted) return;
    // a fresh route: the map shows only what this recording covers
    setState(() {
      _recordingSince = DateTime.now();
      _marks.clear();
      client.clearTrail();
    });
  }

  Future<void> _markStop() async {
    final pose = client.state.pose;
    final dwell = s.settings.stopDwell;
    final result = await _run(
      'mark_stop',
      args: {'dwell': dwell},
      label: s.t('stop_marked', {'s': dwell.round()}),
    );
    if (result.ok && pose != null && mounted) setState(() => _marks.add(Offset(pose.x, pose.y)));
  }

  /// Start, pause or resume the patrol; in REMOTE the robot only follows it once in AUTO.
  Future<void> _navPrimary() async {
    final state = client.state;
    final CommandResult result;
    if (state.navPaused) {
      result = await _run('nav_resume', label: s.t('nav_resumed'), quiet: state.remote);
    } else if (!_idleNav.contains(state.nav)) {
      await _run('nav_pause', label: s.t('nav_paused'));
      return;
    } else {
      result = await _run('nav_start', label: s.t('nav_started'), quiet: state.remote);
    }
    if (result.ok && mounted && client.state.remote) {
      _show(Toast(s.t('remote_nav_hint'), color: Palette.auto, icon: Icons.info_outline_rounded));
    }
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
      if (!ok || !mounted) return;
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

  /// Runs [open] (a page or a dialog over this screen) with the sticks at rest until it closes.
  Future<T> _cover<T>(Future<T> Function() open) async {
    _covers++;
    client.drive(0, 0, 0);
    try {
      return await open();
    } finally {
      _covers--;
    }
  }

  Future<void> _push(Widget page) =>
      _cover(() => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page)));

  Future<void> _openSettings() => _push(SettingsScreen(services: s));

  Future<void> _openRoutes() => _push(RoutesScreen(services: s, onRun: _run));

  Future<void> _openPatrol() =>
      _push(PatrolScreen(client: client, language: s.settings.language, onRun: _run));

  Future<bool> _confirm(String title, String body, String action) async {
    final result = await _cover(
      () => showDialog<bool>(
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
          listenable: Listenable.merge([client, s.settings, s.video]),
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) => _layout(constraints.biggest),
          ),
        ),
      ),
    );
  }

  Widget _layout(Size size) {
    const top = 50.0;
    const scrim = [Color(0xA6000000), Color(0x00000000)];
    final state = client.state;
    final modeColor = Palette.forMode(state.mode);
    final mapMain = s.settings.mainView == 'map';
    final insetWidth = math.max(150.0, math.min(300.0, size.width * 0.27));
    final insetHeight = insetWidth * 0.62;
    // the middle column between the small view and the right rail
    final middleLeft = insetWidth + 20;
    const middleRight = 82.0;
    final status = _statusPill();
    final overlay = _linkOverlay();

    final camera = CameraView(
      frames: client.cameraFrame,
      enabled: s.settings.video,
      offText: s.t('camera_off'),
      waitText: s.t('camera_wait'),
      tags: state.tags,
      people: state.people?.on == true && state.people?.state == 'running'
          ? state.people!.boxes
          : const [],
      webrtc: s.video.renderer,
    );
    final map = MapView(
      viewport: _viewport,
      points: client.lidarPoints,
      route: client.routePoints,
      trail: client.trail,
      marks: state.recording ? _marks : const [],
      pose: state.pose,
      modeColor: modeColor,
      lidar: client.lidarEnabled,
      notLocalizedText: s.t('not_localized'),
      compact: !mapMain,
    );

    return Stack(
      children: [
        // the big view; both boxes keep their key when they swap, so the video keeps playing
        Positioned.fill(
          key: ValueKey(mapMain ? 'map' : 'camera'),
          child: _ViewBox(child: mapMain ? map : camera),
        ),
        const Positioned(
          key: ValueKey('scrim-top'),
          left: 0,
          right: 0,
          top: 0,
          height: 124,
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
          height: 96,
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

        // the small view: tap it to swap
        Positioned(
          key: ValueKey(mapMain ? 'camera' : 'map'),
          left: 10,
          top: top,
          width: insetWidth,
          height: insetHeight,
          child: _ViewBox(onTap: _swapViews, child: mapMain ? camera : map),
        ),
        Positioned(
          key: const ValueKey('view-buttons'),
          left: 10,
          top: top + insetHeight + 8,
          // the map listens to the viewport itself: a pinch does not rebuild the whole screen
          child: ListenableBuilder(listenable: _viewport, builder: (context, _) => _viewButtons()),
        ),
        // last inspection, people in view and the robot's load, above the toolbar
        if (size.height - (top + insetHeight + 52) - 70 > 30)
          Positioned(
            key: const ValueKey('glance'),
            left: 10,
            top: top + insetHeight + 52,
            bottom: 70,
            width: insetWidth,
            child: Align(
              alignment: Alignment.topLeft,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: GlancePanel(
                  state: state,
                  language: s.settings.language,
                  showLoad: s.settings.showLoad,
                  onTap: (client.welcome?.has('inspection_set') ?? false) ? _openPatrol : null,
                ),
              ),
            ),
          ),

        Positioned(key: const ValueKey('top'), left: 8, right: 8, top: 6, child: _topBar()),
        Positioned(
          key: const ValueKey('right'),
          right: 10,
          top: top,
          child: _rightRail(size.height - top - 80),
        ),
        // mapping and patrol, bottom centre (clear of the right rail)
        Positioned(
          key: const ValueKey('toolbar'),
          left: middleRight,
          right: middleRight,
          bottom: 10,
          child: Center(child: _toolbar()),
        ),
        // recording / patrol state, e-stop and messages under the top bar
        Positioned(
          key: const ValueKey('notices'),
          top: top,
          left: middleLeft,
          right: middleRight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!s.gamepad.connected)
                IgnorePointer(
                  key: const ValueKey('no-gamepad'),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ToastView(
                      toast: Toast(
                        s.t('no_gamepad'),
                        color: Palette.caution,
                        icon: Icons.videogame_asset_off_rounded,
                      ),
                    ),
                  ),
                ),
              if (status != null)
                IgnorePointer(
                  key: const ValueKey('status'),
                  child: Padding(padding: const EdgeInsets.only(bottom: 8), child: status),
                ),
              if (state.estop)
                Padding(
                  key: const ValueKey('estop'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _estopBanner(),
                ),
              IgnorePointer(
                key: const ValueKey('toast'),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _toast == null
                      ? const SizedBox.shrink()
                      : ToastView(key: ValueKey(_toast), toast: _toast!),
                ),
              ),
            ],
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
    final loc = _localizationChip(state);

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
                Flexible(child: loc),
                const SizedBox(width: 6),
                if (field != null) ...[
                  Flexible(child: field),
                  const SizedBox(width: 6),
                ],
                BatteryChip(battery: state.battery),
                const SizedBox(width: 8),
                HudButton(
                  icon: Icons.settings_rounded,
                  size: 36,
                  label: s.t('settings'),
                  onPressed: _openSettings,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Localization source: start pose (identity), AprilTag, RViz pose or none; tap for details.
  Widget _localizationChip(RobotState state) {
    final kind = state.localizationKind;
    final (color, icon) = switch (kind) {
      'tag' => (Palette.ok, Icons.qr_code_2_rounded),
      'pose' => (Palette.ok, Icons.ads_click_rounded),
      'start' => (Palette.caution, Icons.home_rounded),
      'other' => (Palette.ok, Icons.my_location_rounded),
      _ => (Palette.stop, Icons.location_disabled_rounded),
    };
    final tag = state.localizationTag;
    final label = kind == 'tag' && tag != null
        ? s.t('loc_tag_named', {'tag': tag})
        : s.t('loc_$kind');
    return HudChip(
      border: color.withValues(alpha: 0.5),
      onTap: () => _show(
        Toast(
          kind == 'none' ? s.t('not_localized') : state.localization,
          color: color,
          icon: icon,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: Txt.label.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Protective field: a quiet shield while clear, its state in words when it slows or stops.
  Widget? _fieldChip(String? field) {
    if (field == null) return null;
    final (color, key) = switch (field) {
      'clear' => (Palette.ok, 'field_clear'),
      'limited' => (Palette.caution, 'field_limited'),
      'stop' => (Palette.stop, 'field_stop'),
      'stale' => (Palette.caution, 'field_stale'),
      _ => (Palette.muted, 'field_off'),
    };
    final loud = const {'limited', 'stop', 'stale'}.contains(field);
    return HudChip(
      border: color.withValues(alpha: 0.5),
      onTap: () => _show(Toast(s.t(key), color: color, icon: Icons.shield_rounded)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_rounded, size: 16, color: color),
          if (loud) ...[
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                s.t(key),
                style: Txt.label.copyWith(color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Under the small view: swap the two views; the map follows the robot or shows the route,
  /// and the compass turns it north up or with the robot's heading.
  Widget _viewButtons() {
    final follow = _viewport.mode == MapMode.follow;
    final fit = _viewport.mode == MapMode.fit;
    final headingUp = _viewport.headingUp;
    final pose = client.state.pose;
    // not localized: the map shows the robot looking up, unturned
    final rotation = pose == null ? 0.0 : _viewport.rotationFor(pose.yaw);
    final turned = headingUp || _viewport.rotation.abs() > 0.01;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HudButton(
          icon: Icons.swap_horiz_rounded,
          size: 36,
          label: s.t('swap_views'),
          onPressed: _swapViews,
        ),
        const SizedBox(width: 8),
        HudButton(
          icon: Icons.gps_fixed_rounded,
          size: 36,
          label: s.t('map_follow'),
          tint: follow ? Palette.auto : Palette.text,
          active: follow,
          onPressed: _viewport.follow,
        ),
        const SizedBox(width: 8),
        HudButton(
          icon: Icons.zoom_out_map_rounded,
          size: 36,
          label: s.t('map_fit'),
          tint: fit ? Palette.auto : Palette.text,
          active: fit,
          onPressed: _viewport.fit,
        ),
        const SizedBox(width: 8),
        // the needle points to map north; turned or heading up: back to north up
        HudButton(
          icon: Icons.navigation_rounded,
          iconAngle: -rotation,
          size: 36,
          label: s.t(turned ? 'map_north' : 'map_heading'),
          tint: headingUp ? Palette.auto : Palette.text,
          active: headingUp,
          onPressed: turned ? _viewport.northUp : _viewport.trackHeading,
        ),
      ],
    );
  }

  /// Mapping (record a route, its stop points and the AprilTags) and patrol (localize, pick a
  /// route, start / pause / resume, end).
  Widget _toolbar() {
    final state = client.state;
    final welcome = client.welcome;
    bool has(String command) => welcome?.has(command) ?? false;
    bool busy(String command) => _busy.contains(command);
    final recording = state.recording;
    final running = !_idleNav.contains(state.nav);
    final inspection = inspectionLook(state.inspection);
    const width = 50.0;

    return Glass(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ActionButton(
              icon: recording ? Icons.stop_circle_rounded : Icons.fiber_manual_record_rounded,
              label: s.t(recording ? 'act_finish' : 'act_record'),
              tint: Palette.stop,
              active: recording,
              width: width,
              busy: busy('record_start') || busy('record_stop'),
              onPressed: has('record_start') ? _toggleRecording : null,
            ),
            ActionButton(
              icon: Icons.add_location_alt_rounded,
              label: s.t('act_stop_point'),
              tint: Palette.caution,
              width: width,
              busy: busy('mark_stop'),
              onPressed: has('mark_stop') && recording ? _markStop : null,
            ),
            ActionButton(
              icon: Icons.qr_code_2_rounded,
              label: s.t('act_tags'),
              width: width,
              busy: busy('record_tags'),
              onPressed: has('record_tags')
                  ? () => _run('record_tags', label: s.t('tags_recorded'))
                  : null,
            ),
            const _ToolbarDivider(),
            ActionButton(
              icon: Icons.my_location_rounded,
              label: s.t('act_localize'),
              width: width,
              busy: busy('localize'),
              onPressed: has('localize') ? () => _run('localize', label: s.t('localized')) : null,
            ),
            ActionButton(
              icon: Icons.route_rounded,
              label: s.t('act_routes'),
              width: width,
              onPressed: has('list_routes') && has('load_route') ? _openRoutes : null,
            ),
            ActionButton(
              icon: running ? Icons.pause_rounded : Icons.play_arrow_rounded,
              label: s.t(state.navPaused ? 'act_resume' : (running ? 'act_pause' : 'act_start')),
              tint: Palette.auto,
              active: running,
              width: width,
              busy: busy('nav_start') || busy('nav_pause') || busy('nav_resume'),
              onPressed: has('nav_start') && has('nav_pause') ? _navPrimary : null,
            ),
            ActionButton(
              icon: Icons.stop_rounded,
              label: s.t('act_end'),
              width: width,
              busy: busy('nav_stop'),
              onPressed: has('nav_stop') && state.nav != 'NAV_INACTIVE'
                  ? () => _run('nav_stop', label: s.t('nav_ended'))
                  : null,
            ),
            const _ToolbarDivider(),
            // the inspection's state at a glance; the page sets it and the patrol speed
            ActionButton(
              icon: inspection.icon,
              label: s.t('act_inspection'),
              tint: inspection.color,
              active: state.inspection?.state == 'running',
              width: width,
              onPressed: has('inspection_set') || has('people_set') || has('nav_speed')
                  ? _openPatrol
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// STOP, then the robot driver's own commands (stand up, sit down, gaits, ...).
  Widget _rightRail(double listHeight) {
    final commands = client.welcome?.robotCommands ?? const <String>[];
    final language = s.settings.language;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        StopButton(engaged: client.state.estop, onPressed: _estop),
        if (commands.isNotEmpty && listHeight >= 60) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: listHeight),
            child: Glass(
              radius: 16,
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final name in commands)
                      ActionButton(
                        icon: robotAction(name).icon,
                        label: robotAction(name).label(language),
                        width: 58,
                        busy: _busy.contains(name),
                        onPressed: () => _runAction(robotAction(name)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Recording or patrol state, under the top bar.
  Widget? _statusPill() {
    final state = client.state;
    final since = _recordingSince;
    final String text;
    final Color color;
    final IconData icon;
    if (state.recording && since != null) {
      final elapsed = DateTime.now().difference(since);
      String two(int value) => value.toString().padLeft(2, '0');
      text = [
        '${s.t('rec')} ${two(elapsed.inMinutes)}:${two(elapsed.inSeconds % 60)}',
        if (_marks.isNotEmpty) s.t('stop_count', {'n': _marks.length}),
      ].join('  ·  ');
      color = Palette.stop;
      icon = Icons.fiber_manual_record_rounded;
    } else if (state.nav != 'NAV_INACTIVE') {
      final label = s.navLabel(state.nav);
      text = state.navMessage.isEmpty ? label : '$label  ·  ${state.navMessage}';
      color = switch (state.nav) {
        'FOLLOWING' || 'JOINING' || 'APPROACHING' || 'DWELLING' => Palette.auto,
        'GOAL_REACHED' => Palette.ok,
        'PAUSED' || 'NO_PATH' || 'TF_UNAVAILABLE' => Palette.caution,
        _ => Palette.stop,
      };
      icon = Icons.route_rounded;
    } else {
      return null;
    }
    return Glass(
      color: Palette.glassHigh,
      border: color.withValues(alpha: 0.6),
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: Txt.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
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

/// The camera or the map, full screen or as the small framed box that swaps them on tap.
///
/// The same widget in both places, so a view keeps its state (the decoded video) when moved.
class _ViewBox extends StatelessWidget {
  const _ViewBox({required this.child, this.onTap});

  final Widget child;

  /// Set for the small box.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final small = onTap != null;
    final radius = BorderRadius.circular(small ? 12 : 0);
    final frame = Border.all(color: Colors.white.withValues(alpha: 0.45), width: 1.5);
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(borderRadius: radius, border: small ? frame : null),
        child: ClipRRect(
          borderRadius: radius,
          clipBehavior: small ? Clip.antiAlias : Clip.none,
          child: child,
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color: Palette.line,
    );
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
