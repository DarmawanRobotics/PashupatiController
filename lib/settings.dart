import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'input/gamepad_input.dart';
import 'l10n.dart';
import 'net/discovery.dart';
import 'net/teleop_client.dart';

/// Handheld settings, kept on the device. The connection part is hidden behind three taps on
/// the version; the rest is under the gear while driving.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static const defaultHost = '192.168.234.234';
  static const defaultPort = 9870;

  /// Share of the robot's speed limits per speed level.
  static const speedScale = [0.3, 0.6, 1.0];

  final SharedPreferencesWithCache _prefs;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    return AppSettings._(prefs);
  }

  String get host => _prefs.getString('host') ?? defaultHost;
  int get port => _prefs.getInt('port') ?? defaultPort;
  String get token => _prefs.getString('token') ?? '';
  String get handheldName => _prefs.getString('name') ?? 'Retroid';
  String get language => _prefs.getString('language') ?? 'id';

  /// Camera video from the robot, and its rate.
  bool get video => _prefs.getBool('camera') ?? true;
  double get cameraFps => _prefs.getDouble('camera_fps') ?? 8;

  /// Lidar returns drawn on the map.
  bool get lidar => _prefs.getBool('map') ?? true;

  /// The big view: 'camera' or 'map'; the other one is the small box.
  String get mainView => _prefs.getString('main_view') ?? 'camera';

  /// Hold R1 to drive with the gamepad sticks.
  bool get deadman => _prefs.getBool('deadman') ?? false;

  /// Inspection time of a stop point marked from the handheld, seconds.
  double get stopDwell => _prefs.getDouble('dwell') ?? 10;

  /// Speed level 1..3, see [speedScale].
  int get gear => _gear(_prefs.getInt('gear') ?? 1);

  static int _gear(int value) => value < 1 ? 1 : (value > 3 ? 3 : value);

  Future<void> update({
    String? host,
    int? port,
    String? token,
    String? handheldName,
    String? language,
    bool? video,
    double? cameraFps,
    bool? lidar,
    String? mainView,
    bool? deadman,
    double? stopDwell,
    int? gear,
  }) async {
    final writes = <Future<void>>[
      if (host != null) _prefs.setString('host', host.trim()),
      if (port != null) _prefs.setInt('port', port),
      if (token != null) _prefs.setString('token', token),
      if (handheldName != null) _prefs.setString('name', handheldName.trim()),
      if (language != null) _prefs.setString('language', language),
      if (video != null) _prefs.setBool('camera', video),
      if (cameraFps != null) _prefs.setDouble('camera_fps', cameraFps),
      if (lidar != null) _prefs.setBool('map', lidar),
      if (mainView != null) _prefs.setString('main_view', mainView),
      if (deadman != null) _prefs.setBool('deadman', deadman),
      if (stopDwell != null) _prefs.setDouble('dwell', stopDwell),
      if (gear != null) _prefs.setInt('gear', _gear(gear)),
    ];
    // the cache holds the new values already: apply them now, the disk catches up
    notifyListeners();
    await Future.wait(writes);
  }
}

/// Everything the screens share, created once in main().
class Services {
  Services({
    required this.settings,
    required this.client,
    required this.discovery,
    required this.gamepad,
  });

  final AppSettings settings;
  final TeleopClient client;
  final Discovery discovery;
  final GamepadInput gamepad;

  String t(String key, [Map<String, Object> args = const {}]) =>
      tr(settings.language, key, args);

  /// Label of a navigation state (falls back to the state name).
  String navLabel(String nav) {
    final label = t('nav_$nav');
    return label.startsWith('nav_') ? nav : label;
  }
}
