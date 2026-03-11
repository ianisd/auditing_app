import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';

class SupplierMappingScreen extends StatefulWidget {
  const SupplierMappingScreen({super.key});

  @override
  State<SupplierMappingScreen> createState() => _SupplierMappingScreenState();
}

class _SupplierMappingScreenState extends State<SupplierMappingScreen> {
  List<Map<String, dynamic>> _suppliers = [];
  Map<String, List<String>> _variations = {};
  bool _isLoading = true;
  String? _selectedSupplierId;
  final TextEditingController _variationController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _variationController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final storage = context.read<OfflineStorage>();
      final suppliers = await storage.getMasterSuppliers();

      // In a real implementation, you'd get variations from storage
      // This is a placeholder
      final variations = <String, List<String>>{};

      setState(() {
        _suppliers = suppliers;
        _variations = variations;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addVariation() async {
    if (_selectedSupplierId == null || _variationController.text.isEmpty) return;

    final variation = _variationController.text.trim();
    final storage = context.read<OfflineStorage>();

    // Add the mapping
    await storage.addSupplierMapping(variation, _selectedSupplierId!);

    setState(() {
      if (!_variations.containsKey(_selectedSupplierId)) {
        _variations[_selectedSupplierId!] = [];
      }
      _variations[_selectedSupplierId!]!.add(variation);
      _variationController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Supplier Name Mapping'),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            onPressed: _autoGenerateMappings,
            tooltip: 'Auto-generate from existing data',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Map supplier name variations to a single supplier',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      decoration: const InputDecoration(
                        labelText: 'Select Supplier',
                        border: OutlineInputBorder(),
                      ),
                      value: _selectedSupplierId,
                      items: _suppliers.map((s) {
                        return DropdownMenuItem(
                          value: s['supplierID']?.toString(),
                          child: Text(s['Supplier']?.toString() ?? 'Unknown'),
                        );
                      }).toList(),
                      onChanged: (val) => setState(() => _selectedSupplierId = val),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _variationController,
                            decoration: const InputDecoration(
                              labelText: 'Name Variation',
                              hintText: 'e.g., DURBAN NORTH LIQ',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          icon: const Icon(Icons.add),
                          onPressed: _addVariation,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _suppliers.length,
              itemBuilder: (context, index) {
                final supplier = _suppliers[index];
                final supplierId = supplier['supplierID']?.toString() ?? '';
                final variations = _variations[supplierId] ?? [];

                if (variations.isEmpty) return const SizedBox.shrink();

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          supplier['Supplier']?.toString() ?? 'Unknown',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...variations.map((v) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(Icons.subdirectory_arrow_right, size: 16, color: Colors.grey),
                              const SizedBox(width: 8),
                              Expanded(child: Text(v)),
                            ],
                          ),
                        )),
                      ],
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

  Future<void> _autoGenerateMappings() async {
    // This would scan existing GRV data and suggest mappings
    // Implementation depends on your data structure
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Auto-generation coming soon!')),
    );
  }
}