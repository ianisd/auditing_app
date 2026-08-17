import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/store_manager.dart';
import '../services/network_ping_service.dart'; // ✅ ADDED: Import for connection check

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  bool _isSyncing = false;
  String _syncMessage = '';
  int _syncedCount = 0;
  Map<String, int> _cachedStats = {};

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    if (!mounted) return;
    try {
      final syncService = context.read<StoreManager>().syncService;
      final stats = await syncService.getDatabaseStats();
      if (mounted) {
        setState(() {
          _cachedStats = stats;
        });
      }
    } catch (e) {
      print('Error loading stats: $e');
    }
  }

  // ✅ NEW: Helper method to warn users about weak connections
  Future<bool> _checkWeakConnection() async {
    final pingService = context.read<NetworkPingService>();

    // If connection is Strong or Average, proceed immediately
    if (pingService.connectionQuality != 'Weak') {
      return true;
    }

    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
        title: const Text('Poor Connection Detected'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Latency: ${pingService.latencyMs} ms'),
            Text('Quality: ${pingService.connectionQuality}',
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text(
              'Sync operations may fail or take several minutes. Consider:\n'
                  '• Switching to mobile data\n'
                  '• Moving closer to your Wi-Fi router\n'
                  '• Waiting for a better connection',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Continue Anyway'),
          ),
        ],
      ),
    );

    return proceed ?? false;
  }

  Future<void> _syncNow() async {
    if (!mounted) return;

    // ✅ ADDED: Check connection quality before syncing
    final shouldProceed = await _checkWeakConnection();
    if (!shouldProceed) return; // User cancelled due to weak connection

    setState(() {
      _isSyncing = true;
      _syncMessage = 'Starting sync...';
    });

    try {
      final syncService = context.read<StoreManager>().syncService;
      final result = await syncService.syncAll();

      if (mounted) {
        // Refresh stats after sync
        await _loadStats();

        setState(() {
          _isSyncing = false;
          _syncMessage = result.message;
          _syncedCount = result.syncedCount;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncMessage = 'Error: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Get pending counts from cached stats
    final pendingInvoices = _cachedStats['invoices'] ?? 0;
    final pendingPurchases = _cachedStats['purchases'] ?? 0;
    final hasPending = pendingInvoices > 0 || pendingPurchases > 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync Data')),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Stats Card
              if (hasPending)
                Container(
                  width: 320,
                  margin: const EdgeInsets.only(bottom: 24),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.receipt, size: 16, color: Colors.blue.shade700),
                              const SizedBox(width: 8),
                              Text('Pending invoices:',
                                  style: TextStyle(color: Colors.blue.shade700)),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$pendingInvoices',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.shopping_cart, size: 16, color: Colors.orange.shade700),
                              const SizedBox(width: 8),
                              Text('Pending purchases:',
                                  style: TextStyle(color: Colors.orange.shade700)),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$pendingPurchases',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.orange.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

              // Main Sync Card
              Container(
                width: 320,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Icon(
                      _isSyncing ? Icons.sync : Icons.cloud_done,
                      size: 64,
                      color: _isSyncing ? Colors.blue : Colors.green,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _isSyncing ? 'Syncing...' : 'Ready to Sync',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _syncMessage.isEmpty
                          ? 'Tap sync to upload pending data'
                          : _syncMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey[600],
                      ),
                    ),
                    if (_syncedCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Successfully synced $_syncedCount items',
                          style: const TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // Sync Button
              SizedBox(
                width: 280,
                child: ElevatedButton.icon(
                  onPressed: _isSyncing ? null : _syncNow,
                  icon: _isSyncing
                      ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                      : const Icon(Icons.sync),
                  label: Text(
                    _isSyncing ? 'Syncing...' : 'Sync Now',
                    style: const TextStyle(fontSize: 18),
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.blue,
                    disabledBackgroundColor: Colors.blue.shade200,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}