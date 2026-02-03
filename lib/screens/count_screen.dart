import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/store_manager.dart';
import '../services/logger_service.dart';
import '../widgets/barcode_scanner.dart';
import 'add_product_screen.dart';
import 'package:intl/intl.dart';

class CountScreen extends StatefulWidget {
  final Map<String, dynamic>? existingCount;
  final Map<String, dynamic>? initialProduct;
  final DateTime? initialDate;
  final String? initialLocation;

  const CountScreen({
    super.key,
    this.existingCount,
    this.initialProduct,
    this.initialDate,
    this.initialLocation,
  });

  @override
  State<CountScreen> createState() => _CountScreenState();
}

class _CountScreenState extends State<CountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _productController = TextEditingController();
  final _countController = TextEditingController(text: '0');
  final _weightController = TextEditingController(text: '0');

  // --- NEW: Measurement Mode State ---
  // Options: 'Weight' (Scale), 'Shots' (Visual), 'Volume' (Jug)
  String _measurementType = 'Volume';

  final List<String> _drinkPackSizes = [
    'Open Bottle',
    'Case 1', 'Case 4', 'Case 6', 'Case 12', 'Case 24',
    'Case 36', 'Case 48',
    'Keg 1', '5 Ltr Cartons', '10 Ltr Cartons',
  ];

  final List<String> _foodPackSizes = [
    'Loose (kg)', 'Loose (g)',
    'Each', 'Portion',
    'Pack', 'Box',
    'Case 1', 'Case 6', 'Case 12', 'Case 24'
  ];

  final List<String> _tobaccoPackSizes = [
    'Loose', 'Pack 10', 'Pack 20', 'Carton', 'Case 1'
  ];

  String? _selectedLocation;
  String? _selectedAudit;
  String? _selectedPackSize;

  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _inventory = [];
  bool _isLoading = true;
  bool _isEditMode = false;

  String? _selectedBarcode;
  Map<String, dynamic>? _selectedProduct;
  List<Map<String, dynamic>> _filteredProducts = [];
  bool _showProductSuggestions = false;
  final FocusNode _productFocusNode = FocusNode();

  // Calculated Values
  double _calcVolumeMl = 0.0;
  double _calcOpenTots = 0.0;
  double _calcTotalBottles = 0.0;
  double _calcTotalMl = 0.0;
  double _calcCostValue = 0.0;

  @override
  void initState() {
    super.initState();
    _isEditMode = widget.existingCount != null;
    _loadData();

    if (!_isEditMode) {
      _productController.addListener(_onProductSearchChanged);
    }
    _countController.addListener(_recalculateTotals);
    _weightController.addListener(_recalculateTotals);
    _productFocusNode.addListener(() {
      if (!_productFocusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) setState(() => _showProductSuggestions = false);
        });
      }
    });
  }

  @override
  void dispose() {
    _productController.removeListener(_onProductSearchChanged);
    _countController.removeListener(_recalculateTotals);
    _weightController.removeListener(_recalculateTotals);
    _productFocusNode.dispose();
    _productController.dispose();
    _countController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final storage = context.read<OfflineStorage>();
    try {
      final locations = await storage.getLocations();
      final inventory = await storage.getAllInventory();
      final currentAudit = await storage.getCurrentAudit();

      setState(() {
        _locations = locations;
        _inventory = inventory;
        _filteredProducts = inventory;
        _selectedAudit = currentAudit?['Audit ID']?.toString();
      });

      if (_isEditMode) {
        await _loadExistingData(widget.existingCount!, inventory);
      }
      else {
        if (widget.initialProduct != null) {
          _selectProductFromList(widget.initialProduct!);
        }
        if (widget.initialLocation != null) {
          _selectedLocation = widget.initialLocation;
        }
      }

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadExistingData(Map<String, dynamic> data, List<Map<String, dynamic>> inventory) async {
    final barcode = data['barcode']?.toString() ?? '';
    final name = data['productName']?.toString() ?? '';
    Map<String, dynamic>? product;
    if (barcode.isNotEmpty) {
      product = inventory.firstWhere((i) => i['Barcode']?.toString() == barcode, orElse: () => {});
    }
    if ((product == null || product.isEmpty) && name.isNotEmpty) {
      product = inventory.firstWhere((i) => i['Inventory Product Name']?.toString() == name, orElse: () => {});
    }
    setState(() {
      _selectedProduct = product;
      _selectedBarcode = barcode;
      _productController.text = name;
      _selectedLocation = data['location']?.toString();
      _selectedPackSize = data['pack_size']?.toString();

      if (_selectedPackSize == 'Loose' && !_isTobaccoCategory(product) && !_isFoodCategory(product)) {
        _selectedPackSize = 'Case 1';
      }

      // Restore Mode if saved (you might want to add 'counting_method' to DB schema later)
      // For now, infer: if product has gradient, assume Weight. If Spirit, assume Shots.
      _determineDefaultMeasurementMode(product);

      _countController.text = data['count']?.toString() ?? '0';
      _weightController.text = data['weight']?.toString() ?? '0';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _recalculateTotals());
  }

  bool _isFoodCategory(Map<String, dynamic>? product) {
    if (product == null) return false;
    final cat = product['Category']?.toString().toLowerCase() ?? '';
    final mainCat = product['Main Category']?.toString().toLowerCase() ?? '';
    const foodTerms = ['meat', 'poultry', 'seafood', 'dairy', 'vegetables', 'fruit', 'dry goods', 'spices', 'bakery', 'prepared food', 'perishables', 'pantry', 'proteins', 'consumables', 'food'];
    return foodTerms.contains(cat) || foodTerms.contains(mainCat);
  }

  bool _isTobaccoCategory(Map<String, dynamic>? product) {
    if (product == null) return false;
    final cat = product['Category']?.toString().toLowerCase() ?? '';
    final mainCat = product['Main Category']?.toString().toLowerCase() ?? '';
    return ['cigars', 'cigarettes', 'tobacco'].contains(cat) || ['cigars', 'cigarettes', 'tobacco'].contains(mainCat);
  }

  List<String> _getFilteredPackSizes() {
    if (_selectedProduct == null) return _drinkPackSizes;
    if (_isFoodCategory(_selectedProduct)) return _foodPackSizes;
    if (_isTobaccoCategory(_selectedProduct)) return _tobaccoPackSizes;
    return _drinkPackSizes;
  }

  void _onProductSearchChanged() {
    if (_isEditMode) return;
    final query = _productController.text.toLowerCase();
    if (query.isEmpty) {
      setState(() {
        _filteredProducts = _inventory;
        _showProductSuggestions = false;
      });
      return;
    }
    setState(() {
      _filteredProducts = _inventory.where((product) {
        final barcode = product['Barcode']?.toString().toLowerCase() ?? '';
        final productName = product['Inventory Product Name']?.toString().toLowerCase() ?? '';
        return barcode.contains(query) || productName.contains(query);
      }).toList();
      _showProductSuggestions = _filteredProducts.isNotEmpty;
    });
  }

  // --- NEW: DETERMINE DEFAULT MODE ---
  void _determineDefaultMeasurementMode(Map<String, dynamic>? product) {
    if (product == null) return;

    double gradient = _safeDouble(product['Gradient']);
    String mainCat = product['Main Category']?.toString().toLowerCase() ?? '';
    String cat = product['Category']?.toString().toLowerCase() ?? '';

    if (gradient != 0) {
      _measurementType = 'Weight'; // Has scale data -> Weight
    } else if (mainCat.contains('spirit') || cat.contains('whiskey') || cat.contains('vodka') || cat.contains('gin') || cat.contains('tequila')) {
      _measurementType = 'Shots'; // Spirit -> Default to Shots
    } else {
      _measurementType = 'Volume'; // Default -> mL
    }
  }

  Future<void> _scanBarcode() async {
    final barcode = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const BarcodeScannerModal(),
    );
    if (barcode != null && barcode.isNotEmpty) {
      await _selectProductByBarcode(barcode);
    }
  }

  Future<void> _selectProductByBarcode(String barcode) async {
    final storage = context.read<OfflineStorage>();
    var product = await storage.getInventoryItem(barcode);
    if (product != null) {
      _selectProductFromList(product);
      return;
    }
    product = await storage.getMasterCatalogItem(barcode);
    if (product != null) {
      if (!mounted) return;
      bool confirm = await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Found in Master Catalog'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Name: ${product?['Inventory Product Name']}'),
              Text('Size: ${product?['Single Unit Volume']} ${product?['UoM']}'),
              const Divider(),
              const Text('Add this product to your Store Inventory?'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add & Count')),
          ],
        ),
      ) ?? false;
      if (confirm) {
        await storage.importFromMasterToLocal(product!);
        final newInv = await storage.getAllInventory();
        setState(() => _inventory = newInv);
        _selectProductFromList(product!);
      }
      return;
    }
    _openManualAdd(initialBarcode: barcode);
  }

  Future<void> _openManualAdd({String? initialBarcode}) async {
    final storeName = context.read<StoreManager>().activeStore?['name'] ?? 'Unknown Store';
    final newProduct = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddProductScreen(
          initialBarcode: initialBarcode,
          initialName: _productController.text,
        ),
      ),
    );
    if (newProduct != null && newProduct is Map<String, dynamic>) {
      newProduct['storeName'] = storeName;
      await context.read<OfflineStorage>().saveNewLocalProduct(newProduct);
      _selectProductFromList(newProduct);
    }
  }

  bool _isWeightBased(String? packSize) {
    return packSize == 'Open Bottle' || packSize == 'Loose (kg)' || packSize == 'Loose (g)';
  }

  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  // --- UPDATED RECALCULATE LOGIC FOR SHOTS ---
  void _recalculateTotals() {
    if (_selectedPackSize == null) return;

    double count = double.tryParse(_countController.text) ?? 0.0;
    double inputVal = double.tryParse(_weightController.text) ?? 0.0; // Acts as Weight, Shots, or Vol

    double singleUnitSize = _safeDouble(_selectedProduct?['Single Unit Volume']);
    double costPrice = _safeDouble(_selectedProduct?['Cost Price']);
    double gradient = _safeDouble(_selectedProduct?['Gradient']);
    double intercept = _safeDouble(_selectedProduct?['Intercept']);

    // Attempt to get Bottle UoM (Sales Unit), default to 30 (Spirits standard)
    double bottleUoM = _safeDouble(_selectedProduct?['Bottle UoM']);
    if (bottleUoM == 0) bottleUoM = (singleUnitSize > 0) ? (singleUnitSize / 25.0) : 30.0;

    double calculatedWeightOrVol = 0.0;
    double totalUnits = 0.0;
    double finalOpenTots = 0.0;

    if (_selectedPackSize == 'Open Bottle') {

      if (_measurementType == 'Shots') {
        // --- MANUAL SHOT COUNT ---
        // Input is "Number of Shots"
        finalOpenTots = inputVal;
        calculatedWeightOrVol = inputVal * 25.0; // Total mL
        totalUnits = finalOpenTots / bottleUoM; // Total Bottles

      } else if (_measurementType == 'Volume') {
        // --- MEASURE BY ML ---
        // Input is "mL"
        calculatedWeightOrVol = inputVal;
        finalOpenTots = inputVal / 25.0;
        totalUnits = finalOpenTots / bottleUoM;

      } else {
        // --- WEIGHT (GRADIENT) ---
        // Input is "Grams"
        if (gradient != 0 || intercept != 0) {
          calculatedWeightOrVol = (gradient * inputVal) + intercept;
        } else {
          calculatedWeightOrVol = inputVal;
        }
        if (calculatedWeightOrVol < 0) calculatedWeightOrVol = 0;

        finalOpenTots = calculatedWeightOrVol / 25.0;
        totalUnits = finalOpenTots / bottleUoM;
      }

    } else if (_selectedPackSize == 'Loose (kg)') {
      calculatedWeightOrVol = inputVal * 1000;
      totalUnits = inputVal;

    } else if (_selectedPackSize == 'Loose (g)') {
      calculatedWeightOrVol = inputVal;
      totalUnits = inputVal / 1000;

    } else {
      // --- STANDARD PACK LOGIC ---
      double multiplier = 0;
      switch (_selectedPackSize) {
        case "Pack": multiplier = 1; break;
        case "Box": multiplier = 1; break;
        case "Each": multiplier = 1; break;
        case "Portion": multiplier = 1; break;
        case "Loose": multiplier = 1; break;
        case "Pack 10": multiplier = 10; break;
        case "Pack 20": multiplier = 20; break;
        case "Carton": multiplier = 200; break;
        case "Case 1": multiplier = 1; break;
        case "Case 2": multiplier = 2; break;
        case "Case 4": multiplier = 4; break;
        case "Case 6": multiplier = 6; break;
        case "Case 12": multiplier = 12; break;
        case "Case 24": multiplier = 24; break;
        case "Case 36": multiplier = 36; break;
        case "Case 48": multiplier = 48; break;
        case "Keg 1": multiplier = 1000; break;
        case "5 Ltr Cartons": multiplier = 5000; break;
        case "10 Ltr Cartons": multiplier = 10000; break;
        default: multiplier = 1;
      }
      totalUnits = count * multiplier;
      calculatedWeightOrVol = totalUnits * singleUnitSize;
    }

    double costValue = totalUnits * costPrice;

    setState(() {
      _calcVolumeMl = calculatedWeightOrVol;
      _calcOpenTots = finalOpenTots;
      _calcTotalBottles = totalUnits;
      _calcTotalMl = calculatedWeightOrVol;
      _calcCostValue = costValue;
    });
  }

  void _selectProductFromList(Map<String, dynamic> product) {
    setState(() {
      _selectedProduct = product;
      _selectedBarcode = product['Barcode']?.toString() ?? '';
      _productController.text = product['Inventory Product Name']?.toString() ?? '';
      _showProductSuggestions = false;

      final validPackSizes = _getFilteredPackSizes();
      if (_selectedPackSize != null && !validPackSizes.contains(_selectedPackSize)) {
        _selectedPackSize = null;
      }

      // Reset logic
      _countController.text = '0';
      _weightController.text = '0';

      // Determine Measurement Mode Default
      _determineDefaultMeasurementMode(product);
    });
    _productFocusNode.unfocus();
  }

  // ... (Delete and Save remain the same) ...
  Future<void> _deleteEntry() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry?'),
        content: const Text('This will remove this count permanently from the device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await context.read<OfflineStorage>().deleteStockCount(widget.existingCount!['id']);
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _saveCount() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedLocation == null && widget.initialLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Missing Location')));
      return;
    }
    if (_selectedPackSize == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Missing Pack Size')));
      return;
    }
    _recalculateTotals();

    final storage = context.read<OfflineStorage>();
    final id = _isEditMode ? widget.existingCount!['id'] : DateTime.now().millisecondsSinceEpoch.toString();
    final stockId = _isEditMode ? widget.existingCount!['stock_id'] : id;

    final dateToUse = _isEditMode
        ? widget.existingCount!['date']
        : (widget.initialDate != null
        ? widget.initialDate!.toIso8601String().split('T')[0]
        : DateTime.now().toIso8601String().split('T')[0]);

    final createdDate = _isEditMode ? widget.existingCount!['createdAt'] : DateTime.now().toIso8601String();

    final countData = {
      'id': id,
      'stock_id': stockId,
      'date': dateToUse,
      'barcode': _selectedBarcode,
      'productName': _selectedProduct?['Inventory Product Name'] ?? _productController.text,
      'mainCategory': _selectedProduct?['Main Category'] ?? '',
      'category': _selectedProduct?['Category'] ?? '',
      'singleUnitVolume': _safeDouble(_selectedProduct?['Single Unit Volume']),
      'uom': _selectedProduct?['UoM'] ?? '',
      'gradient': _safeDouble(_selectedProduct?['Gradient']),
      'intercept': _safeDouble(_selectedProduct?['Intercept']),
      'location': widget.initialLocation ?? _selectedLocation!,
      'pack_size': _selectedPackSize,
      'count': int.tryParse(_countController.text) ?? 0,
      'weight': double.tryParse(_weightController.text) ?? 0.0,
      'volume_ml': _calcVolumeMl,
      'open_tots': _calcOpenTots,
      'total_bottles': _calcTotalBottles,
      'total_ml': _calcTotalMl,
      'cost_value': _calcCostValue,
      'createdAt': createdDate,
      'updatedAt': DateTime.now().toIso8601String(),
      'auditId': _selectedAudit,
    };

    try {
      if (_isEditMode) {
        await storage.updateStockCount(countData);
        context.read<LoggerService>().info('Updated: ${_productController.text} ($id)');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry Updated'), backgroundColor: Colors.blue));
          Navigator.pop(context);
        }
      } else {
        await storage.saveStockCount(countData);
        context.read<LoggerService>().info('Saved: ${_productController.text} ($id)');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved: $_calcTotalBottles Bottles'), backgroundColor: Colors.green));
          _clearForm();
        }
      }
    } catch (e) {
      context.read<LoggerService>().error('Save Failed', e);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  void _clearForm() {
    if (widget.initialProduct != null) {
      _countController.text = '0';
      _weightController.text = '0';
      setState(() {
        _calcVolumeMl = 0;
        _calcTotalBottles = 0;
        _calcCostValue = 0;
      });
    } else {
      _productController.clear();
      _countController.text = '0';
      _weightController.text = '0';
      _selectedBarcode = null;
      _selectedProduct = null;
      _selectedPackSize = null;
      setState(() {
        _calcVolumeMl = 0;
        _calcTotalBottles = 0;
        _calcCostValue = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final costPrice = _safeDouble(_selectedProduct?['Cost Price']);
    final currentPackSizes = _getFilteredPackSizes();

    bool isSameDay = false;
    if (widget.initialDate != null) {
      final now = DateTime.now();
      isSameDay = now.year == widget.initialDate!.year &&
          now.month == widget.initialDate!.month &&
          now.day == widget.initialDate!.day;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditMode ? 'Edit Count' : 'New Count'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: IconButton.filled(
              onPressed: _saveCount,
              icon: const Icon(Icons.check),
              tooltip: 'Save Count',
              style: IconButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
            ),
          ),
          if (_isEditMode)
            IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: _deleteEntry, tooltip: 'Delete Entry'),
        ],
      ),
      body: GestureDetector(
        onTap: () {
          if (_showProductSuggestions) setState(() => _showProductSuggestions = false);
          FocusScope.of(context).unfocus();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                if (widget.initialDate != null && !_isEditMode)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                        color: isSameDay ? Colors.blue.shade50 : Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: isSameDay ? Colors.blue : Colors.orange)
                    ),
                    child: Row(
                      children: [
                        Icon(isSameDay ? Icons.calendar_today : Icons.history, color: isSameDay ? Colors.blue : Colors.orange),
                        const SizedBox(width: 8),
                        Text(
                            isSameDay ? 'Adding Entry for: ' : 'Backdating Entry to: ',
                            style: TextStyle(fontWeight: FontWeight.bold, color: isSameDay ? Colors.blue[900] : Colors.orange[900])
                        ),
                        Text(DateFormat('dd MMM yyyy').format(widget.initialDate!), style: TextStyle(color: isSameDay ? Colors.blue[900] : Colors.orange[900])),
                      ],
                    ),
                  ),

                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _productController,
                        focusNode: _productFocusNode,
                        readOnly: _isEditMode || widget.initialProduct != null,
                        decoration: InputDecoration(
                          labelText: 'Product',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.inventory),
                          suffixIcon: (_isEditMode || widget.initialProduct != null)
                              ? const Icon(Icons.lock, color: Colors.grey)
                              : IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: _scanBarcode),
                        ),
                        onTap: () {
                          if (!_isEditMode && widget.initialProduct == null && _productController.text.isNotEmpty) {
                            setState(() => _showProductSuggestions = true);
                          }
                        },
                      ),
                    ),
                    if (!_isEditMode && widget.initialProduct == null) ...[
                      const SizedBox(width: 8),
                      IconButton.filled(icon: const Icon(Icons.add), tooltip: 'Manual Entry', onPressed: _openManualAdd),
                    ],
                  ],
                ),
                if (_showProductSuggestions && _filteredProducts.isNotEmpty)
                  Card(
                    elevation: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _filteredProducts.length,
                        itemBuilder: (ctx, i) {
                          final p = _filteredProducts[i];
                          return ListTile(
                            title: Text(p['Inventory Product Name']?.toString() ?? ''),
                            subtitle: Text(p['Barcode']?.toString() ?? ''),
                            onTap: () => _selectProductFromList(p),
                          );
                        },
                      ),
                    ),
                  ),
                const SizedBox(height: 16),

                if (_selectedProduct != null)
                  Card(
                    color: Colors.blue.shade50,
                    elevation: 2,
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Product Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blue)),
                          const Divider(color: Colors.blue),
                          _buildDetailRow('Name', _selectedProduct!['Inventory Product Name']),
                          _buildDetailRow('Category', _selectedProduct!['Category']),
                          _buildDetailRow('Volume', '${_selectedProduct!['Single Unit Volume']} ${_selectedProduct!['UoM']}'),
                          _buildDetailRow('Unit Cost', NumberFormat.simpleCurrency().format(costPrice)),
                        ],
                      ),
                    ),
                  ),

                // --- LOCKABLE LOCATION ---
                widget.initialLocation != null
                    ? TextFormField(
                  initialValue: widget.initialLocation,
                  readOnly: true,
                  decoration: const InputDecoration(labelText: 'Location', border: OutlineInputBorder(), prefixIcon: Icon(Icons.location_on), suffixIcon: Icon(Icons.lock, color: Colors.grey), filled: true, fillColor: Color(0xFFEEEEEE)),
                )
                    : DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Location', border: OutlineInputBorder()),
                  value: _selectedLocation,
                  isExpanded: true,
                  items: _locations.map((l) => DropdownMenuItem(value: l['Location']?.toString(), child: Text(l['Location']?.toString() ?? ''))).toList(),
                  onChanged: (val) => setState(() => _selectedLocation = val),
                ),

                const SizedBox(height: 16),

                // --- PACK SIZE ---
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'Pack Size', border: OutlineInputBorder()),
                  value: _selectedPackSize,
                  isExpanded: true,
                  items: currentPackSizes.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                  onChanged: (val) {
                    setState(() {
                      _selectedPackSize = val;
                      if (_isWeightBased(val)) _countController.text = '0'; else _weightController.text = '0';
                    });
                    _recalculateTotals();
                  },
                ),
                const SizedBox(height: 16),

                // --- NEW: MODE SELECTOR FOR OPEN BOTTLE ---
                if (_selectedPackSize == 'Open Bottle')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SegmentedButton<String>(
                      segments: [
                        const ButtonSegment(value: 'Shots', label: Text('Shots'), icon: Icon(Icons.local_bar)),
                        const ButtonSegment(value: 'Volume', label: Text('mL'), icon: Icon(Icons.water_drop)),
                        // Only show Weight if gradient exists
                        if (_safeDouble(_selectedProduct?['Gradient']) != 0)
                          const ButtonSegment(value: 'Weight', label: Text('Grams'), icon: Icon(Icons.scale)),
                      ],
                      selected: {_measurementType},
                      onSelectionChanged: (Set<String> newSelection) {
                        setState(() {
                          _measurementType = newSelection.first;
                          _weightController.clear();
                        });
                        _recalculateTotals();
                      },
                    ),
                  ),

                // --- DYNAMIC INPUT ROW ---
                Row(
                  children: [
                    if (!_isWeightBased(_selectedPackSize))
                      Expanded(
                          child: TextFormField(
                              controller: _countController,
                              decoration: const InputDecoration(labelText: 'Count (Units)', border: OutlineInputBorder()),
                              keyboardType: TextInputType.number
                          )
                      ),

                    if (!_isWeightBased(_selectedPackSize)) const SizedBox(width: 16),

                    if (_isWeightBased(_selectedPackSize))
                      Expanded(
                          child: TextFormField(
                              controller: _weightController,
                              decoration: InputDecoration(
                                // Update label based on Mode
                                  labelText: _selectedPackSize == 'Open Bottle'
                                      ? (_measurementType == 'Shots' ? 'Number of Shots' : (_measurementType == 'Volume' ? 'Volume (mL)' : 'Weight (g)'))
                                      : 'Net Weight',
                                  border: const OutlineInputBorder()
                              ),
                              keyboardType: TextInputType.number
                          )
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                if (_selectedProduct != null)
                  Card(
                    color: Colors.green.shade50,
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          const Text('CALCULATED TOTALS', style: TextStyle(fontWeight: FontWeight.bold)),
                          const Divider(),
                          if (_selectedPackSize == 'Open Bottle') ...[
                            _buildSummaryRow('Calc Volume:', '${_calcVolumeMl.toStringAsFixed(1)} ml'),
                            _buildSummaryRow('Open Tots:', _calcOpenTots.toStringAsFixed(2)),
                          ],
                          _buildSummaryRow('Total Bottles/Units:', _calcTotalBottles.toStringAsFixed(2)),
                          _buildSummaryRow('Total Value:', NumberFormat.simpleCurrency().format(_calcCostValue), isTotal: true),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Helpers...
  Widget _buildDetailRow(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text('$label:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Colors.grey[700]))),
          Expanded(child: Text(value?.toString() ?? '-', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontWeight: isTotal ? FontWeight.bold : FontWeight.normal)),
          Text(value, style: TextStyle(fontWeight: isTotal ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }
}