import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../net/teleop_client.dart';
import '../protocol/messages.dart';
import '../theme.dart';
import '../widgets/hud.dart';

/// Colour, icon and label key of the inspection state, for this page and the toolbar button.
({Color color, IconData icon, String key}) inspectionLook(InspectionStatus? status) {
  if (status == null) {
    return (color: Palette.muted, icon: Icons.visibility_off_rounded, key: 'insp_missing');
  }
  return switch (status.state) {
    'running' => (color: Palette.ok, icon: Icons.visibility_rounded, key: 'insp_running'),
    'loading' => (color: Palette.caution, icon: Icons.hourglass_top_rounded, key: 'insp_loading'),
    'error' => (color: Palette.stop, icon: Icons.error_rounded, key: 'insp_error'),
    'off' => (color: Palette.muted, icon: Icons.visibility_off_rounded, key: 'insp_off'),
    _ => (color: Palette.caution, icon: Icons.link_off_rounded, key: 'insp_offline'),
  };
}

/// Inspection and patrol, live on the robot: the VLM inspection on or off, its pace and model,
/// what it saw last, person detection on or off, and the patrol speed.
class PatrolScreen extends StatefulWidget {
  const PatrolScreen({
    super.key,
    required this.client,
    required this.language,
    required this.onRun,
  });

  final TeleopClient client;
  final String language;
  final RunCommand onRun;

  @override
  State<PatrolScreen> createState() => _PatrolScreenState();
}

class _PatrolScreenState extends State<PatrolScreen> {
  /// Seconds between two inspections in the interval pace.
  static const _intervals = [2.0, 5.0, 10.0, 30.0, 60.0];

  List<InspectionModel>? _models;
  String? _modelsError;
  final Set<String> _busy = {};
  String? _switchingTo;
  double? _speedDraft;

  TeleopClient get client => widget.client;

  String t(String key, [Map<String, Object> args = const {}]) => tr(widget.language, key, args);

  bool _has(String command) => client.welcome?.has(command) ?? false;

  @override
  void initState() {
    super.initState();
    _fetchModels();
  }

  Future<void> _fetchModels() async {
    if (!_has('inspection_models')) {
      setState(() => _models = const []);
      return;
    }
    setState(() {
      _models = null;
      _modelsError = null;
    });
    final result = await widget.onRun('inspection_models', label: t('models'), quiet: true);
    if (!mounted) return;
    setState(() {
      _models = InspectionModel.listFromJson(result.data);
      _modelsError = result.ok ? null : (result.message.isEmpty ? t('failed') : result.message);
    });
  }

  /// Runs a command; [key] marks its control busy meanwhile. A failure shows why.
  Future<bool> _send(String key, String name, Map<String, Object?> args, String label) async {
    setState(() => _busy.add(key));
    final result = await widget.onRun(name, args: args, label: label, quiet: true);
    if (!mounted) return result.ok;
    setState(() => _busy.remove(key));
    if (!result.ok) {
      final why = result.message.isEmpty ? t('failed') : result.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label: $why')));
    }
    return result.ok;
  }

  void _setPeople(bool on) {
    _send('people', 'people_set', {'enabled': on}, t(on ? 'people_on' : 'people_off_done'));
  }

  void _setEnabled(bool on) {
    _send('enabled', 'inspection_set', {'enabled': on}, t(on ? 'inspection_on' : 'inspection_off'));
  }

  void _setPace(String pace, double current) {
    final interval = switch (pace) {
      'continuous' => 0.0,
      'stops' => -1.0,
      _ => current > 0 ? current : 10.0,
    };
    _send('pace', 'inspection_set', {'interval': interval}, t('pace'));
  }

  void _setInterval(double seconds) {
    _send('pace', 'inspection_set', {'interval': seconds}, t('pace'));
  }

  Future<void> _setModel(String name) async {
    setState(() => _switchingTo = name);
    await _send('model', 'inspection_set', {'model': name}, t('model'));
    if (mounted) setState(() => _switchingTo = null);
  }

