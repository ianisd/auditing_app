import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/network_ping_service.dart';
import '../services/store_manager.dart';

class MasterDataRefreshScreen extends StatefulWidget {
  const MasterDataRefreshScreen({super.key});

  @override
  State<MasterDataRefreshScreen> createState() =>
      _MasterDataRefreshScreenState();
}

class _MasterDataRefreshScreenState extends State<MasterDataRefreshScreen> {
  bool _isRefreshing = false;
  String _status = '';

  Future<bool> _checkWeakConnection() async {
    final pingService = context.read<NetworkPingService>();
    if (pingService.connectionQuality != 'Weak') return true;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: Colors.orange,
          size: 48,
        ),
        title: const Text('Poor Connection Detected'),
        content: Text(
          'Latency: ${pingService.latencyMs} ms\n'
              'Quality: ${pingService.connectionQuality}\n\n'
              'Master Data Refresh may take longer or fail on a weak connection.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _refreshMasterData() async {
    if (_isRefreshing) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.cloud_sync_outlined, size: 44),
        title: const Text('Refresh Master Data?'),
        content: const Text(
          'This downloads the latest master data for the active store and '
              'updates the local working copy. Inventory is also bulk-upserted '
              'to Firestore.\n\n'
              'This is separate from Sync Data and should only be run when you '
              'intend to refresh master/reference data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh Master Data'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (!await _checkWeakConnection() || !mounted) return;

    setState(() {
      _isRefreshing = true;
      _status = 'Refreshing master data...';
    });

    try {
      final result =
      await context.read<StoreManager>().syncService.refreshMasterData();
      if (!mounted) return;
      setState(() => _status = result.message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: result.success ? Colors.green : Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Master Data Refresh failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Master Data Refresh failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Master Data Refresh')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Icon(Icons.cloud_sync_outlined, size: 64),
                const SizedBox(height: 20),
                Text(
                  'Refresh master data',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Use this when you need the latest master/reference data '
                      'for the active store. This is not the normal pending-data '
                      'sync.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'What it does',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Text('• Downloads the latest master data'),
                        Text('• Refreshes the local Hive working copy'),
                        Text('• Bulk-upserts Inventory into Firestore'),
                      ],
                    ),
                  ),
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(_status, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _isRefreshing ? null : _refreshMasterData,
                  icon: _isRefreshing
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Icon(Icons.refresh),
                  label: Text(
                    _isRefreshing ? 'Refreshing...' : 'Refresh Master Data',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
