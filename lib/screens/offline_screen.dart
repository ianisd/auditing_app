import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import 'debug_log_screen.dart';
import 'debug_data_screen.dart';

class OfflineScreen extends StatefulWidget {
  const OfflineScreen({super.key});

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends State<OfflineScreen> {
  Map<String, int> _stats = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final storage = context.read<OfflineStorage>();
    final stats = await storage.getDatabaseStats();
    if (mounted) {
      setState(() {
        _stats = stats;
        _isLoading = false;
      });
    }
  }

  Future<void> _clearData(String type) async {
    final storage = context.read<OfflineStorage>();
    bool confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear $type?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear', style: TextStyle(color: Colors.red))),
        ],
      ),
    ) ?? false;

    if (confirm) {
      if (type == 'Inventory') await storage.clearInventory();
      if (type == 'Locations') await storage.clearLocations();
      if (type == 'Audits') await storage.clearAudits();
      if (type == 'Counts') await storage.clearAllStockCounts();
      if (type == 'All') await storage.clearAllData();

      _loadStats();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Data cleared')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Storage')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatCard(
              'Pending Sync', _stats['pendingSync'] ?? 0, Colors.orange, null),
          _buildStatCard(
              'Stock Counts', _stats['stockCounts'] ?? 0, Colors.blue, () =>
              _clearData('Counts')),
          const Divider(height: 32),

          const Padding(
            padding: EdgeInsets.only(bottom: 8.0),
            child: Text('Master Data',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          _buildStatCard('Inventory Items', _stats['inventoryItems'] ?? 0,
              Colors.green, () => _clearData('Inventory')),
          _buildStatCard(
              'Locations', _stats['locations'] ?? 0, Colors.purple, () =>
              _clearData('Locations')),
          _buildStatCard('Audits', _stats['audits'] ?? 0, Colors.teal, () =>
              _clearData('Audits')),

          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => _clearData('All'),
            icon: const Icon(Icons.delete_forever, color: Colors.red),
            label: const Text(
                'WIPE ALL DATA', style: TextStyle(color: Colors.red)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.red),
              padding: const EdgeInsets.all(16),
            ),
          ),

          const SizedBox(height: 20),
          const Divider(),
          const Text("Diagnostics", style: TextStyle(
              fontWeight: FontWeight.bold, color: Colors.grey)),

          // Button 1: System Logs (Errors/Sync status)
          ListTile(
            leading: const Icon(Icons.terminal, color: Colors.grey),
            title: const Text('View System Logs'),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () =>
                Navigator.push(context,
                    MaterialPageRoute(builder: (c) => const DebugLogScreen())),
          ),

          // Button 2: Data Debugger (Check Sales/Purchase Dates)
          ListTile(
            leading: const Icon(Icons.table_chart, color: Colors.blue),
            title: const Text('Check Sales & Purchases Data'),
            subtitle: const Text('Verify dates for variance report'),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () =>
                Navigator.push(context,
                    MaterialPageRoute(builder: (c) => const DebugDataScreen())),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, int count, Color color, VoidCallback? onClear) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.2),
          child: Text(count.toString(), style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ),
        title: Text(title),
        trailing: onClear != null
            ? IconButton(icon: const Icon(Icons.delete_outline, color: Colors.grey), onPressed: onClear)
            : null,
      ),
    );
  }
}