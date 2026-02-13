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

  Future<void> _syncNow() async {
    setState(() {
      _isSyncing = true;
      _syncMessage = 'Starting sync...';
    });

    try {
      final syncService = context.read<StoreManager>().syncService;
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
      appBar: AppBar(title: const Text('Sync Data')),
      body: Center( // ✅ CRITICAL: Wrap content in Center
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ✅ FIXED: Use Container with fixed width + center alignment
            Container(
              width: 320, // ✅ Fixed width for consistent centering
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

            const SizedBox(height: 32),

            // ✅ FIXED: Use SizedBox with fixed width + center alignment
            SizedBox(
              width: 280, // ✅ Fixed width for button
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
                    borderRadius: BorderRadius.circular(24), // ✅ Rounded corners
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