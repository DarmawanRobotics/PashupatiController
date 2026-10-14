import 'package:flutter/material.dart';

import '../robot_actions.dart';
import '../theme.dart';
import 'hud.dart';

/// The robot's own commands (postures, gaits, speed gears, ...) as a grid of tiles.
class ActionsPanel extends StatelessWidget {
  const ActionsPanel({
    super.key,
    required this.commands,
    required this.language,
    required this.busy,
    required this.onRun,
    required this.onClose,
    required this.title,
    required this.emptyText,
  });

  final List<String> commands;
  final String language;
  final Set<String> busy;
  final ValueChanged<RobotAction> onRun;
  final VoidCallback onClose;
  final String title;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    return Glass(
      blur: true,
      color: Palette.glassHigh,
      radius: 16,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: Txt.title)),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
                color: Palette.muted,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: commands.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(emptyText, style: Txt.small, textAlign: TextAlign.center),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.only(right: 6),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 104,
                      mainAxisExtent: 76,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: commands.length,
                    itemBuilder: (context, index) {
                      final action = robotAction(commands[index]);
                      return _ActionTile(
                        action: action,
                        label: action.label(language),
                        busy: busy.contains(action.name),
                        onTap: () => onRun(action),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.action,
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final RobotAction action;
  final String label;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: action.confirm ? Palette.caution.withValues(alpha: 0.5) : Palette.line,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 26,
                child: busy
                    ? const Center(
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Palette.remote),
                        ),
                      )
                    : Icon(action.icon, size: 26, color: Palette.text),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: Txt.small.copyWith(color: Palette.text, height: 1.1),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
