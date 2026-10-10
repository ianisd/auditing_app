import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/network_ping_service.dart';
import '../services/store_manager.dart';

class StockReportingSyncScreen extends StatefulWidget {
  const StockReportingSyncScreen({super.key});

  @override
  State<StockReportingSyncScreen> createState() =>
      _StockReportingSyncScreenState();
}

class _StockReportingSyncScreenState extends State<StockReportingSyncScreen> {
  bool _isSyncing = false;
  bool _isCheckingStatus = true;
  bool _isInitializing = false;
  bool? _isInitialized;
  String? _cursor;
  String _status = '';
  Map<String, dynamic>? _lastResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadReportingStatus());
  }

  Future<void> _loadReportingStatus() async {
    if (!mounted) return;
    setState(() => _isCheckingStatus = true);
    try {
      final result = await context.read<StoreManager>().getStockCountsReportingStatus();
      if (!mounted) return;
      final success = result['success'] == true || result['status'] == 'success';
      setState(() {
        _isCheckingStatus = false;
        if (success) {
          _isInitialized = result['initialized'] == true;
          _cursor = result['cursor']?.toString();
          _status = '';
        } else {
          _isInitialized = null;
          _status = (result['message'] ?? 'Could not check reporting status.').toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCheckingStatus = false;
        _isInitialized = null;
        _status = 'Could not check reporting status: $e';
      });
    }
  }

  Future<void> _initializeReporting() async {
    if (_isInitializing || _isSyncing) return;
    final manager = context.read<StoreManager>();
    final storeName = manager.activeStore?['name']?.toString() ?? 'this store';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.flag_outlined, size: 44),
        title: const Text('Initialize Reporting?'),
        content: Text(
          'This establishes the current StockCounts sheet for $storeName as the historical reporting baseline.\n\n'
              'Existing historical Firestore records will not be re-imported. Future creates, edits and deletions will be mirrored from the initialized cursor onward.\n\n'
              'Only continue if the existing StockCounts sheet is the accepted baseline for this legacy store.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Initialize Reporting')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!await _checkWeakConnection() || !mounted) return;
    setState(() { _isInitializing = true; _status = 'Initializing reporting baseline...'; });
    try {
      final result = await manager.initializeStockCountsReporting();
      if (!mounted) return;
      final success = result['success'] == true || result['status'] == 'success';
      setState(() {
        _lastResult = result;
        if (success) {
          _isInitialized = true;
          _cursor = result['cursor']?.toString();
          _status = '';
        } else {
          _status = (result['message'] ?? 'Reporting initialization failed.').toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Reporting initialization failed: $e');
    } finally {
      if (mounted) setState(() => _isInitializing = false);
    }
  }

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
              'Reporting sync may take longer or fail on a weak connection.',
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

  Future<void> _syncReporting() async {
    if (_isSyncing) return;

    final manager = context.read<StoreManager>();
    final storeName = manager.activeStore?['name']?.toString() ?? 'active store';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.publish_outlined, size: 44),
        title: const Text('Sync Stock Count Reporting?'),
        content: Text(
          'This sends recent StockCounts changes from Firestore to the Google '
              'Sheets reporting mirror for $storeName.\n\n'
              'Only records changed since the last successful reporting cursor are '
              'processed. This is separate from normal pending-data sync.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.publish_outlined),
            label: const Text('Sync Reporting'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (!await _checkWeakConnection() || !mounted) return;

    setState(() {
      _isSyncing = true;
      _status = 'Syncing StockCounts reporting...';
      _lastResult = null;
    });

    try {
      final result = await manager.syncStockCountsReporting();
      if (!mounted) return;

      final success = result['success'] == true || result['status'] == 'success';
      final message = success
          ? _successMessage(result)
          : (result['message'] ?? 'Reporting sync failed.').toString();

      setState(() {
        _lastResult = result;
        _status = message;
        if (success && result['cursor'] != null) _cursor = result['cursor'].toString();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final message = 'Reporting sync failed: $e';
      setState(() => _status = message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  String _successMessage(Map<String, dynamic> result) {
    final changed = result['uniqueChangedIds'] ?? result['changed'] ?? 0;
    final inserted = result['inserted'] ?? 0;
    final updated = result['updated'] ?? 0;
    final deleted = result['deleted'] ?? 0;
    final alreadyAbsent = result['alreadyAbsent'] ?? 0;

    if (changed == 0) return 'Reporting is already up to date.';
    return 'Reporting synced: $changed changed, $inserted inserted, '
        '$updated updated, $deleted deleted, $alreadyAbsent already absent.';
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<StoreManager>();
    final storeName = manager.activeStore?['name']?.toString() ?? 'No Store';
    final result = _lastResult;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync Reporting')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Icon(Icons.publish_outlined, size: 64),
                const SizedBox(height: 20),
                Text(
                  'Stock count reporting',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  storeName,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Mirror recent Firestore StockCounts changes into the store\'s '
                      'Google Sheets reporting table. Creates, edits and deletions '
                      'are applied by stable stock ID.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'What it does',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Text('• Reads only Firestore changes since the reporting cursor'),
                        Text('• Inserts new StockCounts into Google Sheets'),
                        Text('• Updates previously mirrored StockCounts'),
                        Text('• Removes deleted StockCounts from the report'),
                        Text('• Verifies changes before advancing the cursor'),
                        SizedBox(height: 8),
                        Text(
                          'This does not change pending operational sync state.',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(_status, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: _isCheckingStatus
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(
                      _isInitialized == true ? Icons.check_circle_outline : Icons.info_outline,
                      color: _isInitialized == true ? Colors.green : null,
                    ),
                    title: Text(_isCheckingStatus
                        ? 'Checking reporting status...'
                        : _isInitialized == true
                        ? 'Reporting ready'
                        : _isInitialized == false
                        ? 'Reporting not initialized'
                        : 'Reporting status unavailable'),
                    subtitle: _cursor != null && _cursor!.isNotEmpty ? Text('Cursor: $_cursor') : null,
                    trailing: !_isCheckingStatus && _isInitialized == null
                        ? IconButton(onPressed: _loadReportingStatus, icon: const Icon(Icons.refresh), tooltip: 'Retry status check')
                        : null,
                  ),
                ),
                const SizedBox(height: 24),
                if (_isInitialized == false)
                  FilledButton.icon(
                    onPressed: _isInitializing || manager.activeStore == null ? null : _initializeReporting,
                    icon: _isInitializing
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.flag_outlined),
                    label: Text(_isInitializing ? 'Initializing Reporting...' : 'Initialize Reporting'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _isSyncing || _isCheckingStatus || _isInitialized != true || manager.activeStore == null
                        ? null
                        : _syncReporting,
                    icon: _isSyncing
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.publish_outlined),
                    label: Text(_isSyncing ? 'Syncing Reporting...' : 'Sync Reporting'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
