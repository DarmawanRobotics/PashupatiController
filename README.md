# flutter_teleop

Handheld teleop for [Pashupati](https://github.com/DarmawanRobotics/Pashupati) robots, made for
the Retroid Pocket 4 (Android 11, physical sticks) and usable on any Android phone or tablet in
landscape. It talks the UDP teleop protocol v1 straight to `teleop_udp_node`
([PROTOCOL.md](https://github.com/DarmawanRobotics/Pashupati/blob/dev/src/robot_bridge/PROTOCOL.md));
there is no ROS on the handheld.

- One home screen, no menus: two views, the camera and a top-down map, one big and one small
  (tap the small one to swap). The map shows the loaded route with its waypoints and stop points,
  where the robot has been, the lidar and the robot.
- Mapping and patrol icons on top: record a route, mark stop points, record AprilTags, localize,
  pick a route, start / pause / resume, end.
- STOP (software e-stop, released only by holding) and the robot's own `robot_commands` (stand up,
  sit down, gaits, ...) as icons on the right; anything that moves the robot on its own asks first.
- Floating thumb sticks (left drives and strafes, right turns) or the physical sticks, AUTO /
  REMOTE switch, live battery, link, protective field and health.
- Settings under the gear: speed level, video, lidar on the map, language, inspection time.
- Finds robots on the LAN by itself; Indonesian and English.

## Setup

Flutter 3.35 or newer, the handheld on USB with `adb devices` listing it.

```bash
git clone git@github.com:DarmawanRobotics/flutter_teleop.git && cd flutter_teleop
flutter create . --org com.darmawanrobotics --project-name flutter_teleop --platforms android --empty
flutter pub get
flutter test
flutter run --release
```

`flutter create .` runs once: it generates the Gradle project around `lib/` and keeps the files
that are already here (`AndroidManifest.xml` with the network permission and landscape lock,
`MainActivity.kt` with the gamepad hooks and keep-screen-on). `--empty` leaves out the counter-app
test, which would not compile here. Commit what it generates.

## Robot side

The token and the action menu come from the robot's `/etc/pashupati/site.yaml`:

```yaml
teleop_udp_node:
  ros__parameters:
    token: "<secret>"           # the same in the app settings
    robot_commands: [stand_up, sit_down, balance_stand_mode, move_mode, slow_speed, normal_speed,
                     fast_speed, emergency_stop]
```

The default robot is `192.168.234.234:9870`; other robots on the same network appear in the list
on their own.

## Controls

| | Touch | Gamepad |
|---|---|---|
| Drive and strafe | left half of the screen | left stick |
| Turn | right half of the screen | right stick |
| STOP (software e-stop) | red button | B, also on the other pages |
| AUTO / REMOTE | switch on top | Start |
| Swap camera and map | tap the small view | Select |
| Speed level (30 / 60 / 100 % of the robot limits) | gear, Speed | D-pad up / down |
| Robot actions | icons under STOP | L1 + A stand up, L1 + Y sit down |

The robot only takes the joystick in REMOTE; in AUTO navigation drives. After a STOP nothing but
zero reaches the robot until "Hold to release" is held for a second.

**Teach and patrol:** REMOTE, Record, drive the route and tap Point where the robot should stop and
inspect, Finish. Then Routes, pick it, AUTO, Start.

**Settings** (gear) apply at once. The robot address, token, handheld name and a gamepad test are
hidden: tap the version on the start screen three times.

## Code

```
lib/
├── protocol/   messages.dart (JSON), streams.dart (chunked camera / lidar / route)
├── net/        teleop_client.dart (session, commands, joystick), discovery.dart
├── input/      gamepad_input.dart (gamepads, normalized)
├── widgets/    hud, sticks, camera, map
├── screens/    connect, drive (home), routes, settings
├── robot_actions.dart   icons and labels of known robot commands
└── l10n.dart            Indonesian and English text
```

Barlow Semi Condensed is under the SIL Open Font License (`assets/fonts/OFL.txt`).
