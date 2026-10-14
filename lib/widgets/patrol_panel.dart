import 'package:flutter/material.dart';

import '../net/teleop_client.dart';
import '../protocol/messages.dart';
import '../settings.dart';
import '../theme.dart';
import 'hud.dart';

/// Patrol controls: localization, routes, navigation, route recording and stop points.
class PatrolPanel extends StatefulWidget {
  const PatrolPanel({
    super.key,
    required this.services,
    required this.busy,
    required this.onRun,
    required this.onClose,
  });

  final Services services;
  final Set<String> busy;
  final RunCommand onRun;
  final VoidCallback onClose;

  @override
  State<PatrolPanel> createState() => _PatrolPanelState();
}

class _PatrolPanelState extends State<PatrolPanel> {
  static const _dwells = [5.0, 10.0, 30.0];

  bool _showRoutes = false;
  List<String>? _routes;
  String? _routesError;
  String? _loading;
  double _dwell = 10;

  Services get s => widget.services;

  String _navLabel(String nav) {
    final label = s.t('nav_$nav');
    return label.startsWith('nav_') ? nav : label;
  }

  Future<void> _openRoutes() async {
    setState(() {
      _showRoutes = true;
      _routes = null;
      _routesError = null;
    });
    final result = await widget.onRun('list_routes', label: s.t('routes'), quiet: true);
    if (!mounted) return;
    final data = result.data;
    setState(() {
      _routesError = result.ok ? null : result.message;
      _routes = data is List ? data.whereType<String>().toList() : const [];
    });
  }

