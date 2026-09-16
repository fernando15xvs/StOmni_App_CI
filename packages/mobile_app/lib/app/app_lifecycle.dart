import 'package:flutter/material.dart';

import 'package:core_logic/core_logic.dart';
import '../splash/splash_screen.dart';
import 'app_router.dart';

class AppLifecycleObserver extends StatefulWidget {
  const AppLifecycleObserver({required this.child, super.key});

  final Widget child;

  @override
  State<AppLifecycleObserver> createState() => _AppLifecycleObserverState();
}

class _AppLifecycleObserverState extends State<AppLifecycleObserver>
    with WidgetsBindingObserver {
  DateTime? _lastPausedTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _lastPausedTime = DateTime.now();
      return;
    }

    if (state != AppLifecycleState.resumed || _lastPausedTime == null) {
      return;
    }

    final diff = DateTime.now().difference(_lastPausedTime!);
    _lastPausedTime = null;

    if (diff.inMinutes >= 60) {
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SplashScreen()),
        (route) => false,
      );
      return;
    }

    if (diff.inMinutes >= 10) {
      AppTime.sync();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
