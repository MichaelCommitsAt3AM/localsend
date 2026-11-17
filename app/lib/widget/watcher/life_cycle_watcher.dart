import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

class LifeCycleWatcher extends StatefulWidget {
  final Widget child;
  final void Function(AppLifecycleState state) onChangedState;

  /// Runs only while resumed, with at most one check in flight.
  final Future<void> Function()? checkConnections;

  const LifeCycleWatcher({required this.child, required this.onChangedState, this.checkConnections, super.key});

  @override
  State<LifeCycleWatcher> createState() => _LifeCycleWatcherState();
}

class _LifeCycleWatcherState extends State<LifeCycleWatcher> with WidgetsBindingObserver {
  Timer? _timer;
  bool _checking = false;

  void _scheduleChecks() {
    _timer?.cancel();
    if (widget.checkConnections == null) return;
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_check()));
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      await widget.checkConnections?.call();
    } catch (error, stack) {
      Logger('ConnectionHealth').warning('Connection health check failed', error, stack);
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) _scheduleChecks();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (state == AppLifecycleState.resumed) {
      _scheduleChecks();
      unawaited(_check());
    }
    widget.onChangedState(state);
  }
}
