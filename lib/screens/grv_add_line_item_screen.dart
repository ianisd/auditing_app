import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../models/grv_models.dart';
import 'add_product_screen.dart';
import '../services/store_manager.dart';

class GrvAddLineItemScreen extends StatefulWidget {
  final String invoiceDetailsID;
  final String supplierName;
  final DateTime deliveryDate;
  final String grvReference;  // 🔥 ADD THIS
  final GrvLineItemDisplay? initialItem;

  const GrvAddLineItemScreen({
    super.key,
    required this.invoiceDetailsID,
    required this.supplierName,
    required this.deliveryDate,
    required this.grvReference,  // 🔥 ADD THIS
    this.initialItem,
  });

  @override
  State<GrvAddLineItemScreen> createState() => _GrvAddLineItemScreenState();
}

class _GrvAddLineItemScreenState extends State<GrvAddLineItemScreen> {
  late TextEditingController _descriptionController;
  late TextEditingController _quantityController;
  late TextEditingController _unitsPerCaseController;
  late TextEditingController _priceController;

  List<Map<String, dynamic>> _productSuggestions = [];
  Map<String, dynamic>? _selectedProduct;
  bool _isLoadingProducts = false;
  bool _isDisposed = false;
  bool _isEditMode = false; // ADD THIS

  final FocusNode _productFocusNode = FocusNode();

  // Track selected pack size and auto-lookup cost
  String? _selectedPackSize;
  double? _autoCalculatedPrice;

  bool _isMounted() => mounted && !_isDisposed;

  @override
  void initState() {
    super.initState();

    // Initialize controllers
    _descriptionController = TextEditingController();
    _quantityController = TextEditingController(text: '1');
    _unitsPerCaseController = TextEditingController(text: '24');
    _priceController = TextEditingController(text: '0.00');

    // Check if we're in edit mode
    _isEditMode = widget.initialItem != null;

    if (_isEditMode) {
      _populateWithExistingData();
    }

    _loadProducts();
  }

  // ADD THIS: Populate form with existing item data
  void _populateWithExistingData() {
    final item = widget.initialItem!;

    _descriptionController.text = item.description;
    _quantityController.text = item.quantityCases.toString();
    _unitsPerCaseController.text = item.unitsPerCase.toString();
    _priceController.text = item.pricePerUnit.toStringAsFixed(2);

    // Set selected pack size based on units per case
    _selectedPackSize = 'Case ${item.unitsPerCase}';
    _autoCalculatedPrice = item.pricePerUnit;

    // Create a pseudo product for the selected item
    _selectedProduct = {
      'Inventory Product Name': item.productName ?? item.description,
      'bottleID': item.plu,
      'Barcode': item.barcode,
    };
  }

  @override
  void dispose() {
    _isDisposed = true;
    _descriptionController.dispose();
    _quantityController.dispose();
    _unitsPerCaseController.dispose();
    _priceController.dispose();
    _productFocusNode.dispose();
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

  // Open Add Product Screen
  Future<void> _openManualAdd() async {
    final storeName = context.read<StoreManager>().activeStore?['name'] ?? 'Unknown Store';

    final newProduct = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddProductScreen(
          initialName: _descriptionController.text,
        ),
      ),
    );

