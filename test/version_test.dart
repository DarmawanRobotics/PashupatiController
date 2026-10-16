import 'dart:io';

import 'package:flutter_teleop/screens/connect_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the start screen shows the version in pubspec.yaml', () {
    final version = RegExp(
      r'^version:\s*([^+\s]+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(appVersion, version);
  });
}
