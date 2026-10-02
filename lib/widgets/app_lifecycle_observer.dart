import 'package:flutter/material.dart';
import '../services/network_ping_service.dart';

class AppLifecycleObserver with WidgetsBindingObserver {
  final NetworkPingService pingService;

  AppLifecycleObserver({required this.pingService});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      pingService.setAppBackground(true);
    } else if (state == AppLifecycleState.resumed) {
      pingService.setAppBackground(false);
    }
  }
}
