import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../widgets/count_location_field.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/store_manager.dart';
import '../services/logger_service.dart';
import '../widgets/barcode_scanner.dart';
import 'add_product_screen.dart';
import 'package:intl/intl.dart';
import '../services/stock_record_fields.dart';

// ============================================================================
// 🔥 PURE PRICING RESOLVER - Testable, decoupled from UI
// ============================================================================

class PricingResolutionResult {
  final double unitCost;
  final double unitRetail;
  final bool costFellBack;
  final bool retailFellBack;

  const PricingResolutionResult({
    required this.unitCost,
    required this.unitRetail,
    this.costFellBack = false,
    this.retailFellBack = false,
  });

  /// Describes fallback decisions for logging
  String describeFallback(String productName) {
    final parts = <String>[];
    if (costFellBack) parts.add('cost from retail/3');
    if (retailFellBack) parts.add('retail from cost×3');
    if (parts.isEmpty) return '$productName: no fallback needed';
    return '$productName: ${parts.join(', ')}';
  }
}

class PricingResolver {
  /// Resolve unit cost and retail price for a product
  /// Uses precomputed sales index for O(1) lookup
  static PricingResolutionResult resolve({
    required Map<String, dynamic> product,
    required Map<String, double> salesIndex,
  }) {
    final name =
        product['Inventory Product Name']?.toString().toLowerCase().trim() ??
            '';
    double unitCost = _safeDouble(product['Cost Price']);
    double unitRetail = salesIndex[name] ?? 0.0;
    bool costFellBack = false;
    bool retailFellBack = false;

    // Mirrors GAS recalculateStoreValues() exactly — mutually exclusive by construction.
    // Only apply fallback when ONE of the values is missing, not both.
    if (unitCost > 0 && unitRetail == 0.0) {
      unitRetail = unitCost * 3;
      retailFellBack = true;
    } else if (unitRetail > 0 && unitCost == 0.0) {
      unitCost = unitRetail / 3;
      costFellBack = true;
    }
    // If both are 0, leave them as 0 (no fallback applied)

    return PricingResolutionResult(
      unitCost: unitCost,
      unitRetail: unitRetail,
      costFellBack: costFellBack,
      retailFellBack: retailFellBack,
    );
  }

  static double _safeDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is int) return v.toDouble();
    if (v is double) return v;
    return double.tryParse(v.toString()) ?? 0.0;
  }
}

// ============================================================================
// COUNT SCREEN STATE
// ============================================================================

class CountScreen extends StatefulWidget {
  final Map<String, dynamic>? existingCount;
  final Map<String, dynamic>? initialProduct;
  final DateTime? initialDate;
  final String? initialLocation;
  final LoggerService? logger; // 🔥 Constructor injection

  const CountScreen({
    super.key,
    this.existingCount,
    this.initialProduct,
    this.initialDate,
    this.initialLocation,
    this.logger,
  });

  @override
  State<CountScreen> createState() => _CountScreenState();
}

class _CountScreenState extends State<CountScreen> {
  // ============================================================================
  // CONTROLLERS & FORM
  // ============================================================================

  final _formKey = GlobalKey<FormState>();
  final _productController = TextEditingController();
  final _countController = TextEditingController(text: '0');
  final _weightController = TextEditingController(text: '0');

  String _measurementType = 'Volume';

  final List<String> _drinkPackSizes = [
    'Open Bottle',
    'Case 1',
    'Case 4',
    'Case 6',
    'Case 12',
    'Case 24',
    'Case 36',
    'Case 48',
    'Keg 1',
    '5 Ltr Cartons',
    '10 Ltr Cartons',
  ];

  final List<String> _foodPackSizes = [
    'Loose (kg)',
    'Loose (g)',
    'Each',
    'Portion',
    'Pack',
    'Box',
    'Case 1',
    'Case 6',
    'Case 12',
    'Case 24',
  ];

  final List<String> _tobaccoPackSizes = [
    'Loose',
    'Pack 10',
    'Pack 20',
    'Carton',
    'Case 1',
  ];

  // ============================================================================
  // STATE - Data
  // ============================================================================

  String? _selectedLocation;
  String? _selectedAudit;
  String? _selectedPackSize;

  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _inventory = [];
  List<Map<String, dynamic>> _itemSalesRaw =
  []; // 🔥 Keep raw for index rebuild
  bool _isLoading = true;
  bool _isEditMode = false;

  String? _selectedBarcode;
  Map<String, dynamic>? _selectedProduct;
  List<Map<String, dynamic>> _filteredProducts = [];
  bool _showProductSuggestions = false;
  final FocusNode _productFocusNode = FocusNode();

  // ============================================================================
  // 🔥 CACHED PRICING VALUES (resolved once per product selection)
  // ============================================================================

  double _resolvedUnitCost = 0.0;
  double _resolvedUnitRetail = 0.0;
  bool _costFellBack = false;
  bool _retailFellBack = false;

  // ============================================================================
  // 🔥 PRECOMPUTED SALES PRICE INDEX (built once when sales data loads)
  // ============================================================================

  Map<String, double> _salesPriceIndex = {};

  // ============================================================================
  // CALCULATED VALUES (recalculated cheaply on keystroke)
  // ============================================================================