  Future<void> _load(String path) async {
    setState(() => _loading = path);
    final result = await widget.onRun(
      'load_route',
      args: {'file': path},
      label: s.t('route_loaded'),
    );
    if (!mounted) return;
    setState(() {
      _loading = null;
      if (result.ok) _showRoutes = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Glass(
      blur: true,
      color: Palette.glassHigh,
      radius: 16,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 12),
      child: ListenableBuilder(
        listenable: s.client,
        builder: (context, _) => _showRoutes ? _routesView() : _mainView(),
      ),
    );
  }

  Widget _header(String title, {VoidCallback? onBack}) {
    return Row(
      children: [
        if (onBack != null)
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
            color: Palette.muted,
            visualDensity: VisualDensity.compact,
          ),
        Expanded(child: Text(title, style: Txt.title)),
        IconButton(
          onPressed: widget.onClose,
          icon: const Icon(Icons.close_rounded),
          color: Palette.muted,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _row(String name, String value, {String? detail, Color color = Palette.text}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, right: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 84, child: Text(name, style: Txt.small)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: Txt.label.copyWith(color: color)),
                if (detail != null && detail.isNotEmpty)
                  Text(detail, style: Txt.small, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mainView() {
    final state = s.client.state;
    final welcome = s.client.welcome;
    bool has(String command) => welcome?.has(command) ?? false;
    bool busy(String command) => widget.busy.contains(command);
    final run = widget.onRun;

    final Widget navPrimary;
    if (state.navPaused) {
      navPrimary = PanelButton(
        icon: Icons.play_arrow_rounded,
        label: s.t('resume'),
        tint: Palette.auto,
        filled: true,
        busy: busy('nav_resume'),
        onPressed: has('nav_resume') ? () => run('nav_resume', label: s.t('resume')) : null,
      );
    } else if (state.navActive) {
      navPrimary = PanelButton(
        icon: Icons.pause_rounded,
        label: s.t('pause'),
        tint: Palette.auto,
        busy: busy('nav_pause'),
        onPressed: has('nav_pause') ? () => run('nav_pause', label: s.t('pause')) : null,
      );
    } else {
      navPrimary = PanelButton(
        icon: Icons.play_arrow_rounded,
        label: s.t('start'),
        tint: Palette.auto,
        filled: true,
        busy: busy('nav_start'),
        onPressed: has('nav_start') ? () => run('nav_start', label: s.t('start')) : null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(s.t('patrol')),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(right: 6),
            children: [
              _row(s.t('navigation'), _navLabel(state.nav), detail: state.navMessage),
              _row(
                s.t('position'),
                state.localized
                    ? s.t('localized', {'source': state.localization})
                    : s.t('not_localized'),
                color: state.localized ? Palette.text : Palette.caution,
              ),
              if (state.recording) _row('', s.t('recording'), color: Palette.remote),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: PanelButton(
                      icon: Icons.my_location_rounded,
                      label: s.t('localize'),
                      busy: busy('localize'),
                      onPressed: has('localize')
                          ? () => run('localize', label: s.t('localize'))
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: PanelButton(
                      icon: Icons.route_rounded,
                      label: s.t('routes'),
                      onPressed: has('list_routes') && has('load_route') ? _openRoutes : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: navPrimary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: PanelButton(
                      icon: Icons.stop_rounded,
                      label: s.t('stop_nav'),
                      busy: busy('nav_stop'),
                      onPressed: has('nav_stop') && state.nav != 'NAV_INACTIVE'
                          ? () => run('nav_stop', label: s.t('stop_nav'))
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              PanelButton(
                icon: state.recording
                    ? Icons.stop_circle_rounded
                    : Icons.fiber_manual_record_rounded,
                label: state.recording ? s.t('record_stop') : s.t('record'),
                tint: Palette.remote,
                filled: state.recording,
                busy: busy('record_start') || busy('record_stop'),
                onPressed: has('record_start')
                    ? () => (state.recording
                          ? run('record_stop', label: s.t('record_stop'))
                          : run('record_start', label: s.t('record')))
                    : null,
              ),
              const SizedBox(height: 8),
              PanelButton(
                icon: Icons.flag_rounded,
                label: '${s.t('mark_stop')}  ${s.t('dwell', {'s': _dwell.round()})}',
                busy: busy('mark_stop'),
                onPressed: has('mark_stop')
                    ? () => run('mark_stop', args: {'dwell': _dwell}, label: s.t('mark_stop'))
                    : null,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final dwell in _dwells)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text('${dwell.round()} s', style: Txt.label),
                        selected: _dwell == dwell,
                        onSelected: (_) => setState(() => _dwell = dwell),
                        visualDensity: VisualDensity.compact,
                        showCheckmark: false,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              PanelButton(
                icon: Icons.qr_code_2_rounded,
                label: s.t('record_tags'),
                busy: busy('record_tags'),
                onPressed: has('record_tags')
                    ? () => run('record_tags', label: s.t('record_tags'))
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _routesView() {
    final routes = _routes;
    final error = _routesError;
    final Widget body;
    if (routes == null) {
      body = Center(child: Text(s.t('loading'), style: Txt.small));
    } else if (error != null) {
      body = Center(
        child: Text(
          '${s.t('routes')}: ${error.isEmpty ? s.t('failed') : error}',
          style: Txt.small.copyWith(color: Palette.stop),
          textAlign: TextAlign.center,
        ),
      );
    } else if (routes.isEmpty) {
      body = Center(child: Text(s.t('no_routes'), style: Txt.small));
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.only(right: 6),
        itemCount: routes.length,
        separatorBuilder: (context, index) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final path = routes[index];
          final parts = path.split('/');
          final file = parts.last.replaceAll(RegExp(r'\.csv$'), '');
          final folder = parts.length > 1 ? parts[parts.length - 2] : '';
          final current = _loading == path;
          return Material(
            color: Colors.white.withValues(alpha: 0.06),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Palette.line),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _loading == null ? () => _load(path) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.route_rounded, size: 18, color: Palette.auto),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(file, style: Txt.label, overflow: TextOverflow.ellipsis),
                          if (folder.isNotEmpty) Text(folder, style: Txt.small),
                        ],
                      ),
                    ),
                    if (current)
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Palette.auto),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(s.t('routes'), onBack: () => setState(() => _showRoutes = false)),
        Expanded(child: body),
      ],
    );
  }
}

/// Label of a navigation state, for other widgets.
String navStateLabel(Services services, RobotState state) {
  final label = services.t('nav_${state.nav}');
  return label.startsWith('nav_') ? state.nav : label;
}
