import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/messages.dart';
import '../theme.dart';

/// Translucent panel over the video.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    this.radius = 12,
    this.color = Palette.glass,
    this.border = Palette.line,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color color;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Round icon button (disconnect, settings, view buttons).
class HudButton extends StatelessWidget {
  const HudButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.label,
    this.size = 44,
    this.tint = Palette.text,
    this.active = false,
    this.busy = false,
    this.iconAngle = 0,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? label;
  final double size;
  final Color tint;
  final bool active;
  final bool busy;

  /// Turn of the icon, radians clockwise (a compass needle).
  final double iconAngle;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      label: label,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? tint.withValues(alpha: 0.22) : Palette.glass,
                border: Border.all(color: active ? tint : Palette.line, width: active ? 1.5 : 1),
              ),
              child: Center(
                child: busy
                    ? SizedBox.square(
                        dimension: size * 0.4,
                        child: CircularProgressIndicator(strokeWidth: 2, color: tint),
                      )
                    : Transform.rotate(
                        angle: iconAngle,
                        child: Icon(icon, size: size * 0.48, color: tint),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small label + value capsule of the top bar.
class HudChip extends StatelessWidget {
  const HudChip({super.key, required this.child, this.onTap, this.border = Palette.line});

  final Widget child;
  final VoidCallback? onTap;
  final Color border;

  @override
  Widget build(BuildContext context) {
    final chip = Glass(
      radius: 18,
      border: border,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: child,
    );
    if (onTap == null) return chip;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: chip);
  }
}

/// Three rising bars for link quality (0..3 lit).
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.level, required this.color});

  final int level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: 3.5,
            height: 6.0 + i * 4,
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              color: i < level ? color : Palette.line,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
      ],
    );
  }
}

class BatteryChip extends StatelessWidget {
  const BatteryChip({super.key, required this.battery});

  final Battery? battery;

  @override
  Widget build(BuildContext context) {
    final pct = battery?.percent;
    final color = pct == null
        ? Palette.muted
        : pct < 20
        ? Palette.stop
        : pct < 35
        ? Palette.caution
        : Palette.text;
    final icon = pct == null
        ? Icons.battery_unknown_rounded
        : pct < 20
        ? Icons.battery_alert_rounded
        : Icons.battery_full_rounded;
    return HudChip(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 3),
          Text(pct == null ? '--' : '${pct.round()}%', style: Txt.figure.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// AUTO / REMOTE switch; the active side takes its driver colour.
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({
    super.key,
    required this.mode,
    required this.onSelect,
    required this.autoLabel,
    required this.remoteLabel,
    this.busy = false,
  });

  final String mode;
  final ValueChanged<String> onSelect;
  final String autoLabel;
  final String remoteLabel;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final remote = mode == 'remote';
    return Glass(
      radius: 20,
      padding: const EdgeInsets.all(3),
      child: SizedBox(
        width: 176,
        height: 32,
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: remote ? Alignment.centerRight : Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: 0.5,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Palette.forMode(mode),
                    borderRadius: BorderRadius.circular(17),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                _side('auto', autoLabel, !remote),
                _side('remote', remoteLabel, remote),
              ],
            ),
            if (busy)
              const Positioned(
                right: 6,
                top: 0,
                bottom: 0,
                child: Center(
                  child: SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.6, color: Palette.night),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _side(String value, String label, bool selected) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: selected ? null : () => onSelect(value),
        child: Center(
          child: Text(
            label,
            style: Txt.label.copyWith(
              color: selected ? Palette.night : Palette.muted,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),
    );
  }
}

/// The software e-stop: always on screen, one tap.
class StopButton extends StatelessWidget {
  const StopButton({super.key, required this.onPressed, required this.engaged});

  final VoidCallback onPressed;
  final bool engaged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Emergency stop',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.heavyImpact();
            onPressed();
          },
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Palette.stop.withValues(alpha: engaged ? 1 : 0.88),
              border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: Palette.stop.withValues(alpha: engaged ? 0.7 : 0.35),
                  blurRadius: engaged ? 18 : 10,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: const Text(
              'STOP',
              style: TextStyle(
                fontFamily: Txt.family,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Message shown briefly under the icons.
class Toast {
  const Toast(this.text, {this.color = Palette.text, this.icon});

  final String text;
  final Color color;
  final IconData? icon;
}

class ToastView extends StatelessWidget {
  const ToastView({super.key, required this.toast});

  final Toast toast;

  @override
  Widget build(BuildContext context) {
    return Glass(
      color: Palette.glassHigh,
      border: toast.color.withValues(alpha: 0.6),
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (toast.icon != null) ...[
            Icon(toast.icon, size: 16, color: toast.color),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              toast.text,
              style: Txt.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Icon with a short label under it: the mapping strip and the robot action rail.
class ActionButton extends StatelessWidget {
  const ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tint = Palette.text,
    this.active = false,
    this.busy = false,
    this.width = 52,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color tint;

  /// Highlighted (recording, current mode, ...).
  final bool active;
  final bool busy;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Opacity(
        opacity: onPressed == null ? 0.38 : 1,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: busy ? null : onPressed,
            child: SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? tint.withValues(alpha: 0.25) : Colors.transparent,
                        border: Border.all(color: active ? tint : Colors.transparent, width: 1.5),
                      ),
                      child: Center(
                        child: busy
                            ? SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: tint),
                              )
                            : Icon(icon, size: 21, color: tint),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Txt.small.copyWith(fontSize: 10.5, height: 1, color: Palette.text),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
