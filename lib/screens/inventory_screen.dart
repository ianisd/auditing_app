import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../widgets/inventory_list.dart';
import 'product_detail_screen.dart';
import 'add_product_screen.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  List<Map<String, dynamic>> _inventory = [];
  List<Map<String, dynamic>> _filteredInventory = [];
  bool _isLoading = true;
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

  Future<void> _addInventoryItem() async {
    final newProduct = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => const AddProductScreen(),
      ),
    );

    if (!mounted || newProduct == null) return;

    // AddProductScreen already saves the product to Hive. Reload the local
    // inventory so the newly created item appears immediately.
    await _loadInventory();

    if (!mounted) return;
    final productName =
        newProduct['Inventory Product Name']?.toString().trim() ?? '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          productName.isEmpty
              ? 'Inventory item added'
              : '$productName added to inventory',
        ),
      ),
    );
  }

  void _filterInventory() {
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) {
      setState(() => _filteredInventory = _inventory);
      return;
    }

    setState(() {
      _filteredInventory = _inventory.where((item) {
        final name1 =
            item['Inventory Product Name']?.toString().toLowerCase() ?? '';
        final name2 = item['Product Name']?.toString().toLowerCase() ?? '';
        final barcode = item['Barcode']?.toString().toLowerCase() ?? '';

        return name1.contains(query) ||
            name2.contains(query) ||
            barcode.contains(query);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addInventoryItem,
        icon: const Icon(Icons.add),
        label: const Text('Add Item'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _loadInventory,
        child: _filteredInventory.isEmpty
            ? Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: 64,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(
                'No inventory items found\n(${_inventory.length} loaded total)',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add Item'),
                onPressed: _addInventoryItem,
              ),
            ],
          ),
        )
            : InventoryList(
          items: _filteredInventory,
          onTap: (item) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    ProductDetailScreen(product: item),
              ),
            );
          },
        ),
      ),
    );
  }
}
