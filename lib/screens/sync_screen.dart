import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/store_manager.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  bool _isSyncing = false;
  String _syncMessage = '';
  int _syncedCount = 0;
  Map<String, int> _cachedStats = {}; // ✅ Cache stats to avoid rebuilding

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  // ✅ Add method to load stats
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

  Future<void> _syncNow() async {
    if (!mounted) return;

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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ✅ Stats Card
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
    );
  }
}