import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import 'package:intl/intl.dart';
import 'count_screen.dart';

class ProductDetailScreen extends StatefulWidget {
  final Map<String, dynamic> product;

  const ProductDetailScreen({super.key, required this.product});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<Map<String, dynamic>> _relatedCounts = [];
  List<Map<String, dynamic>> _associatedBarcodes = [];
  bool _isLoading = true;
  late String _productName;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _productName = (widget.product['Inventory Product Name'] ?? widget.product['Product Name'] ?? 'Unknown').toString();
    _loadProductCentricData();
  }

  Future<void> _loadProductCentricData() async {
    final storage = context.read<OfflineStorage>();

    // 1. Get Inventory
    final allInventory = await storage.getAllInventory();
    final siblingProducts = allInventory.where((item) {
      final name = item['Inventory Product Name']?.toString() ?? '';
      return name.toLowerCase() == _productName.toLowerCase();
    }).toList();

    // 2. Get Counts
    final allCounts = await storage.getStockCounts();
    final matches = allCounts.where((c) {
      final countName = c['productName']?.toString() ?? '';
      return countName.toLowerCase() == _productName.toLowerCase();
    }).toList();

    matches.sort((a, b) => (b['date'] ?? '').compareTo(a['date'] ?? ''));

    if (mounted) {
      setState(() {
        _associatedBarcodes = siblingProducts;
        _relatedCounts = matches;
        _isLoading = false;
      });
    }
  }

  Future<void> _navigateToAddCount() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CountScreen(initialProduct: widget.product),
      ),
    );
    _loadProductCentricData();
  }

  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  // --- HELPER: Detect if item is Food/Solid ---
  bool _isFood(String? uom) {
    if (uom == null) return false;
    final lower = uom.toLowerCase();
    return lower == 'kg' || lower == 'g' || lower == 'lb' || lower == 'oz' || lower == 'each';
  }

  // --- HELPER: Smart Calculation ---
  double _calculateSmartTotal(Map<String, dynamic> countData) {
    double storedTotal = _safeDouble(countData['total_bottles']);
    if (storedTotal > 0) return storedTotal;

    // Fallback for bad data
    String packSize = countData['pack_size']?.toString() ?? '';
    double count = _safeDouble(countData['count']);

    if (count <= 0) return 0.0;

    double multiplier = 0.0;
    switch (packSize) {
      case "Case 1": multiplier = 1.0; break;
      case "Case 2": multiplier = 2.0; break;
      case "Case 4": multiplier = 4.0; break;
      case "Case 6": multiplier = 6.0; break;
      case "Case 12": multiplier = 12.0; break;
      case "Case 24": multiplier = 24.0; break;
      case "Case 36": multiplier = 36.0; break;
      case "Case 48": multiplier = 48.0; break;
      case "Pack 10": multiplier = 10.0; break;
      case "Pack 20": multiplier = 20.0; break;
      case "Keg 1": multiplier = 1000.0; break;
      case "5 Ltr Cartons": multiplier = 5000.0; break;
      case "10 Ltr Cartons": multiplier = 10000.0; break;
      case "Loose": multiplier = 1.0; break;
      case "Loose (kg)": multiplier = 1.0; break;
      case "Loose (g)": multiplier = 0.001; break;
      case "Pack": multiplier = 1.0; break;
      case "Box": multiplier = 1.0; break;
      case "Each": multiplier = 1.0; break;
      case "Portion": multiplier = 1.0; break;
      case "Open Bottle": return 0.0;
      default: multiplier = 1.0;
    }

    return count * multiplier;
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '';
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('dd MMM yyyy').format(date);
    } catch (e) {
      return dateStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    final category = widget.product['Category']?.toString() ?? '';
    final uom = widget.product['UoM']?.toString() ?? '';
    final isFoodItem = _isFood(uom);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Product Dashboard'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [Tab(text: 'Overview'), Tab(text: 'Live Counts'), Tab(text: 'Purchases')],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToAddCount,
        label: const Text('Add Count'),
        icon: const Icon(Icons.add_task),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // TAB 1: OVERVIEW
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeaderCard(_productName, category),
                const SizedBox(height: 16),
                _buildStatGrid(isFoodItem),
                const SizedBox(height: 24),
                const Text('Associated Barcodes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                _buildBarcodeList(),
                const SizedBox(height: 80),
              ],
            ),
          ),

          // TAB 2: LIVE COUNTS
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _relatedCounts.isEmpty
              ? _buildEmptyState('No active counts for this item.')
              : ListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: _relatedCounts.length,
            itemBuilder: (context, index) {
              final count = _relatedCounts[index];

              final totalUnits = _calculateSmartTotal(count);
              final packSize = count['pack_size'] ?? '';
              final location = count['location'] ?? 'Unknown';
              final dateDisplay = _formatDate(count['date']);
              final unitLabel = isFoodItem ? 'Units / Kg' : 'Bottles';

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: Icon(Icons.check, color: Colors.white, size: 16),
                  ),
                  title: Text(location.toString()),
                  subtitle: Text('$dateDisplay • $packSize'),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        totalUnits.toStringAsFixed(2),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(unitLabel, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                  ),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CountScreen(existingCount: count),
                      ),
                    );
                    _loadProductCentricData();
                  },
                ),
              );
            },
          ),

          // TAB 3: PURCHASES
          const Center(child: Text('Purchases module coming soon.')),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(String name, String category) {
    return Card(
      elevation: 4,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.blue.shade50, shape: BoxShape.circle),
              child: const Icon(Icons.local_bar, color: Colors.blue, size: 32),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Chip(label: Text(category), visualDensity: VisualDensity.compact),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatGrid(bool isFood) {
    double totalUnits = 0;
    for (var c in _relatedCounts) {
      totalUnits += _calculateSmartTotal(c);
    }
    final cost = _safeDouble(widget.product['Cost Price']);
    final totalValue = totalUnits * cost;

    final stockLabel = isFood ? 'Total Units/Kg' : 'Total Stock';

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.6,
      children: [
        _buildStatCard(stockLabel, totalUnits.toStringAsFixed(2), Icons.inventory_2, Colors.blue),
        _buildStatCard('Total Value', NumberFormat.simpleCurrency().format(totalValue), Icons.monetization_on, Colors.green),
        // UPDATED LABEL
        _buildStatCard('Avg Unit Cost', NumberFormat.simpleCurrency().format(cost), Icons.price_check, Colors.purple),
        _buildStatCard('Locations', _getUniqueLocations(), Icons.place, Colors.orange),
      ],
    );
  }

  String _getUniqueLocations() {
    final locs = _relatedCounts.map((e) => e['location'].toString()).toSet();
    return locs.length.toString();
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          Text(title, style: TextStyle(fontSize: 12, color: color.withOpacity(0.8))),
        ],
      ),
    );
  }

  Widget _buildBarcodeList() {
    if (_associatedBarcodes.isEmpty) return const Text('No barcodes linked.');

    return Column(
      children: _associatedBarcodes.map((item) {
        final barcode = item['Barcode']?.toString() ?? 'No Barcode';
        final vol = item['Single Unit Volume']?.toString() ?? '0';
        final uom = item['UoM']?.toString() ?? '';

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.qr_code_2, color: Colors.grey),
            title: Text(barcode, style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'Monospace')),
            trailing: Text('$vol $uom', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildEmptyState(String msg) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.info_outline, size: 48, color: Colors.grey),
          const SizedBox(height: 16),
          Text(msg, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _navigateToAddCount,
            icon: const Icon(Icons.add),
            label: const Text('Add First Count'),
          ),
        ],
      ),
    );
  }
}