  double _calcVolumeMl = 0.0;
  double _calcOpenTots = 0.0;
  double _calcTotalBottles = 0.0;
  double _calcTotalMl = 0.0;
  double _calcCostValue = 0.0;
  double _calcRetailValue = 0.0;

  // ============================================================================
  // CONTEXT DATA
  // ============================================================================

  double _todayTotalAcrossAllLocs = 0.0;
  List<Map<String, dynamic>> _historyStats = [];

  // ============================================================================
  // REGEX & HELPERS
  // ============================================================================

  final RegExp _exclusionRegex = RegExp(
    r'Special Shooter|Special Beverage|Cocktail Ingredient|Special Tot|Special Spirit Bottle|Special Alcoholic Beverage',
    caseSensitive: false,
  );

  // 🔥 FIX: Use injected logger from widget
  LoggerService? get _logger => widget.logger;

  // ============================================================================
  // LIFECYCLE
  // ============================================================================

  @override
  void initState() {
    super.initState();
    _isEditMode = widget.existingCount != null;
    _loadData();

    if (!_isEditMode) {
      _productController.addListener(_onProductSearchChanged);
    }
    _countController.addListener(_onValueChanged);
    _weightController.addListener(_onValueChanged);
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
    _countController.removeListener(_onValueChanged);
    _weightController.removeListener(_onValueChanged);
    _productFocusNode.dispose();
    _productController.dispose();
    _countController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  // ============================================================================
  // 🔥 KEYSTROKE HANDLER - Now does ONLY cheap arithmetic
  // ============================================================================

  void _onValueChanged() {
    _recalculateTotals();
  }

  // ============================================================================
  // DATA LOADING
  // ============================================================================

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    final storage = context.read<OfflineStorage>();
    try {
      final locations = await storage.getLocations();
      final inventory = await storage.getAllInventory();
      final currentAudit = await storage.getCurrentAudit();
      final itemSales = await storage.getItemSalesMap();

      // 🔥 Store raw sales data for later index rebuilds
      _itemSalesRaw = itemSales;

      // 🔥 Build the sales price index ONCE when data loads
      _salesPriceIndex = _buildSalesPriceIndex(itemSales, inventory);

      if (!mounted) return;
      setState(() {
        _locations = locations;
        _inventory = inventory;
        _filteredProducts = inventory;
        _selectedAudit = currentAudit?['Audit ID']?.toString();
      });

      if (_isEditMode) {
        await _loadExistingData(widget.existingCount!, inventory);
      } else {
        if (widget.initialProduct != null) {
          _selectProductFromList(widget.initialProduct!);
        }
        if (widget.initialLocation != null) {
          _selectedLocation = widget.initialLocation;
        }
      }

      if (!mounted) return;
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadExistingData(Map<String, dynamic> data, List<Map<String, dynamic>> inventory) async {
    data = normalizeStockRecord(data);
    final barcode = data['barcode']?.toString() ?? '';
    final name = data['productName']?.toString() ?? '';
    Map<String, dynamic>? product;
    if (barcode.isNotEmpty) {
      product = inventory.firstWhere((i) => i['Barcode']?.toString() == barcode, orElse: () => {});
    }
    if ((product == null || product.isEmpty) && name.isNotEmpty) {
      product = inventory.firstWhere((i) => i['Inventory Product Name']?.toString() == name, orElse: () => {});
    }

    product = stockProductForEdit(data, product);

    if (!mounted) return;
    setState(() {
      _selectedProduct = product;
      _selectedBarcode = barcode;
      _productController.text = name;
      _selectedLocation = data['location']?.toString();
      _selectedPackSize = data['pack_size']?.toString();

      if (_selectedPackSize == 'Loose' && !_isTobaccoCategory(product) && !_isFoodCategory(product)) {
        _selectedPackSize = 'Case 1';
      }

      _determineDefaultMeasurementMode(product);

      _countController.text = data['count']?.toString() ?? '0';
      _weightController.text = data['weight']?.toString() ?? '0';
    });

    // 🔥 Resolve pricing once for this product
    _resolveProductPricing();

    _loadContextData();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recalculateTotals();
    });
  }

  Future<void> _loadContextData() async {
    if (_selectedProduct == null) return;

    final storage = context.read<OfflineStorage>();
    final productName =
        _selectedProduct!['Inventory Product Name']?.toString() ?? '';

    final allCounts = await storage.getStockCounts();
    final productCounts = allCounts
        .where(
          (c) =>
      c['productName'] == productName && c['syncStatus'] != 'deleted',
    )
        .toList();

    final dateToUse = widget.initialDate ?? DateTime.now();
    final dateStr = dateToUse.toIso8601String().split('T')[0];

    double todaySum = 0.0;
    for (var c in productCounts) {
      if (c['date'].toString().startsWith(dateStr)) {
        todaySum += _safeDouble(c['total_bottles']);
      }
    }

    final Map<String, double> historyMap = {};
    for (var c in productCounts) {
      final d = c['date'].toString().split('T')[0];
      if (d == dateStr) continue;

      if (!historyMap.containsKey(d)) historyMap[d] = 0.0;
      historyMap[d] = historyMap[d]! + _safeDouble(c['total_bottles']);
    }

    final sortedKeys = historyMap.keys.toList()..sort((a, b) => b.compareTo(a));
    final historyList = sortedKeys
        .take(3)
        .map((k) => {'date': k, 'total': historyMap[k]})
        .toList();

    if (!mounted) return;
    setState(() {
      _todayTotalAcrossAllLocs = todaySum;
      _historyStats = historyList;
    });
  }

