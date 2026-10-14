import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'input/gamepad_input.dart';
import 'l10n.dart';
import 'net/discovery.dart';
import 'net/teleop_client.dart';

/// Handheld settings, kept on the device. Hidden behind three taps on the version.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static const defaultHost = '192.168.234.234';
  static const defaultPort = 9870;

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
  double get cameraFps => _prefs.getDouble('camera_fps') ?? 8;
  bool get cameraOnStart => _prefs.getBool('camera') ?? true;
  bool get mapOnStart => _prefs.getBool('map') ?? true;
  bool get deadman => _prefs.getBool('deadman') ?? false;

  /// Speed gear 1..3 (30, 60, 100 % of the robot limits).
  int get gear => _gear(_prefs.getInt('gear') ?? 1);

  static int _gear(int value) => value < 1 ? 1 : (value > 3 ? 3 : value);

  Future<void> update({
    String? host,
    int? port,
    String? token,
    String? handheldName,
    String? language,
    double? cameraFps,
    bool? cameraOnStart,
    bool? mapOnStart,
    bool? deadman,
    int? gear,
  }) async {
    if (host != null) await _prefs.setString('host', host.trim());
    if (port != null) await _prefs.setInt('port', port);
    if (token != null) await _prefs.setString('token', token);
    if (handheldName != null) await _prefs.setString('name', handheldName.trim());
    if (language != null) await _prefs.setString('language', language);
    if (cameraFps != null) await _prefs.setDouble('camera_fps', cameraFps);
    if (cameraOnStart != null) await _prefs.setBool('camera', cameraOnStart);
    if (mapOnStart != null) await _prefs.setBool('map', mapOnStart);
    if (deadman != null) await _prefs.setBool('deadman', deadman);
    if (gear != null) await _prefs.setInt('gear', _gear(gear));
    notifyListeners();
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
}
