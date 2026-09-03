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
  final String grvReference; // 🔥 ADD THIS
  final GrvLineItemDisplay? initialItem;

  const GrvAddLineItemScreen({
    super.key,
    required this.invoiceDetailsID,
    required this.supplierName,
    required this.deliveryDate,
    required this.grvReference, // 🔥 ADD THIS
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
  String? _foundSupplierBottleID; // 🔥 Added to store supplierBottleID from MasterCosts

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

    _selectedPackSize = 'Case ${item.unitsPerCase}';
    _autoCalculatedPrice = item.pricePerUnit;

    // 🔥 FIX: carry category metadata so pack-size options and the returned
    // GrvLineItemDisplay keep Main Category / Category / volume / UoM.
    _selectedProduct = {
      'Inventory Product Name': item.productName ?? item.description,
      'bottleID': item.plu,
      'Barcode': item.barcode,
      'Main Category': item.mainCategory,
      'Category': item.category,
      'Single Unit Volume': item.singleUnitVolume,
      'UoM': item.uom,
    };
  }

  // 🔥 FIX: extracted the inline onPressed into a full function so the
  // returned GrvLineItemDisplay carries the product metadata upstream.
  void _submitItem() {
    final desc = _descriptionController.text.trim();
    final qty = int.tryParse(_quantityController.text) ?? 1;
    final units = int.tryParse(_unitsPerCaseController.text) ?? 24;
    final price =
        double.tryParse(_priceController.text.replaceAll(',', '')) ?? 0.0;

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
      productName:
          _selectedProduct?['Inventory Product Name']?.toString() ??
          widget.initialItem?.productName,
      barcode:
          _selectedProduct?['Barcode']?.toString() ??
          widget.initialItem?.barcode,
      supplierBottleID: _foundSupplierBottleID ?? widget.initialItem?.supplierBottleID, // 🔥 Pass the found bottle ID
      // 🔥 FIX: this is what was missing — without it the edit screen wrote
      // empty Category/UoM/volume for manually added lines (the tonic rows).
      mainCategory:
          _selectedProduct?['Main Category']?.toString() ??
          widget.initialItem?.mainCategory,
      category:
          _selectedProduct?['Category']?.toString() ??
          widget.initialItem?.category,
      singleUnitVolume: _selectedProduct != null
          ? _parseNumber(_selectedProduct!['Single Unit Volume'])
          : (widget.initialItem?.singleUnitVolume ?? 0),
      uom: _selectedProduct?['UoM']?.toString() ?? widget.initialItem?.uom,
    );

    Navigator.pop(context, lineItem);
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
    final storeName =
        context.read<StoreManager>().activeStore?['name'] ?? 'Unknown Store';

    final newProduct = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            AddProductScreen(initialName: _descriptionController.text),
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
              content: Text(
                '✓ Added ${newProduct['Inventory Product Name']} to inventory',
              ),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error saving product: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _isLoadingProducts = false);
      }
    }
  }

  // Enhanced cost lookup with feedback
  Future<void> _lookupCostWithFeedback(
    String productName,
    String supplierName,
    String supplierId,
  ) async {
    try {
      final result = await _lookupCost(productName, supplierName, supplierId);
      if (!_isMounted()) return;

      if (result != null) {
        setState(() {
          _autoCalculatedPrice = result['price'];
          _foundSupplierBottleID = result['supplierBottleID'];
          _priceController.text = _autoCalculatedPrice!.toStringAsFixed(2);
        });
        print('✅ Cost lookup success: R$_autoCalculatedPrice, BottleID: $_foundSupplierBottleID');
      } else {
        if (_isMounted()) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
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
    ].contains(cat)) {
      return [
        'Case 1',
        'Case 2',
        'Case 4',
        'Case 6',
        'Case 12',
        'Case 24',
        'Case 36',
        'Case 48',
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
      'consumables',
    ].contains(cat)) {
      return [
        'Single',
        'Pack 10',
        'Pack 20',
        'Keg 1',
        '5 Ltr Cartons',
        '10 Ltr Cartons',
        'Each',
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

  Future<Map<String, dynamic>?> _lookupCost(
    String productName,
    String supplierName,
    String supplierId,
  ) async {
    print('🔍 ===== COST LOOKUP START =====');
    print('  📦 Product: "$productName"');
    print('  🏢 Supplier: "$supplierName"');
    print('  🆔 SupplierID: "$supplierId"');

    try {
      final storage = context.read<OfflineStorage>();

      final allSuppliers = await storage.getMasterSuppliers();
      final supplierMatch = allSuppliers.firstWhere(
        (s) =>
            s['Supplier']?.toString().toLowerCase().trim() ==
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
      Map<String, dynamic>? bestMatch;

      // Strategy 1: Match by product name + supplier (Primary)
      if (actualSupplierId.isNotEmpty) {
        final supplierMatches = masterCosts.where((cost) {
          final costName = (cost['Product Name']?.toString() ?? '')
              .toLowerCase()
              .trim();
          final costSupplierId = (cost['supplierID']?.toString() ?? '').trim();
          final searchName = productName.toLowerCase().trim();

          return (costName == searchName ||
                  costName.contains(searchName) ||
                  searchName.contains(costName)) &&
              costSupplierId == actualSupplierId;
        }).toList();

        if (supplierMatches.isNotEmpty) {
          bestMatch = supplierMatches.first;
        }
      }

      // Strategy 2: Match by product name only (Fallback)
      if (bestMatch == null) {
        final nameMatches = masterCosts.where((cost) {
          final costName = (cost['Product Name']?.toString() ?? '')
              .toLowerCase()
              .trim();
          final searchName = productName.toLowerCase().trim();
          return costName == searchName ||
                 costName.contains(searchName) ||
                 searchName.contains(costName);
        }).toList();

        if (nameMatches.isNotEmpty) {
          bestMatch = nameMatches.first;
        }
      }

      if (bestMatch != null) {
        final price = _extractCost(bestMatch);
        if (price != null) {
          return {
            'price': price,
            'supplierBottleID': bestMatch['supplierBottleID']?.toString(),
          };
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
    final costValue =
        costEntry['Cost Price'] ??
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

  // ADD THIS small helper next to _extractCost
  double _parseNumber(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    final cleaned = value.toString().replaceAll(RegExp(r'[^\d.-]'), '');
    return double.tryParse(cleaned) ?? 0.0;
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
      _descriptionController.text =
          product['Inventory Product Name']?.toString() ?? '';

      final category = product['Category']?.toString();
      final packSizes = _getPackSizesForCategory(category);

      if (packSizes.isNotEmpty) {
        _selectedPackSize = packSizes.first;
        _unitsPerCaseController.text = _getUnitsPerCase(
          _selectedPackSize!,
        ).toString();
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

  // 🔥 CX helper: pack sizes for the currently selected product's category
  // (bridges to the existing _getPackSizesForCategory so the new build() compiles)
  List<String> _getFilteredPackSizes() {
    return _getPackSizesForCategory(
      _selectedProduct?['Category']?.toString(),
    );
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
                      _unitsPerCaseController.text = _getUnitsPerCase(
                        _selectedPackSize!,
                      ).toString();
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
  @override
  Widget build(BuildContext context) {
    // 🔥 CX: Pack sizes for the selected product's category (outlined dropdown like CountScreen)
    final currentPackSizes = List<String>.from(_getFilteredPackSizes());
    if (_selectedPackSize != null && !currentPackSizes.contains(_selectedPackSize)) {
      currentPackSizes.insert(0, _selectedPackSize!);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditMode ? 'Edit Line Item' : 'Add Line Item'),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            children: [
              // 1. PRODUCT INPUT + filled "+" — same CX as the New Count screen
              Row(
                children: [
                  Expanded(
                    child: Autocomplete<Map<String, dynamic>>(
                      initialValue: TextEditingValue(text: widget.initialItem?.description ?? ''),
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
                        return TextFormField(
                          controller: controller,
                          focusNode: focusNode,
                          onChanged: (value) {
                            _descriptionController.text = value;
                          },
                          onFieldSubmitted: (_) => onFieldSubmitted(),
                          decoration: const InputDecoration(
                            labelText: 'Product Description *',
                            hintText: 'Search products...',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.inventory),
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
                  ),
                  const SizedBox(width: 8),
                  // 🔥 Replaces the orange FAB — same purple filled + as CountScreen
                  IconButton.filled(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add New Product',
                    onPressed: _openManualAdd,
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // 2. PACK SIZE — outlined dropdown (was the grey GestureDetector box)
              DropdownButtonFormField<String>(
                value: _selectedPackSize,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Pack Size',
                  border: OutlineInputBorder(),
                ),
                hint: const Text('Select Pack Size'),
                items: currentPackSizes
                    .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                    .toList(),
                onChanged: (val) {
                  if (val == null) return;
                  setState(() {
                    _selectedPackSize = val;
                    _unitsPerCaseController.text = _getUnitsPerCase(val).toString();
                  });
                },
              ),

              const SizedBox(height: 16),

              // 3. UNITS/CASE
              TextFormField(
                controller: _unitsPerCaseController,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'Units/Case',
                  border: const OutlineInputBorder(),
                  helperText: _selectedPackSize != null ? 'Auto from: $_selectedPackSize' : null,
                ),
                keyboardType: TextInputType.number,
              ),

              const SizedBox(height: 16),

              // 4. CASES + PRICE + green ✓ — same CX as the CountScreen save button
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _quantityController,
                      decoration: const InputDecoration(
                        labelText: 'Cases *',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      controller: _priceController,
                      decoration: InputDecoration(
                        labelText: 'Price per Unit *',
                        border: const OutlineInputBorder(),
                        prefixText: 'R ',
                        helperText: _autoCalculatedPrice != null
                            ? 'Auto: R${_autoCalculatedPrice!.toStringAsFixed(2)}'
                            : null,
                      ),
                      keyboardType: TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 56,
                    width: 56,
                    child: IconButton.filled(
                      onPressed: _submitItem,
                      icon: const Icon(Icons.check, size: 28),
                      tooltip: _isEditMode ? 'Update Item' : 'Add Item',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