  // ============================================================================
  // 🔥 REBUILD SALES PRICE INDEX - Call whenever inventory changes
  // ============================================================================

  void _rebuildSalesPriceIndex() {
    _salesPriceIndex = _buildSalesPriceIndex(_itemSalesRaw, _inventory);
  }

  Map<String, double> _buildSalesPriceIndex(
      List<Map<String, dynamic>> itemSalesData,
      List<Map<String, dynamic>> inventory,
      ) {
    final priorityMap = <String, int>{
      'spirit bottle': 1,
      'fermented wine': 2,
      'spirit tot': 3,
      'fermented wine glass': 4,
      'mixer bottle': 5,
      'mixer tot': 6,
      'beverage': 7,
    };
    const int defaultPriority = 99;

    final bestPriority = <String, int>{};
    final index = <String, double>{};

    // Build a quick lookup map for inventory by product name
    final inventoryByName = <String, Map<String, dynamic>>{};
    for (var p in inventory) {
      final name =
          p['Inventory Product Name']?.toString().toLowerCase().trim() ?? '';
      if (name.isNotEmpty && !inventoryByName.containsKey(name)) {
        inventoryByName[name] = p;
      }
    }

    for (var row in itemSalesData) {
      final name = row['Product']?.toString().toLowerCase().trim() ?? '';
      if (name.isEmpty) continue;

      final mainCat =
          row['Main Category']?.toString().toLowerCase().trim() ?? '';
      if (_exclusionRegex.hasMatch(mainCat)) continue;

      final sellPrice = _safeDouble(row['Sell']);
      if (sellPrice <= 0) continue;

      // Find product in inventory
      final matchedProduct = inventoryByName[name];
      if (matchedProduct == null) continue;

      double bottleUoM = _safeDouble(matchedProduct['Bottle UoM']);
      double singleUoM = _safeDouble(matchedProduct['Single UoM']);
      if (bottleUoM == 0) {
        final vol = _safeDouble(matchedProduct['Single Unit Volume']);
        bottleUoM = vol > 0 ? vol / 25.0 : 30.0;
      }
      if (singleUoM == 0) singleUoM = 1.0;

      final measure = row['Measure']?.toString().toLowerCase() ?? '';
      double impliedPrice;
      if (measure.contains('bottle') || measure.contains('can')) {
        impliedPrice = sellPrice;
      } else if (measure.contains('shots') || measure.contains('tot')) {
        impliedPrice = sellPrice * bottleUoM;
      } else if (measure.contains('glass')) {
        impliedPrice = sellPrice / singleUoM;
      } else {
        impliedPrice = sellPrice;
      }

      final priority = priorityMap[mainCat] ?? defaultPriority;
      if (!bestPriority.containsKey(name) || priority < bestPriority[name]!) {
        index[name] = impliedPrice;
        bestPriority[name] = priority;
      }
    }

    return index;
  }

  // ============================================================================
  // 🔥 RESOLVE PRODUCT PRICING - Called once per product selection
  // 🔥 FIX: Uses setState() so it's correct in isolation
  // 🔥 FIX: Guarded with mounted checks for async safety
  // ============================================================================

  void _resolveProductPricing() {
    if (_selectedProduct == null) {
      if (!mounted) return;
      setState(() {
        _resolvedUnitCost = 0.0;
        _resolvedUnitRetail = 0.0;
        _costFellBack = false;
        _retailFellBack = false;
      });
      return;
    }

    final result = PricingResolver.resolve(
      product: _selectedProduct!,
      salesIndex: _salesPriceIndex,
    );

    final saved = widget.existingCount;
    final recordedCost = saved == null ? null : stockRecordedUnitValue(saved, 'cost_value');
    final recordedRetail = saved == null ? null : stockRecordedUnitValue(saved, 'retail_value');
    if (!mounted) return;
    setState(() {
      _resolvedUnitCost = recordedCost ?? result.unitCost;
      _resolvedUnitRetail = recordedRetail ?? result.unitRetail;
      _costFellBack = result.costFellBack;
      _retailFellBack = result.retailFellBack;
    });

    // 🔥 Log fallback ONCE when product is selected, not on every keystroke
    if (result.costFellBack || result.retailFellBack) {
      final name = _selectedProduct!['Inventory Product Name']?.toString() ?? 'Unknown';
      _logger?.info('💰 ${result.describeFallback(name)}');
    }
  }
  // ============================================================================
  // CATEGORY HELPERS
  // ============================================================================

  bool _isFoodCategory(Map<String, dynamic>? product) {
    if (product == null) return false;
    final cat = product['Category']?.toString().toLowerCase() ?? '';
    final mainCat = product['Main Category']?.toString().toLowerCase() ?? '';
    const foodTerms = [
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
      'perishables',
      'pantry',
      'proteins',
      'consumables',
      'food',
    ];
    return foodTerms.contains(cat) || foodTerms.contains(mainCat);
  }

