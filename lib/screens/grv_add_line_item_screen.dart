import 'package:counting_app/screens/purchases_line_items_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';

class GrvAddLineItemScreen extends StatefulWidget {
  final String invoiceDetailsID;
  final String supplierName;
  final DateTime deliveryDate;

  const GrvAddLineItemScreen({
    super.key,
    required this.invoiceDetailsID,
    required this.supplierName,
    required this.deliveryDate,
  });

  @override
  State<GrvAddLineItemScreen> createState() => _GrvAddLineItemScreenState();
}

class _GrvAddLineItemScreenState extends State<GrvAddLineItemScreen> {
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController(text: '1');
  final TextEditingController _unitsPerCaseController = TextEditingController(text: '24');
  final TextEditingController _priceController = TextEditingController(text: '0.00');

  List<Map<String, dynamic>> _productSuggestions = [];
  Map<String, dynamic>? _selectedProduct;
  bool _isLoadingProducts = false;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    setState(() => _isLoadingProducts = true);
    try {
      final storage = context.read<OfflineStorage>();
      final inv = await storage.getAllInventory();
      print('Inventory count: ${inv.length}');
      print('First item: ${inv.first}');

      // 🔥 Critical: Filter AND validate each item
      _productSuggestions = inv.where((item) {
        final name = item['Inventory Product Name']?.toString() ?? '';
        return name.isNotEmpty && name != 'null';
      }).toList();

      print('Loaded ${_productSuggestions.length} valid products');
    } catch (e) {
      print('Error loading products: $e');
      _productSuggestions = [];
    } finally {
      setState(() => _isLoadingProducts = false);
    }
  }

  List<Map<String, dynamic>> _filterSuggestions(String query) {
    if (query.isEmpty) return _productSuggestions.take(10).toList();
    final q = query.toLowerCase();
    return _productSuggestions.where((item) =>
    (item['Inventory Product Name']?.toString()?.toLowerCase() ?? '').contains(q) ||
        (item['Barcode']?.toString()?.toLowerCase() ?? '').contains(q) ||
        (item['bottleID']?.toString()?.toLowerCase() ?? '').contains(q)
    ).take(10).toList(); // ✅ ADDED MISSING PARENTHESES AND DOT BEFORE take()
  }

  void _onProductSelected(Map<String, dynamic> product) {
    setState(() {
      _selectedProduct = product;
      _descriptionController.text = product['Inventory Product Name']?.toString() ?? '';
      final packSize = product['Pack Size'] ?? product['Case/Pack Size'];
      if (packSize != null) {
        final numPart = RegExp(r'\d+').firstMatch(packSize.toString())?.group(0);
        if (numPart != null) _unitsPerCaseController.text = numPart;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filterSuggestions(_descriptionController.text);

    return Scaffold(
      appBar: AppBar(title: const Text('Add Line Item')),

      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Autocomplete<Map<String, dynamic>>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                return filtered;
              },
              displayStringForOption: (option) => option['Inventory Product Name']?.toString() ?? '',
              onSelected: _onProductSelected,
              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                return TextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: InputDecoration(
                    labelText: 'Product Description *',
                    hintText: 'Search products...',
                    suffixIcon: _isLoadingProducts ? const CircularProgressIndicator.adaptive(strokeWidth: 2) : null,
                    border: const OutlineInputBorder(),
                  ),
                );
              },
              optionsViewBuilder: (context, onSelected, options) {
                return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: ListView.builder(
                          itemCount: options.length,
                          itemBuilder: (_, i) {
                            final item = options.elementAt(i); // ✅ FIXED: Use elementAt(i) instead of [i]
                            return ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.grey.shade200,
                                child: Text(
                                  (item['bottleID'] ?? item['Barcode'] ?? item['Inventory Product Name'] ?? '')
                                      .substring(0, 2)
                                      .toUpperCase(),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              title: Text(item['Inventory Product Name'] ?? 'Unnamed'),
                              subtitle: Text('${item['Barcode'] ?? ''} • ${item['Category'] ?? ''}'),
                              onTap: () => onSelected(item),
                            );
                          },
                        ),
                      ),
                    ),
                );

                },
            ),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _quantityController,
                    decoration: const InputDecoration(labelText: 'Cases *'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _unitsPerCaseController,
                    decoration: const InputDecoration(labelText: 'Units/Case *'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            TextField(
              controller: _priceController,
              decoration: const InputDecoration(labelText: 'Price per Unit *'),
              keyboardType: TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      final desc = _descriptionController.text.trim();
                      final qty = int.tryParse(_quantityController.text) ?? 1;
                      final units = int.tryParse(_unitsPerCaseController.text) ?? 24;
                      final price = double.tryParse(_priceController.text.replaceAll(',', '')) ?? 0.0;

                      if (desc.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Product Description is required')),
                        );
                        return;
                      }
                      if (qty <= 0 || units <= 0 || price < 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invalid values entered')),
                        );
                        return;
                      }

                      final newItem = GrvLineItemDisplay(
                        plu: _selectedProduct?['bottleID']?.toString(),
                        description: desc,
                        quantityCases: qty,
                        unitsPerCase: units,
                        pricePerUnit: price,
                        productName: _selectedProduct?['Inventory Product Name']?.toString(),
                        barcode: _selectedProduct?['Barcode']?.toString(),
                      );

                      Navigator.pop(context, newItem); // Return to Line Items screen
                    },
                    child: const Text('Add Item'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}