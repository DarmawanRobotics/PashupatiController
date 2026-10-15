<div align="center">

<img src="assets/images/logo.png" width="112" alt="Pashupati Controller logo">

# Pashupati Controller

**The handheld for [Pashupati](https://github.com/DarmawanRobotics/Pashupati) patrol robots: drive
them, watch through their camera, teach routes and run their AI inspection, from a Retroid
Pocket 4 or any Android device in landscape.**

[![CI](https://github.com/DarmawanRobotics/PashupatiController/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/DarmawanRobotics/PashupatiController/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-2.6.0-4FD1C5)
![Flutter](https://img.shields.io/badge/Flutter-3.35%2B-02569B?logo=flutter&logoColor=white)
![Android](https://img.shields.io/badge/Android-11%2B-3DDC84?logo=android&logoColor=white)
![Robot](https://img.shields.io/badge/robot-ROS%202%20Humble-22314E?logo=ros&logoColor=white)
![Video](https://img.shields.io/badge/video-WebRTC-333333?logo=webrtc&logoColor=white)
![Languages](https://img.shields.io/badge/UI-Indonesia%20%7C%20English-FF9F43)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

[Features](#features) · [Install](#install) · [Robot side](#robot-side) ·
[Controls](#controls) · [Develop](#develop)

</div>

---

The app talks the UDP teleop protocol v1 straight to the robot's `teleop_udp_node`
([PROTOCOL.md](https://github.com/DarmawanRobotics/Pashupati/blob/dev/src/robot_bridge/PROTOCOL.md)),
and takes the video over WebRTC. There is no ROS on the handheld.

## Features

**Drive**
- Physical sticks only: left stick drives and strafes, right stick turns. The touch screen is
  left free for the map.
- AUTO / REMOTE switch, three speed levels, the robot's own actions (stand up, sit down, gaits,
  ...) as icons. Anything that makes the robot move on its own asks first.
- **STOP** is the software e-stop. It is released only by holding the button for a second.

**See**
- Two views, camera and map: one big and one small, swapped with a tap.
- Camera as H.264 over WebRTC, about 0.1 s behind live. When WebRTC is unavailable or fails, the
  app falls back to JPEG frames over the teleop link.
- AprilTags and detected people are boxed on the video as the robot sees them.
- The map shows the route with its waypoints and stop points, the robot's trail, the lidar and
  the robot. Pinch to zoom, drag to move, twist to rotate, or let the map turn with the robot.

**Patrol**
- Record a route, mark stop points, record AprilTags, localize, pick a route, then start, pause,
  resume or end the patrol, all from icons on the main screen.
- The robot can join a route from beside it, and a route loaded again starts over.

**AI inspection** (Inspection page)
- Turn the VLM inspection on or off, and choose the model running on the robot through Ollama.
- Three paces. *Continuous* inspects frames back to back. *Interval* takes a frame every 0.1 s
  to 5 min into a queue that is processed first in, first out. *Stop points only* inspects when
  the robot stops on its route.
- Own finding types: add a type with a description of what the AI should look for, and choose
  whether it is reported to NETRA or only shown on the handheld. Types can also be edited or
  removed.
- The last result is shown on the main screen, e.g. **Clean · 3 s ago** or **Trash · 12 s ago**.
  The queue length is shown there too. A haptic toast pops up on every finding.
- Person detection on or off, with the people count. Patrol speed is set with a slider.

**Monitor**
- Battery, link quality, protective field, health and the localization source (identity, tag or
  pose).
- The robot's CPU, GPU and RAM use and its temperature, at a glance, for development.

**Everything else**
- Finds robots on the LAN by itself, and connects with a token.
- Indonesian and English.

## Install

**From CI (no Flutter needed).** Every push to `main` builds a release APK.

1. Open [Actions](https://github.com/DarmawanRobotics/PashupatiController/actions/workflows/ci.yml)
   and pick the latest green run.
2. Download the `pashupati-controller-apk` artifact.
3. Unzip it and install the APK:

```bash
adb uninstall com.darmawanrobotics.flutter_teleop   # only when switching from a locally built APK
adb install app-release.apk
```

**From source.** You need Flutter 3.35 or newer, and the handheld on USB showing in `adb devices`.

```bash
git clone git@github.com:DarmawanRobotics/PashupatiController.git && cd PashupatiController
flutter pub get
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk     # or: flutter run --release
```

APKs built locally are signed with your debug key, and the CI ones with the CI key. Android only
updates an app in place with the same key, so when you switch between the two, uninstall first.
Uninstalling clears the app's settings.

**First connection.** On the start screen, tap the version three times to open the connection
settings. Enter the robot address (default `192.168.234.234:9870`) and its token. Robots on the
same network also show up in the list by themselves.

## Robot side

The token and the action icons come from the robot's `/etc/pashupati/site.yaml`:

```yaml
teleop_udp_node:
  ros__parameters:
    token: "<secret>"           # the same in the app
    robot_commands: [stand_up, sit_down, balance_stand_mode, move_mode, slow_speed, normal_speed,
                     fast_speed, emergency_stop]
```

What the app can do depends on what the robot runs, set in `/etc/pashupati/pashupati.env`:

| Feature | On the robot | In the app |
|---|---|---|
| WebRTC video | `WEBRTC=true`, `script/setup.sh install webrtc` (MediaMTX) | smooth video; JPEG without it |
| AI inspection | `INSPECTION=true`, `script/setup.sh install ollama` | Inspection page, results on the main screen |
| Person detection | `PEOPLE=true`, `script/setup.sh install people_model` | people count and boxes on the video |
| Fleet | `CC_URL`, `CC_TOKEN`, `ROBOT_ID` | findings and telemetry reach NETRA |

A robot running an older stack simply offers fewer commands, and the app hides or explains the
features it lacks.

## Controls

| | Gamepad | Touch |
|---|---|---|
| Drive and strafe | left stick | |
| Turn | right stick | |
| STOP (software e-stop) | B, on every page | red button |
| AUTO / REMOTE | Start | switch on top |
| Swap camera and map | Select | tap the small view |
| Speed level (30 / 60 / 100 % of the robot's limits) | D-pad up / down | Settings, Speed |
| Robot actions | L1 + A stand up, L1 + Y sit down | icons under STOP |
| Map | | pinch, drag, twist; double tap follows the robot |

The robot only takes the joystick in REMOTE; in AUTO, navigation drives. After a STOP, nothing
but zero reaches the robot until *Hold to release* is held for a second.

**Teach and patrol.**
1. Switch to REMOTE and tap Record.
2. Drive the route. Tap Point wherever the robot should stop and inspect.
3. Tap Finish.
4. Open Routes, pick the route, switch to AUTO and tap Start.

**Settings** (gear) apply at once: speed level, R1 to drive, video, lidar on the map, robot load
on screen, language, and how long the robot inspects at a stop point. A gamepad test is there
too.

## Develop

```
lib/
├── protocol/   messages.dart (JSON of the teleop protocol), streams.dart (camera / lidar / route)
├── net/        teleop_client.dart (session, commands, joystick), discovery.dart,
│               webrtc_video.dart + whep.dart (camera over WebRTC)
├── input/      gamepad_input.dart (gamepads, normalized)
├── widgets/    hud, camera (tag and person boxes), map, glance (AI, people, load)
├── screens/    connect, drive (home), patrol (inspection), routes, settings
├── robot_actions.dart   icons and labels of known robot commands
└── l10n.dart            Indonesian and English text
```

```bash
flutter analyze
flutter test                  # protocol, widgets and pages at Retroid Pocket size
```

CI runs on every push. It analyzes the code, runs the tests and turns failures into annotations,
reports formatting, and builds the release APK. Bump `version` in `pubspec.yaml` with every
release. When a dependency changes, commit the `pubspec.lock` that `flutter pub get` writes.

Barlow Semi Condensed is under the SIL Open Font License (`assets/fonts/OFL.txt`). The app is
released under the [Apache License 2.0](LICENSE).
