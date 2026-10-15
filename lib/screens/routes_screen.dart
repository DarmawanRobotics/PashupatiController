import 'package:flutter/material.dart';

import '../net/teleop_client.dart';
import '../settings.dart';
import '../theme.dart';

/// Recorded routes on the robot, newest first; tap one to load it for the patrol.
class RoutesScreen extends StatefulWidget {
  const RoutesScreen({super.key, required this.services, required this.onRun});

  final Services services;
  final RunCommand onRun;

  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  List<String>? _routes;
  String? _error;
  String? _loading;

  String t(String key, [Map<String, Object> args = const {}]) => widget.services.t(key, args);

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _routes = null;
      _error = null;
    });
    final result = await widget.onRun('list_routes', label: t('routes'), quiet: true);
    if (!mounted) return;
    final data = result.data;
    setState(() {
      _error = result.ok ? null : (result.message.isEmpty ? t('failed') : result.message);
      _routes = data is List ? data.whereType<String>().toList() : const [];
    });
  }

  Future<void> _load(String path) async {
    setState(() => _loading = path);
    final result = await widget.onRun(
      'load_route',
      args: {'file': path},
      label: t('route_loaded'),
    );
    if (!mounted) return;
    setState(() => _loading = null);
    if (result.ok) {
      Navigator.of(context).pop();
    } else {
      final text = result.message.isEmpty ? t('failed') : result.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final routes = _routes;
    final error = _error;
    final Widget body;
    if (routes == null) {
      body = const Center(child: CircularProgressIndicator(color: Palette.auto));
    } else if (error != null) {
      body = Center(child: Text(error, style: Txt.body.copyWith(color: Palette.stop)));
    } else if (routes.isEmpty) {
      body = Center(child: Text(t('no_routes'), style: Txt.body.copyWith(color: Palette.muted)));
    } else {
      body = GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 260,
          mainAxisExtent: 64,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: routes.length,
        itemBuilder: (context, index) => _RouteTile(
          path: routes[index],
          loading: _loading == routes[index],
          onTap: _loading == null ? () => _load(routes[index]) : null,
        ),
      );
    }
    return Scaffold(
      backgroundColor: Palette.night,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(child: Text(t('routes'), style: Txt.title)),
                  IconButton(
                    onPressed: _routes == null ? null : _fetch,
                    tooltip: t('refresh'),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _RouteTile extends StatelessWidget {
  const _RouteTile({required this.path, required this.loading, required this.onTap});

  final String path;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final parts = path.split('/');
    final name = parts.last.replaceAll(RegExp(r'(_path)?\.csv$'), '');
    final folder = parts.length > 1 ? parts[parts.length - 2] : '';
    return Material(
      color: Palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: loading ? Palette.auto : Palette.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              const Icon(Icons.route_rounded, color: Palette.auto),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: Txt.label.copyWith(fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (folder.isNotEmpty) Text(folder, style: Txt.small),
                  ],
                ),
              ),
              if (loading)
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
