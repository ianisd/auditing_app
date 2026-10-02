import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/store_manager.dart';
import '../services/offline_storage.dart';

class SyncStatusWidget extends StatefulWidget {
  const SyncStatusWidget({super.key});

  @override
  State<SyncStatusWidget> createState() => _SyncStatusWidgetState();
}

class _SyncStatusWidgetState extends State<SyncStatusWidget> {
  Map<String, int> _pendingCounts = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPendingCounts();

    // 🔥 Listen to OfflineStorage changes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final offlineStorage = context.read<OfflineStorage>();
      offlineStorage.addListener(_onStorageChanged);
    });
  }

  void _onStorageChanged() {
    if (mounted) {
      _loadPendingCounts();
    }
  }

  Future<void> _loadPendingCounts() async {
    if (!mounted) return;
    try {
      final counts = await context
          .read<OfflineStorage>()
          .getDetailedPendingCounts();
      if (mounted) {
        setState(() {
          _pendingCounts = counts;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    try {
      context.read<OfflineStorage>().removeListener(_onStorageChanged);
    } catch (e) {
      // Ignore if already disposed
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<StoreManager>(
      builder: (context, storeManager, _) {
        final syncService = storeManager.syncService;
        final lastSync = syncService.lastSyncTime;
        final isSyncing = syncService.isSyncing;
        final hasError = syncService.lastError != null;
        final errorMessage = syncService.lastError;

        final pending = _pendingCounts;
        final totalPending = pending['total'] ?? 0;
        final pendingInvoices = pending['invoices'] ?? 0;
        final pendingPurchases = pending['purchases'] ?? 0;
        final pendingPluMappings = pending['pluMappings'] ?? 0;
        final pendingStockCounts = pending['stockCounts'] ?? 0;

        // Build pending details string
        String pendingDetails = '';
        if (pendingInvoices > 0) pendingDetails += '$pendingInvoices Inv';
        if (pendingPurchases > 0)
          pendingDetails +=
              '${pendingDetails.isNotEmpty ? ", " : ""}$pendingPurchases Pur';
        if (pendingPluMappings > 0)
          pendingDetails +=
              '${pendingDetails.isNotEmpty ? ", " : ""}$pendingPluMappings PLU';
        if (pendingStockCounts > 0)
          pendingDetails +=
              '${pendingDetails.isNotEmpty ? ", " : ""}$pendingStockCounts Counts';

        Color bgColor;
        IconData icon;
        Color iconColor;
        String statusText;
        String subText;

        if (isSyncing) {
          bgColor = Colors.blue.shade50;
          icon = Icons.sync;
          iconColor = Colors.blue.shade700;
          statusText = 'Syncing...';
          subText = 'Please wait';
        } else if (hasError) {
          bgColor = Colors.red.shade50;
          icon = Icons.error_outline;
          iconColor = Colors.red.shade700;
          statusText = 'Sync Failed';
          subText = errorMessage ?? 'Tap to retry';
        } else if (totalPending > 0) {
          // 🔥 ORANGE color for pending items
          bgColor = Colors.orange.shade50;
          icon = Icons.cloud_upload_outlined;
          iconColor = Colors.orange.shade700;
          statusText = '$totalPending items pending sync';
          subText = pendingDetails.isNotEmpty
              ? '$pendingDetails pending'
              : 'Tap sync to upload';
        } else {
          bgColor = Colors.green.shade50;
          icon = Icons.check_circle_outline;
          iconColor = Colors.green.shade700;
          statusText = 'All up to date';
          subText = lastSync.isNotEmpty
              ? 'Last synced: $lastSync'
              : 'Ready to sync';
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(
              bottom: BorderSide(color: iconColor.withOpacity(0.2), width: 1),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: isSyncing
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: iconColor,
                        ),
                      )
                    : Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: iconColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subText,
                      style: TextStyle(
                        fontSize: 12,
                        color: iconColor.withOpacity(0.7),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Text(
                  storeManager.activeStore?['name'] ?? 'No Store',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade700,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
