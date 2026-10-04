import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/sync_model.dart';
import '../services/store_manager.dart';
import '../services/network_ping_service.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  bool _isSyncing = false;
  String _syncMessage = '';
  int _syncedCount = 0;

  @override
  void initState() {
    super.initState();
    // 🔥 No need to load anything - SyncStatus is the source of truth
  }

  @override
  void dispose() {
    // 🔥 No need to remove listeners
    super.dispose();
  }

  Future<bool> _checkWeakConnection() async {
    final pingService = context.read<NetworkPingService>();
    if (pingService.connectionQuality != 'Weak') {
      return true;
    }

    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: Colors.orange,
          size: 48,
        ),
        title: const Text('Poor Connection Detected'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Latency: ${pingService.latencyMs} ms'),
            Text(
              'Quality: ${pingService.connectionQuality}',
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
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

    final shouldProceed = await _checkWeakConnection();
    if (!shouldProceed) return;

    setState(() {
      _isSyncing = true;
      _syncMessage = 'Starting sync...';
    });

    try {
      final syncService = context.read<StoreManager>().syncService;

      final result = await syncService.syncAllWithChunking(
        onStatus: (message) {
          if (mounted) {
            setState(() {
              _syncMessage = message;
            });
          }
        },
      );

      if (mounted) {
        // 🔥 After sync, the SyncStatus will auto-update via StoreManager listener
        // No need to manually reload anything

        setState(() {
          _isSyncing = false;
          _syncMessage = result.success
              ? result.detailedMessage
              : 'Error: ${result.message}';
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
    // 🔥 Watch SyncStatus for ALL pending data - one source of truth!
    return Consumer<SyncStatus>(
      builder: (context, syncStatus, _) {
        final pendingCounts = syncStatus.pendingBreakdown;
        final hasPending = syncStatus.pendingCount > 0;
        final pendingInvoices = pendingCounts['invoices'] ?? 0;
        final pendingPurchases = pendingCounts['purchases'] ?? 0;
        final deletedInvoices = pendingCounts['deletedInvoices'] ?? 0;
        final deletedPurchases = pendingCounts['deletedPurchases'] ?? 0;
        final pendingPluMappings = pendingCounts['pluMappings'] ?? 0;
        final pendingStockCounts = pendingCounts['stockCounts'] ?? 0;

        return Scaffold(
          appBar: AppBar(title: const Text('Sync Data')),
          body: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Stats Card - Shows ALL pending types
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
                          if (pendingInvoices > 0)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.receipt,
                                      size: 16,
                                      color: Colors.blue.shade700,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Pending invoices:',
                                      style: TextStyle(
                                        color: Colors.blue.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
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
                          if (pendingInvoices > 0 && pendingPurchases > 0)
                            const SizedBox(height: 8),
                          if (pendingPurchases > 0)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.shopping_cart,
                                      size: 16,
                                      color: Colors.orange.shade700,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Pending purchases:',
                                      style: TextStyle(
                                        color: Colors.orange.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
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
                          if (deletedInvoices > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.delete_outline,
                                        size: 16,
                                        color: Colors.red.shade700,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Invoices to delete:',
                                        style: TextStyle(
                                          color: Colors.red.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    '$deletedInvoices',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (deletedPurchases > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.delete_sweep_outlined,
                                        size: 16,
                                        color: Colors.red.shade700,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Purchases to delete:',
                                        style: TextStyle(
                                          color: Colors.red.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    '$deletedPurchases',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (pendingPluMappings > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.link,
                                        size: 16,
                                        color: Colors.purple.shade700,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Pending PLU mappings:',
                                        style: TextStyle(
                                          color: Colors.purple.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.purple.shade100,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '$pendingPluMappings',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.purple.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (pendingStockCounts > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.inventory,
                                        size: 16,
                                        color: Colors.green.shade700,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Pending stock counts:',
                                        style: TextStyle(
                                          color: Colors.green.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade100,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '$pendingStockCounts',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
                          _isSyncing
                              ? 'Syncing...'
                              : hasPending
                              ? 'Changes Ready to Sync'
                              : 'All Up to Date',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _syncMessage.isEmpty
                              ? hasPending
                                    ? 'Tap sync to process pending changes'
                                    : 'No pending changes'
                              : _syncMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[600]),
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
      },
    );
  }
}
