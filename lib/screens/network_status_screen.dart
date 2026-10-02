import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/store_manager.dart';
import '../services/network_ping_service.dart';

class NetworkStatusScreen extends StatefulWidget {
  const NetworkStatusScreen({super.key});

  @override
  State<NetworkStatusScreen> createState() => _NetworkStatusScreenState();
}

class _NetworkStatusScreenState extends State<NetworkStatusScreen> {
  List<ConnectivityResult> _connectionStatus = [ConnectivityResult.none];
  bool _isChecking = false;

  late final NetworkPingService _pingService;

  @override
  void initState() {
    super.initState();
    _pingService = context.read<NetworkPingService>();
    _checkConnectivity();

    if (_pingService.isEnabled) {
      _pingService.startPeriodicPing();
    }
  }

  @override
  void dispose() {
    _pingService.stopPeriodicPing();
    super.dispose();
  }

  Future<void> _checkConnectivity() async {
    if (!mounted) return;
    setState(() => _isChecking = true);

    try {
      final connectivity = Connectivity();
      final result = await connectivity.checkConnectivity();
      if (!mounted) return;
      setState(() => _connectionStatus = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectionStatus = [ConnectivityResult.none]);
    } finally {
      if (!mounted) return;
      setState(() => _isChecking = false);
    }
  }

  // ✅ NEW: Helper method for color-coding the connection quality
  Color _getQualityColor(String quality) {
    switch (quality) {
      case 'Strong':
        return Colors.green;
      case 'Average':
        return Colors.orange;
      case 'Weak':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncService = context.watch<StoreManager>().syncService;
    final pingService = context.watch<NetworkPingService>();
    final isOnline =
        _connectionStatus.any((r) => r != ConnectivityResult.none) &&
        pingService.isOnline;

    return Scaffold(
      appBar: AppBar(title: const Text('Network Status')),
      body: RefreshIndicator(
        onRefresh: () async {
          await _checkConnectivity();
          await pingService.ping();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Connectivity Card
              Card(
                child: ListTile(
                  leading: Icon(
                    isOnline ? Icons.wifi : Icons.wifi_off,
                    color: isOnline ? Colors.green : Colors.red,
                    size: 40,
                  ),
                  title: Text(
                    isOnline ? 'Connected' : 'No Internet',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: isOnline ? Colors.green : Colors.red,
                    ),
                  ),
                  subtitle: Text(
                    _connectionStatus.map((r) => r.name).join(', '),
                  ),
                  trailing: _isChecking
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _checkConnectivity,
                        ),
                ),
              ),

              const SizedBox(height: 16),

              // Ping / Quality Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Connection Quality',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),

                      SwitchListTile(
                        title: const Text('Enable Network Ping'),
                        subtitle: const Text(
                          'Monitor connection quality (recommended)',
                        ),
                        value: pingService.isEnabled,
                        onChanged: (value) => pingService.setEnabled(value),
                        contentPadding: EdgeInsets.zero,
                      ),

                      if (pingService.isEnabled) ...[
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.timer),
                          title: Text('${pingService.latencyMs} ms'),
                          subtitle: const Text('Latency'),
                        ),

                        // ✅ UPDATED: Speed tile with color-coded quality label
                        ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.speed,
                            color: _getQualityColor(
                              pingService.connectionQuality,
                            ),
                          ),
                          title: Text(
                            '${pingService.speedKbps.toStringAsFixed(0)} Kbps',
                          ),
                          subtitle: Text(
                            pingService.connectionQuality,
                            style: TextStyle(
                              color: _getQualityColor(
                                pingService.connectionQuality,
                              ),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),

                        if (pingService.lastError.isNotEmpty)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.error_outline,
                              color: Colors.red,
                            ),
                            title: Text(
                              pingService.lastError,
                              style: const TextStyle(color: Colors.red),
                            ),
                            subtitle: const Text('Last Error'),
                          ),
                      ] else ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8.0),
                          child: Text(
                            'Ping monitoring is disabled. Enable it to see connection quality metrics.',
                            style: TextStyle(
                              color: Colors.grey,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Sync Service Status
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sync Service',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        dense: true,
                        title: const Text('Last Sync'),
                        subtitle: Text(
                          syncService.lastSyncTime.isEmpty
                              ? 'Never'
                              : syncService.lastSyncTime,
                        ),
                      ),
                      ListTile(
                        dense: true,
                        title: const Text('Last Error'),
                        subtitle: Text(syncService.lastError ?? 'None'),
                        textColor: syncService.lastError != null
                            ? Colors.red
                            : null,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              ElevatedButton.icon(
                onPressed: () async {
                  final result = await syncService.syncAll();
                  if (mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(result.message)));
                  }
                },
                icon: const Icon(Icons.sync),
                label: const Text('Try Sync Now'),
              ),

              const SizedBox(height: 16),

              const Text(
                'Tip: If you see high latency or frequent timeouts, try switching networks.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