    if (newProduct != null && newProduct is Map<String, dynamic>) {
      setState(() => _isLoadingProducts = true);

      try {
        newProduct['storeName'] = storeName;
        await context.read<OfflineStorage>().saveNewLocalProduct(newProduct);
        await _loadProducts();
        _onProductSelected(newProduct);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✓ Added ${newProduct['Inventory Product Name']} to inventory'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving product: $e'), backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted) setState(() => _isLoadingProducts = false);
      }
    }
  }

  // Enhanced cost lookup with feedback
  Future<void> _lookupCostWithFeedback(String productName, String supplierName,
      String supplierId) async {
    try {
      final price = await _lookupCost(productName, supplierName, supplierId);
      if (!_isMounted()) return;

      if (price != null) {
        setState(() {
          _autoCalculatedPrice = price;
          _priceController.text = price.toStringAsFixed(2);
        });
      } else {
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
      if (!_isMounted()) return;
      print('Cost lookup error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ Cost lookup error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Determine pack sizes based on category
  List<String> _getPackSizesForCategory(String? category) {
    if (category == null) {
      return ['Case 1', 'Case 6', 'Case 12', 'Case 24', 'Case 36', 'Case 48'];
    }

    final cat = category.toLowerCase();

    // DRINKS GROUP
    if ([
      'beer', 'cider', 'coolers', 'champagne', 'white wine', 'sparkling wine',
      'rose', 'red wine', 'sparkling white wine', 'champagne xl',
      'soft drinks', 'still water', 'sparkling water',
      'whiskey', 'vodka', 'tequila', 'liqueurs', 'gin', 'aperatif',
      'cognac', 'bourbon', 'rum', 'brandy', 'cordials', 'schnapps'
    ].contains(cat)) {
      return [
        'Case 1', 'Case 2', 'Case 4', 'Case 6', 'Case 12', 'Case 24',
        'Case 36', 'Case 48'
      ];
    }

    // FOOD GROUP
    if ([
      'meat', 'poultry', 'seafood', 'dairy', 'vegetables', 'fruit',
      'dry goods', 'spices', 'bakery', 'prepared food', 'consumables'
    ].contains(cat)) {
      return [
        'Single', 'Pack 10', 'Pack 20', 'Keg 1', '5 Ltr Cartons',
        '10 Ltr Cartons', 'Each'
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

  Future<double?> _lookupCost(String productName, String supplierName,
      String supplierId) async {
    print('🔍 ===== COST LOOKUP START =====');
    print('  📦 Product: "$productName"');
    print('  🏢 Supplier: "$supplierName"');
    print('  🆔 SupplierID: "$supplierId"');

    try {
      final storage = context.read<OfflineStorage>();

      final allSuppliers = await storage.getMasterSuppliers();
      final supplierMatch = allSuppliers.firstWhere(
            (s) => s['Supplier']?.toString().toLowerCase().trim() ==
            supplierName.toLowerCase().trim(),
        orElse: () => <String, dynamic>{},
      );

      final masterCosts = await storage.getMasterCosts();

      if (masterCosts.isEmpty) {
        print('🔍 ===== COST LOOKUP END (NO COSTS) =====');
        return null;
      }

      String actualSupplierId = supplierId;
      if (supplierId == supplierName && supplierMatch.isNotEmpty) {
        actualSupplierId = supplierMatch['supplierID']?.toString() ?? '';
      }

      // Try multiple matching strategies
      double? foundCost;

      // Strategy 1: Match by product name only
      final nameMatches = masterCosts.where((cost) {
        final costName = (cost['Product Name']?.toString() ?? '').toLowerCase().trim();
        final searchName = productName.toLowerCase().trim();
        return costName.contains(searchName) || searchName.contains(costName);
      }).toList();

      if (nameMatches.isNotEmpty) {
        foundCost = _extractCost(nameMatches.first);
        if (foundCost != null) return foundCost;
      }

      // Strategy 2: Match by product + supplier
      if (actualSupplierId.isNotEmpty) {
        final supplierMatches = masterCosts.where((cost) {
          final costName = (cost['Product Name']?.toString() ?? '').toLowerCase().trim();
          final costSupplierId = (cost['supplierID']?.toString() ?? '').trim();
          final searchName = productName.toLowerCase().trim();

          return (costName.contains(searchName) || searchName.contains(costName)) &&
              costSupplierId == actualSupplierId;
        }).toList();

        if (supplierMatches.isNotEmpty) {
          foundCost = _extractCost(supplierMatches.first);
          if (foundCost != null) return foundCost;
        }
      }

      print('🔍 ===== COST LOOKUP END (FAILED) =====');
      return null;
    } catch (e) {
      print('🔍 ERROR in cost lookup: $e');
      return null;
    }
  }

  double? _extractCost(Map<String, dynamic> costEntry) {
    final costValue = costEntry['Cost Price'] ??
        costEntry['Unit Cost'] ??
        costEntry['Cost'] ??
        costEntry['avgCost'];

    if (costValue == null) return null;

    if (costValue is num) return costValue.toDouble();

    if (costValue is String) {
      final cleaned = costValue.replaceAll(RegExp(r'[^\d.]'), '');
      return double.tryParse(cleaned);
    }

    return null;
  }

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

  void _onProductSelected(Map<String, dynamic> product) async {
    print('🔍 ===== PRODUCT SELECTED =====');

    setState(() {
      _selectedProduct = product;
      _descriptionController.text = product['Inventory Product Name']?.toString() ?? '';

      final category = product['Category']?.toString();
      final packSizes = _getPackSizesForCategory(category);

      if (packSizes.isNotEmpty) {
        _selectedPackSize = packSizes.first;
        _unitsPerCaseController.text = _getUnitsPerCase(_selectedPackSize!).toString();
      }
    });

    final supplierId = await _getSupplierIdForName(widget.supplierName);

    if (supplierId.isNotEmpty) {
      await _lookupCostWithFeedback(
        product['Inventory Product Name']?.toString() ?? '',
        widget.supplierName,
        supplierId,
      );
    }
    print('🔍 ===== PRODUCT SELECTION END =====');
  }

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
                      _unitsPerCaseController.text = _getUnitsPerCase(_selectedPackSize!).toString();
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
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);

    return Scaffold(
        appBar: AppBar(
          title: Text(_isEditMode ? 'Edit Line Item' : 'Add Line Item'),
        ),
        body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(isDesktop ? 32 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            // Product Search
            Autocomplete<Map<String, dynamic>>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text.isEmpty) return [];
                return _productSuggestions.where((item) =>
                    (item['Inventory Product Name']?.toString().toLowerCase() ?? '')
                        .contains(textEditingValue.text.toLowerCase())
                ).toList();
              },
              displayStringForOption: (option) => option['Inventory Product Name']?.toString() ?? '',
              onSelected: _onProductSelected,
              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                // Sync controller with our controller
                controller.text = _descriptionController.text;

                return TextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: (value) {
                    _descriptionController.text = value;
                  },
                  decoration: InputDecoration(
                    labelText: 'Product Description *',
                    hintText: 'Search products...',
                    suffixIcon: _isLoadingProducts
                        ? const CircularProgressIndicator.adaptive(strokeWidth: 2)
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

            const SizedBox(height: 16),

                    if (isDesktop) ...[
                      // Desktop: Pack Size and Units Per Case side by side
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Pack Size
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Pack Size',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                                const SizedBox(height: 8),
                                GestureDetector(
                                  onTap: () {
                                    if (_selectedProduct != null) {
                                      _showPackSizeSelection(
                                          _selectedProduct!['Category']?.toString());
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                            content: Text(
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
                          const SizedBox(width: 16),
                          // Units Per Case
                          Expanded(
                            child: TextFormField(
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
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Cases and Price side by side
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _quantityController,
                              decoration:
                              const InputDecoration(labelText: 'Cases *'),
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
                              keyboardType:
                              TextInputType.numberWithOptions(decimal: true),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      // Mobile: original stacked layout
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Pack Size',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 8),
                            GestureDetector(
                              onTap: () {
                                if (_selectedProduct != null) {
                                  _showPackSizeSelection(
                                      _selectedProduct!['Category']?.toString());
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content:
                                        Text('Please select a product first')),
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
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _quantityController,
                              decoration:
                              const InputDecoration(labelText: 'Cases *'),
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
                              keyboardType:
                              TextInputType.numberWithOptions(decimal: true),
                            ),
                          ),
                        ],
                      ),
                    ],

            const SizedBox(height: 24),

            // Cancel and Add/Update buttons
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

                      if (_selectedProduct == null && !_isEditMode) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please select a product from the list')),
                        );
                        return;
                      }

                      final lineItem = GrvLineItemDisplay(
                        plu: _selectedProduct?['bottleID']?.toString() ?? widget.initialItem?.plu,
                        description: desc,
                        quantityCases: qty,
                        unitsPerCase: units,
                        pricePerUnit: price,
                        productName: _selectedProduct?['Inventory Product Name']?.toString() ??
                            widget.initialItem?.productName,
                        barcode: _selectedProduct?['Barcode']?.toString() ?? widget.initialItem?.barcode,
                      );

                      Navigator.pop(context, lineItem);
                    },
                    child: Text(_isEditMode ? 'Update Item' : 'Add Item'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
        ),
      floatingActionButton: FloatingActionButton.extended(
                onPressed: _openManualAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add New Product'),
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            );
        }
}