import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:http/http.dart' as http;

class NetworkPingService with ChangeNotifier {
  bool _isEnabled = true;
  bool _isInBackground = false; // Track background state

  bool _isOnline = false;
  int _latencyMs = -1;
  double _speedKbps = 0.0;
  String _lastError = '';
  DateTime? _lastSuccessfulPing;

  bool get isEnabled => _isEnabled;
  bool get isInBackground => _isInBackground;
  bool get isOnline => _isOnline;
  int get latencyMs => _latencyMs;
  double get speedKbps => _speedKbps;
  String get lastError => _lastError;
  DateTime? get lastSuccessfulPing => _lastSuccessfulPing;

  String get connectionQuality {
    if (_latencyMs < 0 || _speedKbps <= 0) return 'Offline';
    // More realistic thresholds based on actual speed
    if (_speedKbps >= 1500) return 'Strong';      // >= 1.5 Mbps
    if (_speedKbps >= 300) return 'Average';       // >= 300 Kbps
    return 'Weak';
  }

  Timer? _periodicPing;

  final List<String> _testUrls = [
    'https://www.google.com',
    'https://script.google.com',
    'https://www.cloudflare.com',
  ];

  /// Toggles whether the ping service is actively running
  void setEnabled(bool value) {
    if (_isEnabled == value) return;

    _isEnabled = value;

    if (_isEnabled && !_isInBackground) {
      startPeriodicPing();
    } else {
      stopPeriodicPing();
      _isOnline = false;
      _latencyMs = -1;
      _speedKbps = 0.0;
      _lastError = _isEnabled ? 'Waiting for connection...' : 'Ping monitoring disabled';
    }

    notifyListeners();
  }

  /// Handles app lifecycle changes (background/foreground)
  void setAppBackground(bool isBackground) {
    if (_isInBackground == isBackground) return;
    _isInBackground = isBackground;

    if (_isInBackground) {
      // App went to background: stop pinging to save battery/data
      stopPeriodicPing();
    } else {
      // App resumed: restart pinging if the user has it enabled
      if (_isEnabled) {
        startPeriodicPing();
      }
    }
    notifyListeners();
  }

  Future<void> ping() async {
    // Safety check: do not ping if disabled or in background
    if (!_isEnabled || _isInBackground) return;

    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      _updateStatus(false, -1, 0.0, 'No connectivity');
      return;
    }

    final stopwatch = Stopwatch()..start();
    bool success = false;
    String errorMsg = '';
    int bytesDownloaded = 0;
    int latency = -1;

    for (final url in _testUrls) {
      try {
        final startTime = DateTime.now();
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
        final endTime = DateTime.now();

        if (response.statusCode == 200 || response.statusCode == 204) {
          success = true;
          bytesDownloaded = response.bodyBytes.length;

          // Calculate actual speed in Kbps
          final durationInMilliseconds = endTime.difference(startTime).inMilliseconds;
          if (durationInMilliseconds > 0) {
            // Convert bytes to kilobits (8 bits per byte)
            final kilobits = bytesDownloaded * 8 / 1000;
            _speedKbps = (kilobits / (durationInMilliseconds / 1000.0)).clamp(0.0, 100000.0);
          }
          break;
        }
      } catch (e) {
        errorMsg = e.toString();
      }
    }

    stopwatch.stop();
    latency = stopwatch.elapsedMilliseconds;

    if (success) {
      _updateStatus(true, latency, _speedKbps, '');
      _lastSuccessfulPing = DateTime.now();
    } else {
      _updateStatus(false, latency, 0.0, errorMsg);
    }
  }

  void _updateStatus(bool online, int latency, double speed, String error) {
    _isOnline = online;
    _latencyMs = latency;
    _speedKbps = speed;
    _lastError = error;
    notifyListeners();
  }

  // Remove the old _estimateSpeed method as it's no longer needed
  // double _estimateSpeed(int latencyMs) { ... }

  void startPeriodicPing() {
    if (_isInBackground) return; // Don't start if we are in the background

    _periodicPing?.cancel();
    _periodicPing = Timer.periodic(const Duration(seconds: 15), (_) => ping());
    ping(); // immediate ping
  }

  void stopPeriodicPing() {
    _periodicPing?.cancel();
    _periodicPing = null;
  }

  @override
  void dispose() {
    stopPeriodicPing();
    super.dispose();
  }
}