  bool _isTobaccoCategory(Map<String, dynamic>? product) {
    if (product == null) return false;
    final cat = product['Category']?.toString().toLowerCase() ?? '';
    final mainCat = product['Main Category']?.toString().toLowerCase() ?? '';
    return ['cigars', 'cigarettes', 'tobacco'].contains(cat) ||
        ['cigars', 'cigarettes', 'tobacco'].contains(mainCat);
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
      if (!mounted) return;
      setState(() {
        _filteredProducts = _inventory;
        _showProductSuggestions = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _filteredProducts = _inventory.where((product) {
        final barcode = product['Barcode']?.toString().toLowerCase() ?? '';
        final productName =
            product['Inventory Product Name']?.toString().toLowerCase() ?? '';
        return barcode.contains(query) || productName.contains(query);
      }).toList();
      _showProductSuggestions = _filteredProducts.isNotEmpty;
    });
  }

  void _determineDefaultMeasurementMode(Map<String, dynamic>? product) {
    if (product == null) return;
    double gradient = _safeDouble(product['Gradient']);
    String mainCat = product['Main Category']?.toString().toLowerCase() ?? '';
    String cat = product['Category']?.toString().toLowerCase() ?? '';

    if (gradient != 0) {
      _measurementType = 'Weight';
    } else if (mainCat.contains('spirit') ||
        cat.contains('whiskey') ||
        cat.contains('vodka') ||
        cat.contains('gin') ||
        cat.contains('tequila')) {
      _measurementType = 'Shots';
    } else {
      _measurementType = 'Volume';
    }
  }

