import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/sync_service.dart';

class SyncStatusWidget extends StatelessWidget {
  const SyncStatusWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SyncService>(
      builder: (context, syncService, child) {
        final lastSync = syncService.lastSyncTime;
        final isSyncing = syncService.isSyncing;
        final hasError = syncService.lastError != null;

        if (lastSync.isEmpty && !isSyncing && !hasError) {
          return const SizedBox.shrink();
        }

        Color bgColor = Colors.blue.shade50;
        IconData icon = Icons.cloud_done;
        Color iconColor = Colors.blue;
        String text = 'Last synced: $lastSync';

        if (isSyncing) {
          bgColor = Colors.blue.shade50;
          icon = Icons.sync;
          text = 'Syncing...';
        } else if (hasError) {
          bgColor = Colors.red.shade50;
          icon = Icons.error_outline;
          iconColor = Colors.red;
          text = 'Sync Failed';
        } else {
          bgColor = Colors.green.shade50;
          iconColor = Colors.green;
        }

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: iconColor.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              isSyncing
                  ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: iconColor),
              )
                  : Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text,
                      style: TextStyle(
                        color: iconColor.withOpacity(0.8),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (hasError)
                      Text(
                        syncService.lastError!,
                        style: TextStyle(color: iconColor, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}