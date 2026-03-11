import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/logger_service.dart';
import '../models/plu_mapping.dart';

class PluMappingScreen extends StatefulWidget {
  const PluMappingScreen({super.key});

  @override
  State<PluMappingScreen> createState() => _PluMappingScreenState();
}

class _PluMappingScreenState extends State<PluMappingScreen> {
  List<PluMapping> _mappings = [];
  bool _isLoading = true;
  String? _selectedSupplier;
  Map<String, String> _supplierNames = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final storage = context.read<OfflineStorage>();
      final mappings = await storage.getAllPluMappings();
      print('🔍 PLU Mapping Screen - Found ${mappings.length} mappings:');
      for (var m in mappings) {
        print('  - ${m.csvPlu} (${m.csvDescription}) → ${m.correctPlu} (${m.productName})');
      }
    });
    _loadData();
  }

  Future<void> _loadData() async {
    final storage = context.read<OfflineStorage>();

    print('🔍 PLU MAPPING SCREEN: Loading data...');

    // Load suppliers for display
    final suppliers = await storage.getMasterSuppliers();
    final supplierMap = {for (var s in suppliers) s['supplierID']?.toString() ?? '' : s['Supplier']?.toString() ?? 'Unknown'};
    print('📊 Loaded ${suppliers.length} suppliers');

    // Load mappings
    final mappings = await storage.getAllPluMappings();
    print('📊 Loaded ${mappings.length} PLU mappings');

    if (mappings.isEmpty) {
      print('⚠️ No mappings found in _pluMappings box');
    } else {
      print('✅ First mapping: ${mappings.first.csvPlu} -> ${mappings.first.correctPlu}');
    }

    setState(() {
      _mappings = mappings;
      _supplierNames = supplierMap;
      _isLoading = false;
    });
  }

  Future<void> _deleteMapping(PluMapping mapping) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Mapping'),
        content: Text('Delete mapping for PLU ${mapping.csvPlu}?\n\n${mapping.csvDescription} → ${mapping.productName}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final storage = context.read<OfflineStorage>();
      await storage.deletePluMapping(mapping.supplierId, mapping.csvPlu);
      await _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mapping deleted')),
        );
      }
    }
  }

  List<PluMapping> get _filteredMappings {
    if (_selectedSupplier == null) return _mappings;
    return _mappings.where((m) => m.supplierId == _selectedSupplier).toList();
  }

  @override
  Widget build(BuildContext context) {
    // Get unique suppliers for filter
    final suppliers = _mappings.map((m) => m.supplierId).toSet().toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('PLU Mappings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          if (suppliers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: _selectedSupplier == null,
                      onSelected: (_) => setState(() => _selectedSupplier = null),
                    ),
                    const SizedBox(width: 8),
                    ...suppliers.map((sid) {
                      final supplierName = _supplierNames[sid] ?? sid;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(supplierName.length > 15
                              ? '${supplierName.substring(0, 12)}...'
                              : supplierName),
                          selected: _selectedSupplier == sid,
                          onSelected: (_) => setState(() => _selectedSupplier = sid),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _filteredMappings.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.link_off, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No PLU mappings yet',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Mappings will appear when you match\nproducts during GRV import',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ],
              ),
            )
                : ListView.builder(
              itemCount: _filteredMappings.length,
              padding: const EdgeInsets.all(8),
              itemBuilder: (context, index) {
                final mapping = _filteredMappings[index];
                final supplierName = _supplierNames[mapping.supplierId] ?? mapping.supplierId;

                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blue.shade100,
                      child: Text(
                        mapping.csvPlu,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    title: Text(
                      mapping.csvDescription,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '→ ${mapping.productName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'PLU: ${mapping.correctPlu} | Used: ${mapping.confidence} time${mapping.confidence == 1 ? '' : 's'}',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        Text(
                          'Supplier: $supplierName',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _deleteMapping(mapping),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}