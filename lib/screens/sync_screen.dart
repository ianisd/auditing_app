import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/sync_service.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  bool _isSyncing = false;
  String _syncMessage = '';
  int _syncedCount = 0;

  Future<void> _syncNow() async {
    setState(() {
      _isSyncing = true;
      _syncMessage = 'Starting sync...';
    });

    try {
      final syncService = context.read<SyncService>();
      final result = await syncService.syncAll();

      setState(() {
        _isSyncing = false;
        _syncMessage = result.message;
        _syncedCount = result.syncedCount;
      });
    } catch (e) {
      setState(() {
        _isSyncing = false;
        _syncMessage = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Data'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Sync Status Card
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      _isSyncing ? Icons.sync : Icons.cloud_upload,
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
                          ? 'Tap sync to upload pending counts'
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
                          'Successfully synced $_syncedCount counts',
                          style: const TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Sync Button
            ElevatedButton.icon(
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}