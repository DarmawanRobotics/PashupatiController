import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Colours of the handheld: dark glass over the video, and one colour per driver.
abstract final class Palette {
  static const night = Color(0xFF080D10);
  static const panel = Color(0xFF111A1F);
  static const glass = Color(0xA6111A1F);
  static const glassHigh = Color(0xE6111A1F);
  static const line = Color(0x24FFFFFF);
  static const text = Color(0xFFF1F4F5);
  static const muted = Color(0xFF9DA9AF);

  /// The operator drives (REMOTE).
  static const remote = Color(0xFFFF9F43);

  /// The robot drives itself (AUTO).
  static const auto = Color(0xFF4FD1C5);
  static const stop = Color(0xFFFF4D4F);
  static const ok = Color(0xFF59D98E);
  static const caution = Color(0xFFF5CD47);

  static Color forMode(String mode) => mode == 'remote' ? remote : auto;
}

/// Barlow Semi Condensed: compact signage letters that stay legible over moving video.
abstract final class Txt {
  static const family = 'Barlow';
  static const _tabular = [ui.FontFeature.tabularFigures()];

  static const display = TextStyle(
    fontFamily: family,
    fontSize: 40,
    fontWeight: FontWeight.w700,
    height: 0.95,
    letterSpacing: 1.2,
    color: Palette.text,
  );
  static const title = TextStyle(
    fontFamily: family,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    height: 1.1,
    color: Palette.text,
  );
  static const body = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.25,
    color: Palette.text,
  );
  static const label = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.1,
    color: Palette.text,
  );
  static const small = TextStyle(
    fontFamily: family,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    height: 1.2,
    color: Palette.muted,
  );
  static const figure = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.0,
    color: Palette.text,
    fontFeatures: _tabular,
  );
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Palette.remote,
    onPrimary: Color(0xFF221303),
    secondary: Palette.auto,
    onSecondary: Color(0xFF04201D),
    error: Palette.stop,
    surface: Palette.panel,
    onSurface: Palette.text,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: Txt.family,
    scaffoldBackgroundColor: Palette.night,
    visualDensity: VisualDensity.compact,
  );
}
