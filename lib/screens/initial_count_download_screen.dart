import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/store_manager.dart';

class InitialCountDownloadScreen extends StatefulWidget {
  const InitialCountDownloadScreen({super.key});

  @override
  State<InitialCountDownloadScreen> createState() =>
      _InitialCountDownloadScreenState();
}

class _InitialCountDownloadScreenState
    extends State<InitialCountDownloadScreen> {
  bool _running = false;
  String _message = 'Ready for initial Firestore download.';

  DateTime? _latestUpdatedAt(List<Map<String, dynamic>> rows) {
    DateTime? latest;
    for (final row in rows) {
      final raw = row['updatedAt'] ?? row['updated_at'];
      DateTime? value;
      if (raw is DateTime) {
        value = raw;
      } else if (raw != null) {
        value = DateTime.tryParse(raw.toString());
      }
      if (value != null && (latest == null || value.isAfter(latest))) {
        latest = value;
      }
    }
    return latest?.toUtc();
  }

  Future<void> _download() async {
    final manager = context.read<StoreManager>();
    final firestore = manager.firestoreService;
    final storage = manager.offlineStorage;
    final key = manager.activeFirestoreKey;

    if (firestore == null || key == null) {
      setState(() => _message = 'Firestore or the active store is unavailable.');
      return;
    }
    final pending = storage.pendingStockCountsCount;
    if (pending > 0) {
      setState(() => _message =
      'Blocked: sync the $pending pending StockCount change(s) first.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Initial count download?'),
        content: const Text(
          'This is a migration/recovery operation. It will replace the local '
              'StockCounts working copy with the current Firestore snapshot for '
              'this store. It does not read Google Sheets.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _running = true;
      _message = 'Downloading StockCounts from Firestore…';
    });

    try {
      final rows = await firestore.getStockCounts(key);
      if (!mounted) return;
      setState(() => _message = 'Downloaded ${rows.length} documents. Rebuilding local counts…');

      final result = await storage.applyInitialStockCountsDownload(rows);
      final expectedActive = rows.where((row) {
        final value = row['deleted'];
        return !(value == true || value?.toString().toLowerCase() == 'true');
      }).length;
      final local = (result['local'] ?? -1);
      final skipped = (result['skipped'] ?? 0);
      if (skipped != 0 || local != expectedActive) {
        throw StateError(
          'Verification failed: Firestore active=$expectedActive, local=$local, skipped=$skipped.',
        );
      }

      // The cursor is only committed after the complete snapshot is applied
      // and verified. A later incremental refresh can safely start here.
      final cursor = _latestUpdatedAt(rows) ?? DateTime.now().toUtc();
      await storage.setStockCountsDownloadCursor(cursor);

      if (!mounted) return;
      setState(() => _message =
      'Complete: ${result['active']} active counts loaded; '
          '${result['deleted']} Firestore tombstone(s) applied.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Initial download failed: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<StoreManager>();
    final pending = manager.offlineStorage.pendingStockCountsCount;
    final storeName = manager.activeStore?['name']?.toString() ?? 'No active store';

    return Scaffold(
      appBar: AppBar(title: const Text('Initial Count Download')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(storeName, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 12),
                      const Text(
                        'Use this once when preparing a store/device. It downloads the '
                            'complete StockCounts collection directly from Firestore and '
                            'builds the local Hive working copy.',
                      ),
                      const SizedBox(height: 12),
                      Text('Pending local StockCount changes: $pending'),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _running || pending > 0 ? null : _download,
                          icon: _running
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.cloud_download_outlined),
                          label: Text(_running ? 'Downloading…' : 'Download Initial Counts'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_message),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
