import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../models/grv_models.dart';

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
  final TextEditingController _quantityController = TextEditingController(
      text: '1');
  final TextEditingController _unitsPerCaseController = TextEditingController(
      text: '24');
  final TextEditingController _priceController = TextEditingController(
      text: '0.00');

  List<Map<String, dynamic>> _productSuggestions = [];
  Map<String, dynamic>? _selectedProduct;
  bool _isLoadingProducts = false;
  bool _isDisposed = false; // 🔴 FIX 1: Add _isDisposed flag

  bool _isMounted() => mounted && !_isDisposed;

  // Track selected pack size and auto-lookup cost
  String? _selectedPackSize;
  double? _autoCalculatedPrice;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _isDisposed = true; // 🔴 FIX 2: Set disposed flag
    _descriptionController.dispose();
    _quantityController.dispose();
    _unitsPerCaseController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    if (!_isMounted()) return;
    setState(() => _isLoadingProducts = true);
    try {
      final storage = context.read<OfflineStorage>();
      final inv = await storage.getAllInventory();
      if (!_isMounted()) return;

      // Filter valid products
      _productSuggestions = inv.where((item) {
        final name = item['Inventory Product Name']?.toString() ?? '';
        return name.isNotEmpty && name != 'null';
      }).toList();

      print('Loaded ${_productSuggestions.length} valid products');
    } catch (e) {
      if (!_isMounted()) return;
      print('Error loading products: $e');
      _productSuggestions = [];
    } finally {
      if (!_isMounted()) return;
      setState(() => _isLoadingProducts = false);
    }
  }

  // Enhanced cost lookup with feedback
  Future<void> _lookupCostWithFeedback(String productName, String supplierName,
      String supplierId) async {
    try {
      final price = await _lookupCost(productName, supplierName, supplierId);
      if (!_isMounted()) return; // 🔴 ADD THIS AFTER AWAIT

      if (price != null) {
        setState(() {
          _autoCalculatedPrice = price;
          _priceController.text = price.toStringAsFixed(2);
        });
      } else {
        // Show user that lookup failed
        if (_isMounted()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⚠️ Cost lookup failed. Enter price manually.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (!_isMounted()) return; // 🔴 ADD THIS
      print('Cost lookup error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ Cost lookup error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  List<Map<String, dynamic>> _filterSuggestions(String query) {
    if (query.isEmpty) return _productSuggestions.take(10).toList();
    final q = query.toLowerCase();
    return _productSuggestions.where((item) =>
    (item['Inventory Product Name']?.toString()?.toLowerCase() ?? '').contains(
        q) ||
        (item['Barcode']?.toString()?.toLowerCase() ?? '').contains(q) ||
        (item['bottleID']?.toString()?.toLowerCase() ?? '').contains(q)
    ).take(10).toList();
  }

  // Determine pack sizes based on category
  List<String> _getPackSizesForCategory(String? category) {
    if (category == null)
      return ['Case 1', 'Case 6', 'Case 12', 'Case 24', 'Case 36', 'Case 48'];

    final cat = category.toLowerCase();

    // DRINKS GROUP
    if ([
      'beer',
      'cider',
      'coolers',
      'champagne',
      'white wine',
      'sparkling wine',
      'rose',
      'red wine',
      'sparkling white wine',
      'champagne xl',
      'soft drinks',
      'still water',
      'sparkling water',
      'whiskey',
      'vodka',
      'tequila',
      'liqueurs',
      'gin',
      'aperatif',
      'cognac',
      'bourbon',
      'rum',
      'brandy',
      'cordials',
      'schnapps',
      'coolers',
      'cider',
      'beer',
      'coolers'
    ].contains(cat)) {
      return [
        'Case 1',
        'Case 2',
        'Case 4',
        'Case 6',
        'Case 12',
        'Case 24',
        'Case 36',
        'Case 48'
      ];
    }

    // FOOD GROUP
    if ([
      'meat',
      'poultry',
      'seafood',
      'dairy',
      'vegetables',
      'fruit',
      'dry goods',
      'spices',
      'bakery',
      'prepared food',
      'consumables'
    ].contains(cat)) {
      return [
        'Single',
        'Pack 10',
        'Pack 20',
        'Keg 1',
        '5 Ltr Cartons',
        '10 Ltr Cartons',
        'Each'
      ];
    }

    // TOBACCO GROUP
    if (['tobacco', 'cigarettes', 'cigars'].contains(cat)) {
      return ['Case 1', 'Case 10', 'Case 20', 'Pack 20', 'Each'];
    }

    // DEFAULT
    return ['Case 1', 'Case 6', 'Case 12', 'Case 24', 'Case 36', 'Case 48'];
  }

  // Get units per case from pack size
  int _getUnitsPerCase(String packSize) {
    final match = RegExp(r'\d+').firstMatch(packSize);
    if (match != null) {
      return int.tryParse(match.group(0)!) ?? 1;
    }
    return 1;
  }

  // 🔴 FIX 4: Fix cost lookup to properly get supplier ID
  // In grv_add_line_item_screen.dart
  Future<double?> _lookupCost(String productName, String supplierName,
      String supplierId) async {
    print('🔍 ===== COST LOOKUP START =====');
    print('  📦 Product: "$productName"');
    print('  🏢 Supplier: "$supplierName"');
    print('  🆔 SupplierID: "$supplierId"');

    try {
      final storage = context.read<OfflineStorage>();

      // Check if suppliers exist
      final allSuppliers = await storage.getMasterSuppliers();
      print('  📊 Total suppliers in DB: ${allSuppliers.length}');

      // Check if this supplier exists
      final supplierMatch = allSuppliers.firstWhere(
            (s) =>
        s['Supplier']?.toString().toLowerCase().trim() ==
            supplierName.toLowerCase().trim(),
        orElse: () => <String, dynamic>{},
      );
      print('  🔎 Supplier exists in DB: ${supplierMatch.isNotEmpty}');
      if (supplierMatch.isNotEmpty) {
        print('  ✅ Supplier ID in DB: ${supplierMatch['supplierID']}');
      }

      // Get master costs
      final masterCosts = await storage.getMasterCosts();
      print('  📊 Total master costs in DB: ${masterCosts.length}');

      if (masterCosts.isEmpty) {
        print('  ⚠️ No master costs available - cannot lookup price');
        print('🔍 ===== COST LOOKUP END (NO COSTS) =====');
        return null;
      }

      // Show sample costs for debugging
      print('  📝 Sample costs (first 3):');
      for (var i = 0; i < masterCosts.length && i < 3; i++) {
        final cost = masterCosts[i];
        print('    [${i +
            1}] Product: "${cost['Product Name']}", Supplier: "${cost['Supplier']}", Price: ${cost['Cost Price']}');
      }

      // Try to find match
      String actualSupplierId = supplierId;
      if (supplierId == supplierName) {
        print('  ⚠️ supplierId looks like a name, attempting to resolve...');
        if (supplierMatch.isNotEmpty) {
          actualSupplierId = supplierMatch['supplierID']?.toString() ?? '';
          print('  ✅ Resolved supplier ID to: $actualSupplierId');
        }
      }

      // Try multiple matching strategies
      double? foundCost;

      // Strategy 1: Match by product name only
      print('  🔎 Trying Strategy 1: Product name only match');
      final nameMatches = masterCosts.where((cost) {
        final costName = (cost['Product Name']?.toString() ?? '')
            .toLowerCase()
            .trim();
        final searchName = productName.toLowerCase().trim();
        return costName.contains(searchName) || searchName.contains(costName);
      }).toList();

      print('  📊 Found ${nameMatches.length} name matches');
      if (nameMatches.isNotEmpty) {
        final firstMatch = nameMatches.first;
        foundCost = _extractCost(firstMatch);
        print(
            '  ✅ Strategy 1 matched: ${firstMatch['Product Name']} @ R$foundCost');
        if (foundCost != null) return foundCost;
      }

      // Strategy 2: Match by product + supplier
      if (actualSupplierId.isNotEmpty) {
        print('  🔎 Trying Strategy 2: Product + Supplier match');
        final supplierMatches = masterCosts.where((cost) {
          final costName = (cost['Product Name']?.toString() ?? '')
              .toLowerCase()
              .trim();
          final costSupplierId = (cost['supplierID']?.toString() ?? '').trim();
          final searchName = productName.toLowerCase().trim();

          return (costName.contains(searchName) ||
              searchName.contains(costName)) &&
              costSupplierId == actualSupplierId;
        }).toList();

        print('  📊 Found ${supplierMatches.length} product+supplier matches');
        if (supplierMatches.isNotEmpty) {
          final firstMatch = supplierMatches.first;
          foundCost = _extractCost(firstMatch);
          print(
              '  ✅ Strategy 2 matched: ${firstMatch['Product Name']} @ R$foundCost');
          if (foundCost != null) return foundCost;
        }
      }

      print('  ❌ No matching cost found after all strategies');
      print('🔍 ===== COST LOOKUP END (FAILED) =====');
      return null;
    } catch (e) {
      print('🔍 ERROR in cost lookup: $e');
      print('🔍 Stack trace: ${StackTrace.current}');
      return null;
    }
  }

// Add helper method
  double? _extractCost(Map<String, dynamic> costEntry) {
    final costValue = costEntry['Cost Price'] ??
        costEntry['Unit Cost'] ??
        costEntry['Cost'] ??
        costEntry['avgCost'];

    print('  💰 Extracting cost from: $costValue');

    if (costValue == null) return null;

    if (costValue is num) {
      final result = costValue.toDouble();
      print('  ✅ Extracted number: $result');
      return result;
    }

    if (costValue is String) {
      final cleaned = costValue.replaceAll(RegExp(r'[^\d.]'), '');
      final result = double.tryParse(cleaned);
      print('  ✅ Extracted from string: "$costValue" -> "$cleaned" -> $result');
      return result;
    }

    print('  ❌ Could not extract cost from type: ${costValue.runtimeType}');
    return null;
  }

  // 🔴 FIX 5: Implement _getSupplierIdForName method
  Future<String> _getSupplierIdForName(String supplierName) async {
    try {
      final storage = context.read<OfflineStorage>();
      final suppliers = await storage.getMasterSuppliers();
      final match = suppliers.firstWhere(
            (s) => s['Supplier']?.toString() == supplierName,
        orElse: () => <String, dynamic>{},
      );
      return match['supplierID']?.toString() ?? '';
    } catch (e) {
      print('Error getting supplier ID: $e');
      return '';
    }
  }

  // 🔴 FIX 6: Make createStandardPurchase async to handle supplier ID lookup
  Future<Map<String, dynamic>> createStandardPurchase({
    required String invoiceId,
    required String supplierName,
    required String productName,
    required String plu,
    required double price,
    required int quantity,
    required int unitsPerCase,
    required String barcode,
  }) async {
    final supplierId = await _getSupplierIdForName(supplierName);

    return {
      'purchases_ID': 'purchase_${DateTime
          .now()
          .millisecondsSinceEpoch}_${quantity}_${plu}',
      'invoiceDetailsID': invoiceId,
      'supplierID': supplierId,
      'Supplier': supplierName,
      'Barcode': barcode,
      'Purchased Product Name': productName,
      'purSupplierBottleID': plu,
      'Cost Per Bottle': price,
      'Stock Delivery Date': widget.deliveryDate.toIso8601String(),
      // 🔴 FIX 7: Use widget.deliveryDate
      'Case/Pack Size': 'Case $unitsPerCase',
      'Qty Purchased': quantity.toDouble(),
      'Purchases Bottles': (quantity * unitsPerCase).toDouble(),
      'Cost of Purchases': price * quantity * unitsPerCase,
      'syncStatus': 'pending',
    };
  }

  void _onProductSelected(Map<String, dynamic> product) async {
    print('🔍 ===== PRODUCT SELECTED =====');
    print('  📦 Product: ${product['Inventory Product Name']}');
    print('  🆔 Barcode: ${product['Barcode']}');
    print('  🏷️ Category: ${product['Category']}');

    setState(() {
      _selectedProduct = product;
      _descriptionController.text =
          product['Inventory Product Name']?.toString() ?? '';

      final category = product['Category']?.toString();
      final packSizes = _getPackSizesForCategory(category);

      if (packSizes.isNotEmpty) {
        _selectedPackSize = packSizes.first;
        _unitsPerCaseController.text =
            _getUnitsPerCase(_selectedPackSize!).toString();
        print('  📦 Selected pack size: $_selectedPackSize');
      }
    });

    // Get supplier ID first
    print('  🔎 Looking up supplier ID for: ${widget.supplierName}');
    final supplierId = await _getSupplierIdForName(widget.supplierName);

    if (supplierId.isNotEmpty) {
      print('  ✅ Found supplier ID: $supplierId');
      await _lookupCostWithFeedback(
        product['Inventory Product Name']?.toString() ?? '',
        widget.supplierName,
        supplierId,
      );
    } else {
      print('  ❌ No supplier ID found for ${widget.supplierName}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ Supplier not found in database'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
    print('🔍 ===== PRODUCT SELECTION END =====');
  }

  // Handle pack size selection
  void _showPackSizeSelection(String? category) {
    final packSizes = _getPackSizesForCategory(category);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select Pack Size'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: packSizes.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(packSizes[index]),
                  onTap: () {
                    setState(() {
                      _selectedPackSize = packSizes[index];
                      _unitsPerCaseController.text = _getUnitsPerCase(
                          _selectedPackSize!).toString();
                    });
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Line Item')),
      body: SingleChildScrollView( // ✅ Wrap everything in SingleChildScrollView
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Product Search with Auto-populated Fields
            Autocomplete<Map<String, dynamic>>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text.isEmpty) return [];
                return _productSuggestions.where((item) =>
                    (item['Inventory Product Name']
                        ?.toString()
                        ?.toLowerCase() ?? '')
                        .contains(textEditingValue.text.toLowerCase())
                ).toList();
              },
              displayStringForOption: (
                  option) => option['Inventory Product Name']?.toString() ?? '',
              onSelected: _onProductSelected,
              fieldViewBuilder: (context, controller, focusNode,
                  onFieldSubmitted) {
                return TextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: InputDecoration(
                    labelText: 'Product Description *',
                    hintText: 'Search products...',
                    suffixIcon: _isLoadingProducts
                        ? const CircularProgressIndicator.adaptive(
                        strokeWidth: 2)
                        : null,
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
                          final item = options.elementAt(i);
                          return ListTile(
                            dense: true,
                            title: Text(
                                item['Inventory Product Name'] ?? 'Unnamed'),
                            subtitle: Text('${item['Barcode'] ??
                                ''} • ${item['Category'] ?? ''}'),
                            onTap: () => onSelected(item),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 16),

            // Pack Size Selection
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pack Size',
                    style: Theme
                        .of(context)
                        .textTheme
                        .labelLarge,
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () {
                      if (_selectedProduct != null) {
                        _showPackSizeSelection(
                            _selectedProduct!['Category']?.toString());
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text(
                              'Please select a product first')),
                        );
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.grey.shade50,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _selectedPackSize ?? 'Select Pack Size',
                            style: TextStyle(
                              color: _selectedPackSize == null
                                  ? Colors.grey
                                  : Colors.black87,
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Units Per Case
            TextFormField(
              controller: _unitsPerCaseController,
              readOnly: true,
              decoration: InputDecoration(
                labelText: 'Units/Case',
                helperText: _selectedPackSize != null
                    ? 'Auto from: $_selectedPackSize'
                    : null,
              ),
              keyboardType: TextInputType.number,
            ),

            const SizedBox(height: 16),

            // Quantity and Price
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _quantityController,
                    decoration: const InputDecoration(labelText: 'Cases *'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _priceController,
                    decoration: InputDecoration(
                      labelText: 'Price per Unit *',
                      helperText: _autoCalculatedPrice != null
                          ? 'Auto: R${_autoCalculatedPrice!.toStringAsFixed(2)}'
                          : null,
                      prefixText: 'R ',
                    ),
                    keyboardType: TextInputType.numberWithOptions(
                        decimal: true),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Submit button
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
                    onPressed: () async {
                      // Validation and submission logic
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

                      print('DEBUG: _selectedProduct exists: ${_selectedProduct != null}');
                      if (_selectedProduct != null) {
                        print('DEBUG: Product name: ${_selectedProduct!['Inventory Product Name']}');
                        print('DEBUG: Barcode: ${_selectedProduct!['Barcode']}');
                        print('DEBUG: bottleID: ${_selectedProduct!['bottleID']}');
                      }

                      // Create the return object
                      final newItem = GrvLineItemDisplay(
                        plu: _selectedProduct?['bottleID']?.toString(),
                        description: desc,
                        quantityCases: qty,
                        unitsPerCase: units,
                        pricePerUnit: price,
                        productName: _selectedProduct?['Inventory Product Name']?.toString(),
                        barcode: _selectedProduct?['Barcode']?.toString(),
                        // supplierBottleID will be set during matching in the main screen
                      );

                      print('DEBUG: Returning item from add screen: ${newItem.description}'); // ADD THIS
                      Navigator.pop(context, newItem); // ← THIS SHOULD RETURN THE ITEM
                    },
                    child: const Text('Add Item'),
                  )
                ),
              ],
            ),

            // ✅ Add bottom padding to prevent overflow
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}