  Future<void> _setSpeed(double speed) async {
    final value = double.parse(speed.toStringAsFixed(2));
    await _send('speed', 'nav_speed', {'speed': value}, t('patrol_speed'));
    if (mounted) setState(() => _speedDraft = null);
  }

  /// The offered interval closest to [seconds].
  static double _nearest(double seconds) =>
      _intervals.reduce((a, b) => (a - seconds).abs() <= (b - seconds).abs() ? a : b);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.night,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: client,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(child: Text(t('patrol_page'), style: Txt.title)),
                    IconButton(
                      onPressed: _models == null ? null : _fetchModels,
                      tooltip: t('refresh'),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 6, child: _inspection(client.state.inspection)),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 5,
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 16),
                          children: [
                            _people(client.state.people),
                            const SizedBox(height: 12),
                            _speed(client.state.speed),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _inspection(InspectionStatus? status) {
    final live = _has('inspection_set') && status != null && status.state != 'offline';
    final pace = status?.pace ?? 'continuous';
    final current = status?.interval ?? 0.0;
    return ListView(
      padding: const EdgeInsets.only(left: 8, right: 4, bottom: 16),
      children: [
        _section(t('section_inspection')),
        _statusCard(status),
        const SizedBox(height: 6),
        SwitchListTile(
          key: const ValueKey('inspection-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(t('inspection_switch'), style: Txt.body),
          subtitle: Text(t('inspection_switch_hint'), style: Txt.small),
          value: status?.on ?? false,
          onChanged: live && !_busy.contains('enabled') ? _setEnabled : null,
        ),
        _choice(
          t('pace'),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'continuous', label: Text(t('pace_continuous'))),
              ButtonSegment(value: 'interval', label: Text(t('pace_interval'))),
              ButtonSegment(value: 'stops', label: Text(t('pace_stops'))),
            ],
            selected: {pace},
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            onSelectionChanged: live && !_busy.contains('pace')
                ? (selection) => _setPace(selection.first, current)
                : null,
          ),
          hint: t('pace_hint_$pace'),
        ),
        if (pace == 'interval')
          _choice(
            t('every'),
            SegmentedButton<double>(
              segments: [
                for (final seconds in _intervals)
                  ButtonSegment(value: seconds, label: Text('${seconds.round()} s')),
              ],
              selected: {_nearest(current)},
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              onSelectionChanged: live && !_busy.contains('pace')
                  ? (selection) => _setInterval(selection.first)
                  : null,
            ),
          ),
        _section(t('section_model')),
        ..._modelTiles(status, live),
      ],
    );
  }

  Widget _statusCard(InspectionStatus? status) {
    final look = inspectionLook(status);
    final lines = <String>[];
    if (status == null) {
      lines.add(t('inspection_missing'));
    } else {
      if (status.model.isNotEmpty) lines.add(status.model);
      lines.add(t('inspection_counts', {'n': status.count, 'm': status.reports}));
      final last = status.last;
      if (last != null) lines.add(_lastText(last));
      if (status.state == 'error' && status.error.isNotEmpty) lines.add(status.error);
    }
    return Glass(
      color: Palette.panel,
      border: look.color.withValues(alpha: 0.5),
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(look.icon, size: 18, color: look.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(t(look.key), style: Txt.title.copyWith(color: look.color)),
              ),
            ],
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(line, style: Txt.small.copyWith(color: Palette.text)),
            ),
        ],
      ),
    );
  }

  String _lastText(InspectionResult last) {
    final what = last.clear ? t('cat_none') : categoryLabel(widget.language, last.category);
    final age = last.age;
    final parts = [
      t('last_result', {'what': what}),
      '${(last.latencyMs / 1000).toStringAsFixed(1)} s',
      if (age != null) age < 60 ? t('ago_s', {'n': age}) : t('ago_min', {'n': age ~/ 60}),
      if (last.reported) t('reported'),
    ];
    final text = parts.join('  ·  ');
    return last.description.isEmpty ? text : '$text\n${last.description}';
  }

  List<Widget> _modelTiles(InspectionStatus? status, bool live) {
    final models = _models;
    final error = _modelsError;
    if (models == null) {
      return const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(color: Palette.auto)),
        ),
      ];
    }
    if (error != null) return [Text(error, style: Txt.body.copyWith(color: Palette.stop))];
    if (models.isEmpty) return [Text(t('no_models'), style: Txt.small)];
    final current = status == null ? '' : fullModelName(status.model);
    final loading = status?.state == 'loading';
    return [
      for (final model in models)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ModelTile(
            name: model.name,
            note: fullModelName(model.name) == current
                ? t('model_active')
                : switch (model.installed) {
                    true => t('model_ready'),
                    false => t('model_missing', {'name': model.name}),
                    null => t('model_unknown'),
                  },
            active: fullModelName(model.name) == current,
            working:
                _switchingTo == model.name || (loading && fullModelName(model.name) == current),
            onTap:
                live &&
                    _switchingTo == null &&
                    model.installed != false &&
                    fullModelName(model.name) != current
                ? () => _setModel(model.name)
                : null,
          ),
        ),
    ];
  }

  Widget _speed(PatrolSpeed? speed) {
    final supported = _has('nav_speed');
    final children = <Widget>[
      Text(t('patrol_speed'), style: Txt.title),
      const SizedBox(height: 8),
    ];
    if (!supported || speed == null || speed.max <= speed.min) {
      final why = t(supported ? 'speed_unavailable' : 'speed_unsupported');
      children.add(Text(why, style: Txt.small));
    } else {
      final value = math.min(math.max(_speedDraft ?? speed.target, speed.min), speed.max);
      children.addAll([
        Text('${value.toStringAsFixed(2)} m/s', style: Txt.display.copyWith(fontSize: 34)),
        const SizedBox(height: 4),
        Slider(
          value: value,
          min: speed.min,
          max: speed.max,
          divisions: math.max(1, ((speed.max - speed.min) / 0.05).round()),
          label: value.toStringAsFixed(2),
          onChanged: _busy.contains('speed') ? null : (v) => setState(() => _speedDraft = v),
          onChangeEnd: _busy.contains('speed') ? null : _setSpeed,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(speed.min.toStringAsFixed(2), style: Txt.small),
            Text(speed.max.toStringAsFixed(2), style: Txt.small),
          ],
        ),
        const SizedBox(height: 8),
        Text(t('patrol_speed_hint'), style: Txt.small),
      ]);
    }
    return Glass(
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _people(PeopleStatus? people) {
    final live = _has('people_set') && people != null && people.state != 'offline';
    final lines = <String>[];
    if (people == null) {
      lines.add(t('people_missing'));
    } else {
      final count = people.count;
      if (count != null) {
        lines.add(
          t('people_detail', {'n': count, 'ms': people.latencyMs, 'backend': people.backend}),
        );
      }
      if (people.state == 'error' && people.error.isNotEmpty) lines.add(people.error);
    }
    return Glass(
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('section_people'), style: Txt.title),
          SwitchListTile(
            key: const ValueKey('people-switch'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(t('people_switch'), style: Txt.body),
            subtitle: Text(t('people_switch_hint'), style: Txt.small),
            value: people?.on ?? false,
            onChanged: live && !_busy.contains('people') ? _setPeople : null,
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(line, style: Txt.small.copyWith(color: Palette.text)),
            ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        title.toUpperCase(),
        style: Txt.small.copyWith(
          color: Palette.auto,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _choice(String label, Widget control, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Txt.body),
          const SizedBox(height: 6),
          control,
          if (hint != null) ...[const SizedBox(height: 4), Text(hint, style: Txt.small)],
        ],
      ),
    );
  }
}

/// One model the robot can inspect with; tap to switch to it.
class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.name,
    required this.note,
    required this.active,
    required this.working,
    required this.onTap,
  });

  final String name;
  final String note;
  final bool active;

  /// Switching to it, or the robot is loading it.
  final bool working;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: active ? Palette.ok : Palette.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                active ? Icons.check_circle_rounded : Icons.memory_rounded,
                color: active ? Palette.ok : Palette.muted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: Txt.label.copyWith(fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(note, style: Txt.small, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (working)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Palette.auto),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
