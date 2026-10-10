import 'dart:async';
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
  static const Duration _syncCooldownDuration = Duration(minutes: 2);
  Timer? _syncCooldownTimer;
  DateTime? _syncCooldownUntil;
  int _syncCooldownSeconds = 0;
  String _syncMessage = '';
  int _syncedCount = 0;
  bool _isMigratingStockCounts = false;
  String _stockMigrationMessage = '';

  @override
  void initState() {
    super.initState();
    // 🔥 No need to load anything - SyncStatus is the source of truth
  }

  @override
  void dispose() {
    _syncCooldownTimer?.cancel();
    // 🔥 No need to remove listeners
    super.dispose();
  }

  bool get _isSyncCoolingDown => _syncCooldownSeconds > 0;

  void _startSyncCooldown() {
    _syncCooldownTimer?.cancel();
    _syncCooldownUntil = DateTime.now().add(_syncCooldownDuration);

    void updateRemaining() {
      final until = _syncCooldownUntil;
      if (until == null) return;

      final remaining = until.difference(DateTime.now()).inSeconds;
      if (remaining <= 0) {
        _syncCooldownTimer?.cancel();
        _syncCooldownTimer = null;
        _syncCooldownUntil = null;
        if (mounted) {
          setState(() => _syncCooldownSeconds = 0);
        }
        return;
      }

      if (mounted) {
        setState(() => _syncCooldownSeconds = remaining);
      }
    }

    updateRemaining();
    _syncCooldownTimer = Timer.periodic(
      const Duration(seconds: 1),
          (_) => updateRemaining(),
    );
  }

  String get _syncButtonLabel {
    if (_isSyncing) return 'Syncing...';
    if (_isSyncCoolingDown) {
      final minutes = _syncCooldownSeconds ~/ 60;
      final seconds = _syncCooldownSeconds % 60;
      return 'Retry in $minutes:${seconds.toString().padLeft(2, '0')}';
    }
    return 'Sync Now';
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
    if (!mounted || _isSyncing || _isSyncCoolingDown) return;

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
          _syncMessage = result.detailedMessage;
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
    } finally {
      if (mounted) {
        _startSyncCooldown();
      }
    }
  }

  Future<void> _migrateStockCountsOnce() async {
    if (_isMigratingStockCounts || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Migrate StockCounts to Firestore?'),
        content: const Text(
          'This is a one-time administrative migration for the active store.\n\n'
              'Existing Google Sheet StockCounts will be de-duplicated by stable ID, '
              'upserted to Firestore, and verified before the migration is marked complete.\n\n'
              'It does not delete Firestore-only counts and does not change the Google Sheet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Run Migration'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isMigratingStockCounts = true;
      _stockMigrationMessage = 'Preparing StockCounts migration...';
    });

    try {
      final syncService = context.read<StoreManager>().syncService;
      final result = await syncService.migrateStockCountsToFirestore(
        onProgress: (processed, total) {
          if (!mounted) return;
          setState(() {
            _stockMigrationMessage = total == null
                ? 'Reading StockCounts: $processed rows...'
                : 'Processing StockCounts: $processed / $total';
          });
        },
      );

      if (!mounted) return;

      final alreadyComplete = result['alreadyComplete'] == true;
      final receipt = alreadyComplete
          ? result['message'].toString()
          : 'Source: ${result['source']}\n'
          'Valid unique: ${result['validUnique']}\n'
          'Invalid: ${result['invalid']}\n'
          'Duplicate excess: ${result['duplicateExcess']}\n'
          'Upserted: ${result['upserted']}\n'
          'Verified: ${result['verified']}';

      setState(() {
        _stockMigrationMessage = alreadyComplete
            ? 'StockCounts migration was already complete.'
            : 'StockCounts migration verified successfully.';
      });

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            alreadyComplete
                ? 'Migration Already Complete'
                : 'Migration Complete',
          ),
          content: SelectableText(receipt),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stockMigrationMessage = 'Migration failed: $e';
      });
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Migration Failed'),
          content: SelectableText(
            '$e\n\nThe completion marker was not written. '
                'The migration can be safely retried.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isMigratingStockCounts = false;
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
                  // Temporary administrative action for the one-time
                  // Google Sheets -> Firestore StockCounts migration.
                  Card(
                    margin: const EdgeInsets.only(bottom: 24),
                    child: SizedBox(
                      width: 320,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'StockCounts Firestore Migration',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'One-time admin action for the active store. '
                                  'Safe to retry until verification succeeds.',
                            ),
                            if (_stockMigrationMessage.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(_stockMigrationMessage),
                            ],
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _isMigratingStockCounts
                                  ? null
                                  : _migrateStockCountsOnce,
                              icon: _isMigratingStockCounts
                                  ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                                  : const Icon(Icons.cloud_upload_outlined),
                              label: Text(
                                _isMigratingStockCounts
                                    ? 'Migrating...'
                                    : 'Migrate StockCounts Once',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

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
                      onPressed: (_isSyncing || _isSyncCoolingDown) ? null : _syncNow,
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
                        _syncButtonLabel,
                        style: const TextStyle(fontSize: 18),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Colors.blue,
                        disabledBackgroundColor: Colors.grey.shade400,
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
