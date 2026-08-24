import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/store_manager.dart';
import '../services/network_ping_service.dart'; // ✅ ADDED: Import for connection check
import '../widgets/inventory_list.dart';
import 'product_detail_screen.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  List<Map<String, dynamic>> _inventory = [];
  List<Map<String, dynamic>> _filteredInventory = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadInventory();
    _searchController.addListener(_filterInventory);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInventory() async {
    setState(() => _isLoading = true);
    try {
      final storage = context.read<OfflineStorage>();
      final inventory = await storage.getAllInventory();
      setState(() {
        _inventory = inventory;
        _filteredInventory = inventory;
        _isLoading = false;
      });
      // Re-apply search filter if exists
      if (_searchController.text.isNotEmpty) _filterInventory();
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  // ✅ NEW: Helper method to warn users about weak connections
  Future<bool> _checkWeakConnection() async {
    final pingService = context.read<NetworkPingService>();

    // If connection is Strong or Average, proceed immediately
    if (pingService.connectionQuality != 'Weak') {
      return true;
    }

    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
        title: const Text('Poor Connection Detected'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Latency: ${pingService.latencyMs} ms'),
            Text('Quality: ${pingService.connectionQuality}',
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
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

  // --- SYNC ACTION ---
  Future<void> _syncInventory() async {
    // ✅ ADDED: Check connection quality before syncing
    final shouldProceed = await _checkWeakConnection();
    if (!shouldProceed) return; // User cancelled due to weak connection

    setState(() => _isSyncing = true);

    try {
      final syncService = context.read<StoreManager>().syncService;
      final result = await syncService.refreshMasterData(); // This triggers the merge logic

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: result.success ? Colors.green : Colors.red,
          ),
        );
        if (result.success) {
          await _loadInventory(); // Reload from Hive after sync
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  void _filterInventory() {
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) {
      setState(() => _filteredInventory = _inventory);
      return;
    }

    setState(() {
      _filteredInventory = _inventory.where((item) {
        final name1 = item['Inventory Product Name']?.toString().toLowerCase() ?? '';
        final name2 = item['Product Name']?.toString().toLowerCase() ?? '';
        final barcode = item['Barcode']?.toString().toLowerCase() ?? '';

        return name1.contains(query) || name2.contains(query) || barcode.contains(query);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
        actions: [
          // SYNC BUTTON
          IconButton(
            icon: _isSyncing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_sync),
            tooltip: 'Sync Master Data',
            onPressed: _isSyncing ? null : _syncInventory,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search products...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _syncInventory,
        child: _filteredInventory.isEmpty
            ? Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                'No inventory items found\n(${_inventory.length} loaded total)',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.cloud_download),
                label: const Text('Download Master Data'),
                onPressed: _syncInventory,
              )
            ],
          ),
        )
            : InventoryList(
          items: _filteredInventory,
          onTap: (item) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ProductDetailScreen(product: item),
              ),
            );
          },
        ),
      ),
    );
  }
}