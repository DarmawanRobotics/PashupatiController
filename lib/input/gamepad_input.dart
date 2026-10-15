import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:gamepads/gamepads.dart';

/// The handheld's physical controls (Retroid sticks and buttons), normalized by `gamepads`.
class GamepadInput extends ChangeNotifier {
  final _state = NormalizedGamepadState();
  final _presses = StreamController<GamepadButton>.broadcast();
  StreamSubscription<NormalizedGamepadEvent>? _subscription;

  /// Last raw event, for the gamepad test in the settings.
  String lastEvent = '';

  /// A gamepad is attached (the handheld's own controls count), and its name.
  bool connected = false;
  String name = '';
  StreamSubscription<GamepadConnectionEvent>? _connections;
  DateTime _lastInput = DateTime.fromMillisecondsSinceEpoch(0);

  /// Button presses (down edges only).
  Stream<GamepadButton> get presses => _presses.stream;

  void start() {
    try {
      _subscription ??= Gamepads.normalizedEvents.listen(_onEvent, onError: (Object _) {});
      _connections ??= Gamepads.connectionEvents.listen((_) => refresh(), onError: (Object _) {});
    } on Exception {
      // no gamepad plugin on this platform (tests, desktop without support)
    }
    refresh();
  }

  /// Asks the plugin which gamepads are attached (at start, on the drive screen, on plug events).
  Future<void> refresh() async {
    try {
      final pads = await Gamepads.list();
      final padName = pads.isEmpty ? name : pads.first.name;
      for (final pad in pads) {
        unawaited(pad.dispose()); // every listed controller holds an event subscription
      }
      // a controller that sends input counts even if the plugin does not list it
      final recent = DateTime.now().difference(_lastInput) < const Duration(seconds: 30);
      _setConnected(pads.isNotEmpty || recent, padName);
    } on Exception {
      // no gamepad plugin on this platform
    }
  }

  void _setConnected(bool value, String padName) {
    if (value == connected && padName == name) return;
    connected = value;
    name = padName;
    notifyListeners();
  }

  double axis(GamepadAxis axis) => _state.axisValue(axis);

  bool pressed(GamepadButton button) => _state.isPressed(button);

  /// Stick deflection with a radial dead zone, rescaled to 0..1 outside it.
  static double shaped(double value, [double deadZone = 0.12]) {
    final magnitude = value.abs();
    if (magnitude <= deadZone) return 0;
    final scaled = math.min(1.0, (magnitude - deadZone) / (1 - deadZone));
    return value.isNegative ? -scaled : scaled;
  }

  void _onEvent(NormalizedGamepadEvent event) {
    _lastInput = DateTime.now();
    connected = true;
    final button = event.button;
    final wasDown = button != null && _state.isPressed(button);
    _state.update(event);
    if (button != null && event.value != 0 && !wasDown) _presses.add(button);
    lastEvent = '${event.button?.name ?? event.axis?.name}  ${event.value.toStringAsFixed(2)}'
        '  (${event.rawEvent.key})';
    notifyListeners();
  }

  @override
  void dispose() {
    _connections?.cancel();
    _subscription?.cancel();
    _presses.close();
    super.dispose();
  }
}
