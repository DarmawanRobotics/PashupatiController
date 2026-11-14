import 'package:flutter/material.dart';

import '../l10n.dart';
import '../protocol/messages.dart';
import '../theme.dart';
import 'hud.dart';

/// The robot's trip meter under the glance panel: distance and moving time, the speed now, the
/// average and the top speed since the last reset. The robot counts (also while no handheld is
/// connected); holding the panel asks it to start again from zero.
class TripPanel extends StatelessWidget {
  const TripPanel({super.key, required this.trip, required this.language, this.onReset});

  final TripStatus trip;
  final String language;

  /// Hold to reset; null on a robot that cannot (no trip_reset command).
  final VoidCallback? onReset;

  String t(String key, [Map<String, Object> args = const {}]) => tr(language, key, args);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('trip'),
      behavior: HitTestBehavior.opaque,
      onLongPress: onReset,
      child: Glass(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(
              Icons.route_rounded,
              Palette.text,
              t('trip_distance', {
                'd': formatDistance(trip.distance),
                't': formatDuration(trip.movingSeconds),
              }),
              strong: true,
            ),
            _row(
              Icons.speed_rounded,
              trip.speed > 0 ? Palette.auto : Palette.muted,
              t('trip_speed', {'v': trip.speed.toStringAsFixed(2)}),
            ),
            _row(
              Icons.show_chart_rounded,
              Palette.muted,
              t('trip_average', {
                'a': trip.average.toStringAsFixed(2),
                'm': trip.top.toStringAsFixed(2),
              }),
            ),
            if (onReset != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  t('trip_hold'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Txt.small.copyWith(color: Palette.muted, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, Color color, String text, {bool strong = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: strong ? Txt.label.copyWith(color: color) : Txt.small,
            ),
          ),
        ],
      ),
    );
  }
}