  // ============================================================================
  // BARCODE SCANNING
  // ============================================================================

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
      bool confirm =
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Found in Master Catalog'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Name: ${product?['Inventory Product Name']}'),
                  Text(
                    'Size: ${product?['Single Unit Volume']} ${product?['UoM']}',
                  ),
                  const Divider(),
                  const Text('Add this product to your Store Inventory?'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Add & Count'),
                ),
              ],
            ),
          ) ??
              false;
      if (confirm) {
        await storage.importFromMasterToLocal(product);
        final newInv = await storage.getAllInventory();

        // 🔥 FIX: Rebuild sales index when inventory changes
        if (!mounted) return;
        setState(() {
          _inventory = newInv;
        });
        _rebuildSalesPriceIndex();
        _selectProductFromList(product);
      }
      return;
    }
    _openManualAdd(initialBarcode: barcode);
  }

  Future<void> _openManualAdd({String? initialBarcode}) async {
    final storeName =
        context.read<StoreManager>().activeStore?['name'] ?? 'Unknown Store';
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

      // 🔥 FIX: Rebuild sales index when inventory changes
      final newInv = await context.read<OfflineStorage>().getAllInventory();
      if (!mounted) return;
      setState(() {
        _inventory = newInv;
      });
      _rebuildSalesPriceIndex();
      _selectProductFromList(newProduct);
    }
  }

  bool _isWeightBased(String? packSize) {
    return packSize == 'Open Bottle' ||
        packSize == 'Loose (kg)' ||
        packSize == 'Loose (g)';
  }

  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  // ============================================================================
  // 🔥 RECALCULATE TOTALS - Pure arithmetic with cached prices
  // ============================================================================

  void _recalculateTotals() {
    if (_selectedPackSize == null) return;

    double count = double.tryParse(_countController.text) ?? 0.0;
    double inputVal = double.tryParse(_weightController.text) ?? 0.0;

    double singleUnitSize = _safeDouble(
      _selectedProduct?['Single Unit Volume'],
    );
    double gradient = _safeDouble(_selectedProduct?['Gradient']);
    double intercept = _safeDouble(_selectedProduct?['Intercept']);

    double bottleUoM = _safeDouble(_selectedProduct?['Bottle UoM']);
    if (bottleUoM == 0)
      bottleUoM = (singleUnitSize > 0) ? (singleUnitSize / 25.0) : 30.0;

    double calculatedWeightOrVol = 0.0;
    double totalUnits = 0.0;
    double finalOpenTots = 0.0;

    // --- Volume/Weight calculation ---
    if (_selectedPackSize == 'Open Bottle') {
      if (_measurementType == 'Shots') {
        finalOpenTots = inputVal;
        calculatedWeightOrVol = inputVal * 25.0;
        totalUnits = finalOpenTots / bottleUoM;
      } else if (_measurementType == 'Volume') {
        calculatedWeightOrVol = inputVal;
        finalOpenTots = inputVal / 25.0;
        totalUnits = finalOpenTots / bottleUoM;
      } else {
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
      double multiplier = 0;
      switch (_selectedPackSize) {
        case "Pack":
          multiplier = 1;
          break;
        case "Box":
          multiplier = 1;
          break;
        case "Each":
          multiplier = 1;
          break;
        case "Portion":
          multiplier = 1;
          break;
        case "Loose":
          multiplier = 1;
          break;
        case "Pack 10":
          multiplier = 10;
          break;
        case "Pack 20":
          multiplier = 20;
          break;
        case "Carton":
          multiplier = 200;
          break;
        case "Case 1":
          multiplier = 1;
          break;
        case "Case 2":
          multiplier = 2;
          break;
        case "Case 4":
          multiplier = 4;
          break;
        case "Case 6":
          multiplier = 6;
          break;
        case "Case 12":
          multiplier = 12;
          break;
        case "Case 24":
          multiplier = 24;
          break;
        case "Case 36":
          multiplier = 36;
          break;
        case "Case 48":
          multiplier = 48;
          break;
        case "Keg 1":
          multiplier = 1000;
          break;
        case "5 Ltr Cartons":
          multiplier = 5000;
          break;
        case "10 Ltr Cartons":
          multiplier = 10000;
          break;
        default:
          multiplier = 1;
      }
      totalUnits = count * multiplier;
      calculatedWeightOrVol = totalUnits * singleUnitSize;
    }

    // 🔥 COST & RETAIL: Use cached resolved values (no scan, no fallback logic)
    final unitCost = _resolvedUnitCost;
    final unitRetail = _resolvedUnitRetail;

    final costValue = totalUnits * unitCost;
    final retailValue = totalUnits * unitRetail;

    if (!mounted) return;
    setState(() {
      _calcVolumeMl = calculatedWeightOrVol;
      _calcOpenTots = finalOpenTots;
      _calcTotalBottles = totalUnits;
      _calcTotalMl = calculatedWeightOrVol;
      _calcCostValue = costValue;
      _calcRetailValue = retailValue;
    });
  }

  // ============================================================================
  // PRODUCT SELECTION
  // ============================================================================

  void _selectProductFromList(Map<String, dynamic> product) {
    if (!mounted) return;
    setState(() {
      _selectedProduct = product;
      _selectedBarcode = product['Barcode']?.toString() ?? '';
      _productController.text =
          product['Inventory Product Name']?.toString() ?? '';
      _showProductSuggestions = false;

      final validPackSizes = _getFilteredPackSizes();
      if (_selectedPackSize != null &&
          !validPackSizes.contains(_selectedPackSize)) {
        _selectedPackSize = null;
      }

      _countController.text = '0';
      _weightController.text = '0';

      _determineDefaultMeasurementMode(product);
    });

    // 🔥 Resolve pricing once for this product
    _resolveProductPricing();

    _loadContextData();
    _productFocusNode.unfocus();

    // Recalculate totals with the new product
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recalculateTotals();
    });
  }

  // ============================================================================
  // DELETE ENTRY
  // ============================================================================

  Future<void> _deleteEntry() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry?'),
        content: const Text(
          'This will remove this count permanently from the device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final id = widget.existingCount!['id'];
      final storage = context.read<OfflineStorage>();

      await storage.deleteStockCount(id);

      // 🔥 REAL-TIME SOFT-DELETE ON FIRESTORE
      // (was a hard .delete() before — that raced with the background sync
      // recreating the doc a few seconds later, which is why `deleted`
      // kept reverting to false)
      final syncService = context.read<StoreManager>().syncService;
      if (syncService.firestore != null && storage.firestoreKey != null) {
        final deletedData = <String, dynamic>{
          'id': id,
          'deleted': true,
          'deletedAt': DateTime.now().toIso8601String(),
        };
        await syncService.firestore!.saveStockCount(
          storage.firestoreKey!,
          deletedData,
        );
      }

      if (mounted) Navigator.pop(context);
    }
  }

  // ============================================================================
  // DUPLICATE INTERVENTION & SAVE
  // ============================================================================

  Future<void> _processSave() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedProduct == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a product from the list')),
      );
      return;
    }
    if (_selectedLocation == null && widget.initialLocation == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Missing Location')));
      return;
    }
    if (_selectedPackSize == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Missing Pack Size')));
      return;
    }

    _recalculateTotals();

    if (_isEditMode || _selectedPackSize == 'Open Bottle') {
      await _commitSaveToDB();
      return;
    }

    final storage = context.read<OfflineStorage>();
    final allCounts = await storage.getStockCounts();

    final dateToUse = widget.initialDate != null
        ? widget.initialDate!.toIso8601String().split('T')[0]
        : DateTime.now().toIso8601String().split('T')[0];

    final locationToUse = widget.initialLocation ?? _selectedLocation!;
    final productName =
        _selectedProduct?['Inventory Product Name'] ?? _productController.text;

    try {
      final existingEntry = allCounts.firstWhere(
            (c) =>
        c['date'].toString().startsWith(dateToUse) &&
            c['location'] == locationToUse &&
            c['productName'] == productName &&
            c['pack_size'] == _selectedPackSize &&
            c['syncStatus'] != 'deleted',
      );

      if (mounted) {
        await _showDuplicateInterventionDialog(existingEntry);
      }
    } catch (e) {
      await _commitSaveToDB();
    }
  }

  Future<void> _showDuplicateInterventionDialog(
      Map<String, dynamic> existingEntry,
      ) async {
    final currentCount =
        double.tryParse(existingEntry['count']?.toString() ?? '0') ?? 0.0;
    final newCount = double.tryParse(_countController.text) ?? 0.0;
    final addTotal = currentCount + newCount;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Item Already Counted'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You already have $currentCount ${_selectedPackSize}s here.'),
            const SizedBox(height: 8),
            Text('Do you want to ADD to it, or EDIT (Overwrite) it?'),
            const SizedBox(height: 16),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Add:',
                  style: TextStyle(
                    color: Colors.green[700],
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '$currentCount + $newCount = $addTotal',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Edit:',
                  style: TextStyle(
                    color: Colors.blue[700],
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'New value will be $newCount',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _commitSaveToDB(existingId: existingEntry['id'], isUpdate: true);
            },
            child: const Text('Edit (Overwrite)'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _countController.text = addTotal.toString();
              _recalculateTotals();
              _commitSaveToDB(existingId: existingEntry['id'], isUpdate: true);
            },
            child: const Text('ADD'),
          ),
        ],
      ),
    );
  }

  String _generateStockId({
    required String date,
    required String time,
    required String barcode,
    required String productName,
    required String location,
  }) {
    final cleanDate = date.replaceAll(RegExp(r'[^0-9-]'), '');
    final cleanTime = time
        .replaceAll(RegExp(r'[^0-9:]'), '')
        .replaceAll(':', '');

    final rawBarcode = barcode.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final cleanBarcode = rawBarcode.isEmpty
        ? 'unknown'
        : rawBarcode.substring(0, math.min(20, rawBarcode.length));

    final rawProduct = productName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final cleanProduct = rawProduct.isEmpty
        ? 'unknown'
        : rawProduct.substring(0, math.min(15, rawProduct.length));

    final rawLocation = location.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final cleanLocation = rawLocation.isEmpty
        ? 'unknown'
        : rawLocation.substring(0, math.min(10, rawLocation.length));

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = _generateShortId();

    return 'stock_${cleanDate}_${cleanTime}_${cleanBarcode}_${cleanProduct}_${cleanLocation}_${timestamp}_$random';
  }

  String _generateShortId() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    String result = '';
    for (int i = 0; i < 6; i++) {
      result += chars[math.Random.secure().nextInt(chars.length)];
    }
    return result;
  }

  Future<void> _commitSaveToDB({String? existingId, bool isUpdate = false}) async {
    final storage = context.read<OfflineStorage>();

    var preserved = <String, dynamic>{};
    if (_isEditMode) {
      preserved = normalizeStockRecord(widget.existingCount!);
    } else if (existingId != null) {
      final rows = await storage.getStockCounts();
      final matches = rows.where((row) => row['id']?.toString() == existingId).toList();
      if (matches.length != 1) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The existing count changed. Reopen it before editing.')));
        return;
      }
      preserved = normalizeStockRecord(matches.single);
    }
    if (_isEditMode || isUpdate) {
      try {
        final product = stockProductForEdit(preserved, _selectedProduct);
        final cost = stockRecordedUnitValue(preserved, 'cost_value') ?? _resolvedUnitCost;
        final retail = stockRecordedUnitValue(preserved, 'retail_value') ?? _resolvedUnitRetail;
        validateStockEdit(preserved, product, cost, retail);
        _selectedProduct = product;
        _resolvedUnitCost = cost;
        _resolvedUnitRetail = retail;
      } catch (error) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
        return;
      }
    }
    if (!mounted) return;
    final dateToUse = _isEditMode
        ? preserved['date']
        : (widget.initialDate != null
        ? widget.initialDate!.toIso8601String().split('T')[0]
        : DateTime.now().toIso8601String().split('T')[0]);

    final timeToUse = DateTime.now().toIso8601String().split('T').last.split('.').first;
    final barcode = _selectedBarcode ?? '';
    final productName = _selectedProduct?['Inventory Product Name'] ?? _productController.text;
    final location = widget.initialLocation ?? _selectedLocation ?? '';

    String id;
    if (existingId != null) {
      id = existingId;
    } else if (_isEditMode && widget.existingCount!['id'] != null) {
      id = widget.existingCount!['id'];
    } else {
      id = _generateStockId(
        date: dateToUse,
        time: timeToUse,
        barcode: barcode,
        productName: productName,
        location: location,
      );
    }

    final stockId = id;
    // 🔥 FIX: Handle both createdAt and created_at to avoid losing the original timestamp
    final createdDate = _isEditMode
        ? (widget.existingCount!['createdAt'] ?? widget.existingCount!['created_at'] ?? DateTime.now().toIso8601String())
        : DateTime.now().toIso8601String();

    _recalculateTotals();

    final countData = <String, dynamic>{
      ...preserved,
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
      'count': double.tryParse(_countController.text) ?? 0.0,
      'weight': double.tryParse(_weightController.text) ?? 0.0,
      'volume_ml': _calcVolumeMl,
      'open_tots': _calcOpenTots,
      'total_bottles': _calcTotalBottles,
      'total_ml': _calcTotalMl,
      'total_shots': _calcTotalMl / 25.0,
      'cost_value': _calcCostValue,
      'retail_value': _calcRetailValue,
      'createdAt': preserved['createdAt'] ?? createdDate,
      'updatedAt': DateTime.now().toIso8601String(),
      'auditId': preserved['auditId'] ?? _selectedAudit,
      'syncStatus': 'pending',
    };

    try {
      if (isUpdate || _isEditMode) {
        await storage.updateStockCount(countData);

        // 🔥 REAL-TIME UPDATE TO FIRESTORE
        final syncService = context.read<StoreManager>().syncService;
        if (syncService.firestore != null && storage.currentStoreId != null) {
          final firestoreData = Map<String, dynamic>.from(countData);
          firestoreData['deleted'] = false; // Explicitly ensure active state
          await syncService.firestore!.saveStockCount(storage.firestoreKey!, firestoreData);
        }

        _logger?.info('Updated: ${_productController.text} ($id)');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry Updated'), backgroundColor: Colors.blue));
        if (_isEditMode) {
          Navigator.pop(context);
        } else {
          _clearForm();
        }
      } else {
        await storage.saveStockCount(countData);

        // 🔥 REAL-TIME WRITE TO FIRESTORE FOR NEW CREATIONS
        final syncService = context.read<StoreManager>().syncService;
        if (syncService.firestore != null && storage.currentStoreId != null) {
          final firestoreData = Map<String, dynamic>.from(countData);
          firestoreData['deleted'] = false;
          await syncService.firestore!.saveStockCount(storage.firestoreKey!, firestoreData);
        }

        _logger?.info('Saved: ${_productController.text} ($id)');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved: $_calcTotalBottles Bottles'), backgroundColor: Colors.green));
        _clearForm();
      }

      _loadContextData();

    } catch (e) {
      _logger?.error('Save Failed', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }


  void _clearForm() {
    if (widget.initialProduct != null) {
      _countController.text = '0';
      _weightController.text = '0';
      if (!mounted) return;
      setState(() {
        _calcVolumeMl = 0;
        _calcTotalBottles = 0;
        _calcCostValue = 0;
        _calcRetailValue = 0;
      });
      _loadContextData();
    } else {
      _productController.clear();
      _countController.text = '0';
      _weightController.text = '0';
      _selectedBarcode = null;
      _selectedProduct = null;
      _selectedPackSize = null;

      // 🔥 FIX: Reset ALL pricing-related state
      if (!mounted) return;
      setState(() {
        _resolvedUnitCost = 0.0;
        _resolvedUnitRetail = 0.0;
        _costFellBack = false;
        _retailFellBack = false;
        _calcVolumeMl = 0;
        _calcTotalBottles = 0;
        _calcCostValue = 0;
        _calcRetailValue = 0;
        _todayTotalAcrossAllLocs = 0.0;
        _historyStats = [];
      });
    }
  }

  // ============================================================================
  // BUILD
  // ============================================================================

  Widget _buildLocationInput() {
    return CountLocationField(
      locations: _locations.map((row) => row['Location']?.toString()).toList(),
      value: widget.initialLocation ?? _selectedLocation,
      readOnly: widget.initialLocation != null,
      onChanged: (value) {
        if (mounted) setState(() => _selectedLocation = value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final costPrice = _resolvedUnitCost;
    final currentPackSizes = _getFilteredPackSizes();

    bool isSameDay = false;
    if (widget.initialDate != null) {
      final now = DateTime.now();
      isSameDay =
          now.year == widget.initialDate!.year &&
              now.month == widget.initialDate!.month &&
              now.day == widget.initialDate!.day;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditMode ? 'Edit Count' : 'New Count'),
        actions: [
          if (_isEditMode)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: _deleteEntry,
              tooltip: 'Delete Entry',
            ),
        ],
      ),
      body: GestureDetector(
        onTap: () {
          if (_showProductSuggestions) {
            if (mounted) setState(() => _showProductSuggestions = false);
          }
          FocusScope.of(context).unfocus();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                // 1. DATE BANNER
                if (widget.initialDate != null && !_isEditMode)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: isSameDay
                          ? Colors.blue.shade50
                          : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSameDay ? Colors.blue : Colors.orange,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isSameDay ? Icons.calendar_today : Icons.history,
                          color: isSameDay ? Colors.blue : Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isSameDay
                              ? 'Adding Entry for: '
                              : 'Backdating Entry to: ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isSameDay
                                ? Colors.blue[900]
                                : Colors.orange[900],
                          ),
                        ),
                        Text(
                          DateFormat('dd MMM yyyy').format(widget.initialDate!),
                          style: TextStyle(
                            color: isSameDay
                                ? Colors.blue[900]
                                : Colors.orange[900],
                          ),
                        ),
                      ],
                    ),
                  ),

                // 2. PRODUCT INPUT
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
                          suffixIcon:
                          (_isEditMode || widget.initialProduct != null)
                              ? const Icon(Icons.lock, color: Colors.grey)
                              : IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            onPressed: _scanBarcode,
                          ),
                        ),
                        onTap: () {
                          if (!_isEditMode &&
                              widget.initialProduct == null &&
                              _productController.text.isNotEmpty) {
                            if (mounted)
                              setState(() => _showProductSuggestions = true);
                          }
                        },
                      ),
                    ),
                    if (!_isEditMode && widget.initialProduct == null) ...[
                      const SizedBox(width: 8),
                      IconButton.filled(
                        icon: const Icon(Icons.add),
                        tooltip: 'Manual Entry',
                        onPressed: _openManualAdd,
                      ),
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
                            title: Text(
                              p['Inventory Product Name']?.toString() ?? '',
                            ),
                            subtitle: Text(p['Barcode']?.toString() ?? ''),
                            onTap: () => _selectProductFromList(p),
                          );
                        },
                      ),
                    ),
                  ),

                const SizedBox(height: 16),

                // 3. LOCATION INPUT
                _buildLocationInput(),
                const SizedBox(height: 16),

                // 4. PACK SIZE INPUT
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(
                    labelText: 'Pack Size',
                    border: OutlineInputBorder(),
                  ),
                  initialValue: _selectedPackSize,
                  isExpanded: true,
                  items: currentPackSizes
                      .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                      .toList(),
                  onChanged: (val) {
                    if (!mounted) return;
                    setState(() {
                      _selectedPackSize = val;
                      if (_isWeightBased(val)) {
                        _countController.text = '0';
                      } else {
                        _weightController.text = '0';
                      }
                    });
                    _recalculateTotals();
                  },
                ),
                const SizedBox(height: 16),

                // 5. MODE SELECTOR (If Open Bottle)
                if (_selectedPackSize == 'Open Bottle')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SegmentedButton<String>(
                      segments: [
                        const ButtonSegment(
                          value: 'Shots',
                          label: Text('Shots'),
                          icon: Icon(Icons.local_bar),
                        ),
                        const ButtonSegment(
                          value: 'Volume',
                          label: Text('mL'),
                          icon: Icon(Icons.water_drop),
                        ),
                        if (_safeDouble(_selectedProduct?['Gradient']) != 0)
                          const ButtonSegment(
                            value: 'Weight',
                            label: Text('Grams'),
                            icon: Icon(Icons.scale),
                          ),
                      ],
                      selected: {_measurementType},
                      onSelectionChanged: (Set<String> newSelection) {
                        if (!mounted) return;
                        setState(() {
                          _measurementType = newSelection.first;
                          _weightController.clear();
                        });
                        _recalculateTotals();
                      },
                    ),
                  ),

                // 6. COUNT INPUT ROW + SAVE BUTTON
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (!_isWeightBased(_selectedPackSize))
                      Expanded(
                        child: TextFormField(
                          controller: _countController,
                          decoration: const InputDecoration(
                            labelText: 'Count (Units)',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),

                    if (!_isWeightBased(_selectedPackSize))
                      const SizedBox(width: 16),

                    if (_isWeightBased(_selectedPackSize))
                      Expanded(
                        child: TextFormField(
                          controller: _weightController,
                          decoration: InputDecoration(
                            labelText: _selectedPackSize == 'Open Bottle'
                                ? (_measurementType == 'Shots'
                                ? 'Number of Shots'
                                : (_measurementType == 'Volume'
                                ? 'Volume (mL)'
                                : 'Weight (g)'))
                                : 'Net Weight',
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),

                    const SizedBox(width: 12),

                    SizedBox(
                      height: 56,
                      width: 56,
                      child: IconButton.filled(
                        onPressed: _processSave,
                        icon: const Icon(Icons.check, size: 28),
                        tooltip: 'Save',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // 7. CONTEXT CARD
                if (_selectedProduct != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.indigo.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.indigo.shade200),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Total Today (All Locs):',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.indigo,
                              ),
                            ),
                            Text(
                              _todayTotalAcrossAllLocs.toStringAsFixed(2),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                                color: Colors.indigo,
                              ),
                            ),
                          ],
                        ),
                        if (_historyStats.isNotEmpty) ...[
                          const Divider(height: 16),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'History:',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: _historyStats.map((h) {
                              String date = h['date'];
                              try {
                                date = DateFormat(
                                  'dd MMM',
                                ).format(DateTime.parse(h['date']));
                              } catch (e) {}
                              return Column(
                                children: [
                                  Text(
                                    date,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    h['total'].toStringAsFixed(1),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),

                // 8. PRODUCT DETAILS CARD
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
                          const Text(
                            'Product Details',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: Colors.blue,
                            ),
                          ),
                          const Divider(color: Colors.blue),
                          _buildDetailRow(
                            'Name',
                            _selectedProduct!['Inventory Product Name'],
                          ),
                          _buildDetailRow(
                            'Category',
                            _selectedProduct!['Category'],
                          ),
                          _buildDetailRow(
                            'Volume',
                            '${_selectedProduct!['Single Unit Volume']} ${_selectedProduct!['UoM']}',
                          ),
                          _buildDetailRow(
                            'Unit Cost',
                            NumberFormat.simpleCurrency(
                              name: 'R',
                            ).format(costPrice),
                          ),
                          if (_costFellBack || _retailFellBack)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _costFellBack
                                    ? '⚠️ Cost derived from retail/3'
                                    : '⚠️ Retail derived from cost×3',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange.shade700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                // 9. CALCULATED TOTALS
                if (_selectedProduct != null)
                  Card(
                    color: Colors.green.shade50,
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          const Text(
                            'CALCULATED TOTALS',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const Divider(),
                          if (_selectedPackSize == 'Open Bottle') ...[
                            _buildSummaryRow(
                              'Calc Volume:',
                              '${_calcVolumeMl.toStringAsFixed(1)} ml',
                            ),
                            _buildSummaryRow(
                              'Open Tots:',
                              _calcOpenTots.toStringAsFixed(2),
                            ),
                          ],
                          _buildSummaryRow(
                            'Total Bottles/Units:',
                            _calcTotalBottles.toStringAsFixed(2),
                          ),
                          _buildSummaryRow(
                            'Total Cost Value:',
                            NumberFormat.simpleCurrency(
                              name: 'R',
                            ).format(_calcCostValue),
                          ),
                          _buildSummaryRow(
                            'Total Retail Value:',
                            NumberFormat.simpleCurrency(
                              name: 'R',
                            ).format(_calcRetailValue),
                            isTotal: true,
                          ),
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

  Widget _buildDetailRow(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.grey[700],
              ),
            ),
          ),
          Expanded(
            child: Text(
              value?.toString() ?? '-',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
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
          Text(
            label,
            style: TextStyle(
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
