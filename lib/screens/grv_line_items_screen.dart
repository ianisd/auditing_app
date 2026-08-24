import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:data_table_2/data_table_2.dart';
import '../models/plu_mapping.dart';
import '../services/offline_storage.dart';
import 'add_product_screen.dart';
import 'grv_add_line_item_screen.dart';
import '../models/grv_models.dart';

//***************************************************************************
// SCREEN: GrvLineItemsScreen
// Purpose: Displays and manages GRV line items with auto-matching from invoices
//***************************************************************************

class GrvLineItemsScreen extends StatefulWidget {
  final String invoiceDetailsID;
  final String supplierName;
  final DateTime deliveryDate;
  final String grvReference;
  final List<ParsedGrvLineItem>? preloadedItems;

  const GrvLineItemsScreen({
    super.key,
    required this.invoiceDetailsID,
    required this.supplierName,
    required this.deliveryDate,
    required this.grvReference,
    this.preloadedItems,
  });

  @override
  State<GrvLineItemsScreen> createState() => _GrvLineItemsScreenState();
}

//===========================================================================
// STATE CLASS
//===========================================================================
class _GrvLineItemsScreenState extends State<GrvLineItemsScreen> {
  //-------------------------------------------------------------------------
  // PROPERTIES
  //-------------------------------------------------------------------------
  final List<GrvLineItemDisplay> _items = [];
  bool _isMatching = false;
  bool _isLoading = false;
  double _totalValue = 0.0;
  bool _isDisposed = false;
  bool _hasInitialized = false;
  Map<String, dynamic>? _noMatchBrowserSelection;

  // 🔥 Add this
  Timer? _debounceTimer;

  // 🔥 Add this for tracking the correct invoice ID
  String? _currentInvoiceId;

  // Cache for product details to avoid repeated lookups
  final Map<String, Map<String, dynamic>> _productCache = {};

  //-------------------------------------------------------------------------
  // LIFECYCLE METHODS
  //-------------------------------------------------------------------------
  @override
  void initState() {
    super.initState();
    print('DEBUG: GrvLineItemsScreen.initState() called');
    print('  - Invoice ID: ${widget.invoiceDetailsID}');
    print('  - Supplier: ${widget.supplierName}');
    print('  - Delivery Date: ${widget.deliveryDate}');
    print('  - Preloaded Items: ${widget.preloadedItems?.length ?? 0}');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_hasInitialized) {
      final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

      if (args == null && widget.preloadedItems != null && widget.preloadedItems!.isNotEmpty) {
        // 🔥 Cancel any existing timer
        _debounceTimer?.cancel();

        _debounceTimer = Timer(const Duration(milliseconds: 300), () {
          if (mounted) {
            final storage = context.read<OfflineStorage>();

            // 🔥 FIX: Don't check for duplicates here - the invoice was just saved!
            // The upload screen already saved the invoice. Just auto-match.
            _autoMatchPluItems(widget.preloadedItems!, invoiceId: widget.invoiceDetailsID);
          }
        });
      }

      _hasInitialized = true;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }


  bool _isMounted() => mounted && !_isDisposed;

  /// Check if an invoice already exists for this supplier + invoice number
  Future<Map<String, dynamic>?> _checkForExistingInvoice(
      String invoiceNumber,
      String supplierName
      ) async {
    final storage = context.read<OfflineStorage>();
    return await storage.findInvoiceBySupplierAndNumber(
      supplierName: supplierName,
      invoiceNumber: invoiceNumber,
    );
  }

  /// Check for duplicate invoice with enhanced criteria
  Future<Map<String, dynamic>?> _checkForDuplicateInvoice({
    required String invoiceNumber,
    required String supplierName,
    required DateTime deliveryDate,
    required List<ParsedGrvLineItem> items,
  }) async {
    final storage = context.read<OfflineStorage>();

    // 1. First check by supplier + invoice number
    final existingInvoice = await storage.findInvoiceBySupplierAndNumber(
      supplierName: supplierName,
      invoiceNumber: invoiceNumber,
    );

    if (existingInvoice == null) {
      return null; // No duplicate found
    }

    // 2. Get existing purchases for this invoice
    final existingPurchases = await storage.getPurchasesByInvoiceId(
      existingInvoice['invoiceDetailsID']?.toString() ?? '',
    );

    // 3. Check if the items match exactly
    final existingItemCount = existingPurchases.length;
    final newItemCount = items.length;

    // 4. Check if the delivery date matches
    final existingDate = existingInvoice['Date of Purchase']?.toString();
    final newDate = deliveryDate.toIso8601String();
    final datesMatch = existingDate == newDate;

    // 5. Check if the total value matches
    double toDouble(dynamic value) {
      if (value == null) return 0.0;
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0.0;
      return 0.0;
    }

// Then:
    final existingTotal = existingPurchases.fold<double>(
      0.0,
          (sum, p) => sum + toDouble(p['Cost of Purchases']),
    );
    final newTotal = items.fold<double>(
      0.0,
          (sum, i) => sum + i.totalValue,
    );
    final totalsMatch = (existingTotal - newTotal).abs() < 0.01;

    // 6. Check if the items match (by barcode or product name)
    final existingItems = existingPurchases.map((p) =>
    '${p['Barcode']}|${p['Purchased Product Name']}'
    ).toSet();
    final newItems = items.map((i) =>
    '${i.barcode}|${i.description}'
    ).toSet();
    final itemsMatch = existingItems.containsAll(newItems) &&
        newItems.containsAll(existingItems);

    // 7. Determine duplicate type
    final isExactDuplicate = datesMatch && totalsMatch && itemsMatch;
    final isPartialDuplicate = !isExactDuplicate &&
        (datesMatch || totalsMatch || itemsMatch);

    print('🔍 Duplicate Analysis:');
    print('  - Exact duplicate: $isExactDuplicate');
    print('  - Partial duplicate: $isPartialDuplicate');
    print('  - Dates match: $datesMatch');
    print('  - Totals match: $totalsMatch');
    print('  - Items match: $itemsMatch');

    return {
      'existingInvoice': existingInvoice,
      'existingItemCount': existingItemCount,
      'newItemCount': newItemCount,
      'isExactDuplicate': isExactDuplicate,
      'isPartialDuplicate': isPartialDuplicate,
      'existingTotal': existingTotal,
      'newTotal': newTotal,
      'datesMatch': datesMatch,
      'totalsMatch': totalsMatch,
      'itemsMatch': itemsMatch,
    };
  }

  /// Show duplicate warning dialog with 3 options
  Future<String?> _showDuplicateWarningDialog({
    required String invoiceNumber,
    required String supplierName,
    required String? existingDate,
    int existingItemCount = 0,  // 🔥 ADD THIS
    int newItemCount = 0,       // 🔥 ADD THIS
  }) async {
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('⚠️ Duplicate GRV Detected'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Invoice #$invoiceNumber from $supplierName already exists.'),
            const SizedBox(height: 8),
            if (existingDate != null)
              Text('Existing date: ${existingDate.split('T')[0]}'),
            const SizedBox(height: 8),
            // 🔥 Show item counts
            Text('Existing items: $existingItemCount, New items: $newItemCount'),
            const SizedBox(height: 16),
            const Text(
              'What would you like to do?',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('• UPDATE: Keep existing invoice, add/update items'),
            const Text('• CREATE NEW: Create a new GRV (keeps both)'),
            const Text('• CANCEL: Stop this upload'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('CANCEL'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, 'create_new'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('CREATE NEW'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'update'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            child: const Text('UPDATE'),
          ),
        ],
      ),
    ) ?? 'cancel';
  }

  //=========================================================================
  // HELPER METHODS - DATA EXTRACTION
  //=========================================================================
  // TODO: Add helper methods for extracting and parsing data from various sources
  // Example: _parseNumericValue(String value), _extractFromMap(...)

  double? _extractCost(Map<String, dynamic> costEntry) {
    final costValue = costEntry['Cost Price'] ??
        costEntry['cost'] ??
        costEntry['avgCost'] ??
        costEntry['Unit Cost'] ??
        costEntry['Cost'];

    if (costValue == null) return null;

    if (costValue is num) return costValue.toDouble();
    if (costValue is String) {
      final cleaned = costValue.replaceAll(',', '').replaceAll(RegExp(r'[^\d.]'), '');
      return double.tryParse(cleaned);
    }
    return null;
  }

  //=========================================================================
  // HELPER METHODS - DATA PROCESSING
  //=========================================================================
  // TODO: Add helper methods for processing and transforming data
  // Example: _buildProductLookup(), _calculateMatchScore(), _normalizeString()

  Future<Map<String, dynamic>?> _getProductDetailsByName(String productName) async {
    // Check cache first
    if (_productCache.containsKey(productName)) {
      return _productCache[productName];
    }

    final storage = context.read<OfflineStorage>();
    final allInventory = await storage.getAllInventory();

    final product = allInventory.firstWhere(
          (item) => item['Inventory Product Name']?.toString() == productName,
      orElse: () => <String, dynamic>{},
    );

    // Cache the result for next time
    if (product.isNotEmpty) {
      _productCache[productName] = product;
    }

    return product;
  }

  Future<Map<String, Map<String, dynamic>>> _buildPluLookup(OfflineStorage storage) async {
    final Map<String, Map<String, dynamic>> productByPlu = {};

    try {
      final itemSales = await storage.getItemSalesMap();
      for (var sale in itemSales) {
        final plu = sale['PLU']?.toString().trim();
        final productName = sale['Product']?.toString().trim() ?? sale['Menu Item']?.toString().trim();
        if (plu != null && plu.isNotEmpty && productName != null && productName.isNotEmpty) {
          productByPlu[plu] = {'productName': productName};
        }
      }
      print('  📊 Built PLU lookup with ${productByPlu.length} entries');
    } catch (e) {
      print('  ⚠️ Could not build PLU lookup: $e');
    }

    return productByPlu;
  }

  Future<Map<String, Map<String, dynamic>>> _buildProductNameLookup(List<Map<String, dynamic>> allInventory) async {
    final Map<String, Map<String, dynamic>> productByName = {};

    for (var product in allInventory) {
      final name = product['Inventory Product Name']?.toString().toLowerCase().trim();
      if (name != null && name.isNotEmpty) {
        productByName[name] = product;
      }
    }

    return productByName;
  }

  Future<Map<String, Map<String, dynamic>>> _buildCostLookup(List<Map<String, dynamic>> allMasterCosts) async {
    final Map<String, Map<String, dynamic>> costsBySupplierAndProduct = {};

    for (var cost in allMasterCosts) {
      final supplierID = cost['supplierID']?.toString();
      final productName = cost['Product Name']?.toString().toLowerCase().trim();
      if (supplierID != null && productName != null) {
        final key = '$supplierID|$productName';
        costsBySupplierAndProduct[key] = cost;
      }
    }

    return costsBySupplierAndProduct;
  }

  Future<Map<String, dynamic>> _buildLookupMaps() async {
    final storage = context.read<OfflineStorage>();

    print('  📦 Pre-fetching data...');
    final allInventory = await storage.getAllInventory();
    // 🔥 FIX: Use cached version
    final allSuppliers = await storage.getMasterSuppliersCached();
    final allMasterCosts = await storage.getMasterCosts();
    final productByPlu = await _buildPluLookupFromItemsIssued(storage);
    final productByName = await _buildProductNameLookup(allInventory);
    final costsBySupplierAndProduct = await _buildCostLookup(allMasterCosts);

    print('  📊 Data loaded: ${allInventory.length} products, ${allSuppliers.length} suppliers, ${allMasterCosts.length} costs');

    return {
      'allInventory': allInventory,
      'allSuppliers': allSuppliers,
      'allMasterCosts': allMasterCosts,
      'productByPlu': productByPlu,
      'productByName': productByName,
      'costsBySupplierAndProduct': costsBySupplierAndProduct,
    };
  }

  String? _findSupplierId(List<Map<String, dynamic>> allSuppliers) {
    // This method is called with allSuppliers from _buildLookupMaps,
    // which already uses the cached version. No change needed.
    final supplier = allSuppliers.firstWhere(
          (s) => s['Supplier']?.toString() == widget.supplierName,
      orElse: () => <String, dynamic>{},
    );
    return supplier['supplierID']?.toString();
  }

  Future<GrvLineItemDisplay> _matchSingleItem(
      ParsedGrvLineItem item,
      Map<String, Map<String, dynamic>> productByPlu,
      Map<String, Map<String, dynamic>> productByName,
      Map<String, Map<String, dynamic>> costsBySupplierAndProduct,
      List<Map<String, dynamic>> allSuppliers,
      ) async {

    String? productName;
    String? barcode;
    String? supplierBottleID;
    double? price = item.pricePerUnit;
    String? matchedPlu;
    String? matchedBy;

    final storage = context.read<OfflineStorage>();
    final supplierID = _findSupplierId(allSuppliers);

    // ------------------------------------------------------------------------
    // PHASE 1: Try PLU matching with saved mappings
    // ------------------------------------------------------------------------
    if (item.plu.isNotEmpty && supplierID != null) {
      final savedMapping = await storage.getPluMapping(supplierID, item.plu);

      if (savedMapping != null) {
        final lookupName = savedMapping.productName.toLowerCase().trim();

        if (productByName.containsKey(lookupName)) {
          final matchedProduct = productByName[lookupName];
          productName = matchedProduct?['Inventory Product Name']?.toString();
          barcode = matchedProduct?['Barcode']?.toString();
          matchedPlu = savedMapping.correctPlu;
          matchedBy = 'saved_mapping';
          print('    ✅ [SAVED MAPPING] ${item.plu} -> ${savedMapping.correctPlu} -> $productName');
        } else if (productByPlu.containsKey(savedMapping.correctPlu)) {
          final pluMatch = productByPlu[savedMapping.correctPlu];
          productName = pluMatch?['productName']?.toString();
          matchedPlu = savedMapping.correctPlu;
          matchedBy = 'saved_mapping';
          print('    ✅ [SAVED MAPPING VIA PLU] ${item.plu} -> ${savedMapping.correctPlu} -> $productName');
        }
      }

      // If no saved mapping, try direct PLU match
      // WITH — verify the resolved name actually exists in inventory:
      // If no saved mapping, try direct PLU match
      if (productName == null && productByPlu.containsKey(item.plu)) {
        final pluMatch = productByPlu[item.plu];
        final candidateName = pluMatch?['productName']?.toString();

        if (candidateName != null && candidateName.isNotEmpty) {
          // Confirm this name resolves to a real inventory record
          final inventoryRecord = await _getProductDetailsByName(candidateName);
          if (inventoryRecord != null && inventoryRecord.isNotEmpty) {
            productName = inventoryRecord['Inventory Product Name']?.toString();
            barcode = inventoryRecord['Barcode']?.toString();
            matchedBy = 'plu_direct';
            print('    ✅ [PLU DIRECT] ${item.plu} -> $productName (inventory confirmed)');
          } else {
            print('    ⚠️ [PLU DIRECT] ${item.plu} -> "$candidateName" NOT found in inventory, skipping');
          }
        }
      }
    }

    // ------------------------------------------------------------------------
    // PHASE 2: Fuzzy matching — always requires user confirmation
    // ------------------------------------------------------------------------
    if (productName == null) {
      print('    🔍 [FUZZY] Attempting to match: "${item.description}"');

      final matches = _findBestProductMatches(item.description, productByName);

      if (matches.isNotEmpty) {
        // ✅ FIX: Always show dialog regardless of match count.
        // Removed the fuzzy_single silent auto-accept — a single result above
        // the 0.3 threshold is NOT a confirmed match and must never be
        // written to purchases without user approval.
        print('    ⚠️ [FUZZY] ${matches.length} possible match(es) - showing dialog');

        final selectedProduct = await _showProductSelectionDialog(
          context,
          item.description,
          matches,
        );

        if (selectedProduct != null) {
          // User tapped "Browse All" instead of picking a fuzzy suggestion
          final wantsBrowse = selectedProduct['__browse_all__'] == true;
          final resolvedProduct = wantsBrowse
              ? await _showFullProductBrowser(context, item.description)
              : selectedProduct;

          if (resolvedProduct != null) {
            productName = resolvedProduct['Inventory Product Name']?.toString();
            barcode = resolvedProduct['Barcode']?.toString();
            matchedBy = wantsBrowse ? 'manual_browser' : 'manual_selection';
            print('    ✅ [${wantsBrowse ? 'BROWSE' : 'MANUAL'}] User selected: "$productName"');

            // Offer to save mapping
            if (supplierID != null && item.plu.isNotEmpty) {
              final shouldSave = await _showSaveMappingDialog(
                context,
                item,
                supplierID,
                resolvedProduct,
              );

              if (shouldSave) {
                final correctPlu = await _findPluForProduct(resolvedProduct);
                if (correctPlu != null) {
                  final mapping = PluMapping(
                    csvPlu: item.plu,
                    csvDescription: item.description,
                    correctPlu: correctPlu,
                    productName: productName!,
                    supplierId: supplierID,
                    createdAt: DateTime.now(),
                  );
                  await storage.savePluMapping(mapping);
                  print('    💾 [MAPPING SAVED] ${item.plu} -> $correctPlu');
                  final verifyMapping = await storage.getPluMapping(supplierID, item.plu);
                  if (verifyMapping != null) {
                    print('    ✅ VERIFICATION: Mapping exists in DB');
                  } else {
                    print('    ❌ VERIFICATION: Mapping NOT found in DB!');
                  }
                  final allMappings = await storage.getAllPluMappings();
                  print('    📊 Total mappings now: ${allMappings.length}');
                }
              }
            }
          } else {
            print('    ⚠️ [FUZZY] User dismissed browser without selecting');
          }
        } else {
          print('    ⚠️ [FUZZY] User skipped selection');
        }

      } else {
        print('    ❌ [FUZZY] No matches found');

        if (_isMounted()) {
          final String? action = await _showNoMatchDialog(context, item.description);

          if (action == 'browser_selected' && _noMatchBrowserSelection != null) {
            // User picked from the full inventory browser
            final selectedProduct = _noMatchBrowserSelection!;
            _noMatchBrowserSelection = null;
            productName = selectedProduct['Inventory Product Name']?.toString();
            barcode = selectedProduct['Barcode']?.toString();
            matchedBy = 'manual_browser';
            print('    ✅ Selected from browser: "$productName"');

            if (supplierID != null && item.plu.isNotEmpty) {
              final correctPlu = await _findPluForProduct(selectedProduct);
              if (correctPlu != null) {
                final mapping = PluMapping(
                  csvPlu: item.plu,
                  csvDescription: item.description,
                  correctPlu: correctPlu,
                  productName: productName!,
                  supplierId: supplierID,
                  createdAt: DateTime.now(),
                );
                await storage.savePluMapping(mapping);
                print('    💾 [MAPPING SAVED] ${item.plu} -> $correctPlu');
              }
            }
          } else if (action == 'add_new') {
            print('    ➕ User chose to add new product');
            final newProduct = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => AddProductScreen(
                  initialName: item.description,
                ),
              ),
            );

            if (newProduct != null && newProduct is Map<String, dynamic>) {
              productName = newProduct['Inventory Product Name']?.toString();
              barcode = newProduct['Barcode']?.toString();
              matchedBy = 'new_product';
              print('    ✅ New product created: "$productName"');

              if (supplierID != null && item.plu.isNotEmpty) {
                final correctPlu = await _findPluForProduct(newProduct);
                if (correctPlu != null) {
                  final mapping = PluMapping(
                    csvPlu: item.plu,
                    csvDescription: item.description,
                    correctPlu: correctPlu,
                    productName: productName!,
                    supplierId: supplierID,
                    createdAt: DateTime.now(),
                  );
                  await storage.savePluMapping(mapping);
                  print('    💾 [MAPPING SAVED] ${item.plu} -> $correctPlu');
                }
              }
            }
          } else {
            print('    ⏭️ User chose to skip or dismissed');
          }
        }
      }
    }

    // ------------------------------------------------------------------------
    // PHASE 3: Look up cost
    // ------------------------------------------------------------------------
    if (supplierID != null && productName != null) {
      final costKey = '$supplierID|${productName.toLowerCase().trim()}';
      final costMatch = costsBySupplierAndProduct[costKey];

      if (costMatch != null) {
        supplierBottleID = costMatch['supplierBottleID']?.toString();
        price = _extractCost(costMatch) ?? item.pricePerUnit;
        print('    ✅ [COST] Found: R$price, ID: $supplierBottleID');
      }
    }

    return GrvLineItemDisplay(
      plu: item.plu,
      description: item.description,
      quantityCases: item.quantityCases,
      unitsPerCase: item.unitsPerCase,
      pricePerUnit: price ?? item.pricePerUnit,
      productName: productName,
      barcode: barcode,
      supplierBottleID: supplierBottleID,
      matchedBy: matchedBy,
    );
  }

  void _calculateTotal() {
    _totalValue = _items.fold(0.0, (sum, item) => sum + item.totalValue);
    print('DEBUG: Total calculated: $_totalValue for ${_items.length} items');
  }

  List<Map<String, dynamic>> _findBestProductMatches(
      String description,
      Map<String, Map<String, dynamic>> productByName, {
        double threshold = 0.3,
      }) {

    String normalize(String s) {
      return s.toLowerCase()
          .replaceAll(RegExp(r'[^\w\s]'), '')
          .replaceAll(RegExp(r'\b(the|and|yr|yrs|ml|btl|bottle|pack|case|can|glass)\b'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    final searchTerm = normalize(description);
    final searchWords = searchTerm.split(' ');

    // Brand corrections for common mismatches
    final brandMappings = {
      'veuve': 'veuve clicquot',
      'clicquot': 'veuve clicquot',
      'yl': 'ponsardin yl',
      'yellow': 'ponsardin yl',
      'mumm': 'g.h.mumm',
      'mum': 'g.h.mumm',
      'ice': 'ice extra',
      'pongracz': 'pongracz',
      'noble': 'noble nector',
      'nectar': 'noble nector',
      'dom': 'dom perignon',
      'brut': 'brut',
      'luminous': 'luminous',
      'rich': 'rich',
      'kranz': 'krans',           // For "DE KRANZ" -> "DE KRANS"
      'dusse': "d'usse",          // For "DUSSE" -> "D'usse"
      'corona': 'corona extra',    // For "CCORONA" -> "Corona"
      'hennessey': 'hennessy',     // Common misspelling
      'hennessy': 'hennessy vs',   // For "HENNESSEY VSCO" -> "Hennessy VS"
    };

    List<MapEntry<Map<String, dynamic>, double>> scored = [];

    for (var entry in productByName.entries) {
      final productName = entry.key;
      final normalizedProduct = normalize(productName);

      double score = 0;

      // Exact match bonus
      if (normalizedProduct == searchTerm) {
        score += 100;
      }

      // Contains match
      if (normalizedProduct.contains(searchTerm)) {
        score += 50;
      }
      if (searchTerm.contains(normalizedProduct)) {
        score += 40;
      }

      // Word matching with weights
      for (var word in searchWords) {
        if (word.length < 2) continue;

        if (normalizedProduct.contains(word)) {
          if (normalizedProduct.split(' ').contains(word)) {
            score += 10;  // Exact word match
          } else {
            score += 5;   // Partial match
          }
        }

        // Check brand mappings
        for (var mapping in brandMappings.entries) {
          if (word.contains(mapping.key) && normalizedProduct.contains(mapping.value)) {
            score += 8;
          }
        }
      }

      // Normalize score by length
      score = score / (normalizedProduct.split(' ').length + 1);

      if (score > threshold) {
        scored.add(MapEntry(entry.value, score));
      }
    }

    // Sort by score descending
    scored.sort((a, b) => b.value.compareTo(a.value));

    return scored.map((e) => e.key).toList();
  }
  bool _fuzzyMatch(String a, String b) {
    final aNorm = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '');
    final bNorm = b.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '');

    // Check if one contains the other
    if (aNorm.contains(bNorm) || bNorm.contains(aNorm)) return true;

    // Check word-by-word
    final aWords = aNorm.split(RegExp(r'\s+'));
    final bWords = bNorm.split(RegExp(r'\s+'));

    int matches = 0;
    for (var aWord in aWords) {
      if (aWord.length < 3) continue;
      for (var bWord in bWords) {
        if (bWord.length < 3) continue;
        if (aWord == bWord || aWord.contains(bWord) || bWord.contains(aWord)) {
          matches++;
          break;
        }
      }
    }

    return matches >= (aWords.length / 2).ceil();
  }

  // NEW method using ItemsIssued
  // NEW improved method using ItemsIssuedMap
  Future<Map<String, Map<String, dynamic>>> _buildPluLookupFromItemsIssued(OfflineStorage storage) async {
    final Map<String, Map<String, dynamic>> productByPlu = {};

    try {
      // 1. PRIMARY SOURCE: Use ItemsIssuedMap (explicit mappings)
      final itemsIssuedMap = await storage.getItemsIssuedMap();
      int mapCount = 0;

      for (var mapping in itemsIssuedMap) {
        final plu = mapping['PLU']?.toString().trim();

        // Try 'Product' first (mapped app product name), fallback to 'Menu Item'
        final productName = mapping['Product']?.toString().trim() ??
            mapping['Menu Item']?.toString().trim();

        if (plu != null && plu.isNotEmpty && productName != null && productName.isNotEmpty) {
          productByPlu[plu] = {
            'productName': productName,
            'source': 'ItemsIssuedMap'
          };
          mapCount++;
        }
      }
      print('  📊 ItemsIssuedMap contributed $mapCount entries');

      // 2. SECONDARY SOURCE: Use ItemsIssued as fallback for any missing PLUs
      final itemsIssued = await storage.getItemsIssued();
      int issuedCount = 0;

      for (var issue in itemsIssued) {
        final plu = issue['PLU']?.toString().trim();
        final menuItem = issue['Menu Item']?.toString().trim();

        // Only add if not already in the map (prioritize explicit mappings)
        if (plu != null && plu.isNotEmpty && menuItem != null && menuItem.isNotEmpty) {
          if (!productByPlu.containsKey(plu)) {
            productByPlu[plu] = {
              'productName': menuItem,
              'source': 'ItemsIssued'
            };
            issuedCount++;
          }
        }
      }
      print('  📊 ItemsIssued contributed $issuedCount additional entries');

      // 3. TERTIARY SOURCE: StockIssues as last resort
      final stockIssues = await storage.getStockIssues();
      int stockCount = 0;

      for (var issue in stockIssues) {
        final item = issue['Item']?.toString().trim();
        final name = issue['Name']?.toString().trim();

        if (item != null && item.isNotEmpty && name != null && name.isNotEmpty) {
          if (!productByPlu.containsKey(item)) {
            productByPlu[item] = {
              'productName': name,
              'source': 'StockIssues'
            };
            stockCount++;
          }
        }
      }
      print('  📊 StockIssues contributed $stockCount entries');

      print('  📊 TOTAL PLU lookup entries: ${productByPlu.length}');

    } catch (e) {
      print('  ⚠️ Could not build combined PLU lookup: $e');
    }

    return productByPlu;
  }

  //=========================================================================
  // HELPER METHODS - UI FEEDBACK
  //=========================================================================
  // TODO: Add helper methods for consistent UI feedback
  // Example: _showProgressDialog(), _showConfirmationDialog(), _showErrorDialog()

  void _safeShowSnackBar(String message, {Color backgroundColor = Colors.blue}) {
    if (!_isMounted()) return;
    print('DEBUG: Showing snackbar: $message');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  void _showProgressDialogForLargeFile(int itemCount) {
    // 🔴 CHANGED from 5 to 20.
    // Small files match instantly, no dialog needed.
    if (itemCount > 20 && _isMounted()) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Matching Products...'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Processing $itemCount items...'),
            ],
          ),
        ),
      );
    }
  }

  Future<Map<String, dynamic>?> _showProductSelectionDialog(
      BuildContext context,
      String searchTerm,
      List<Map<String, dynamic>> matches,
      ) async {
    final TextEditingController searchController = TextEditingController();
    List<Map<String, dynamic>> filtered = List.from(matches);

    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Match: "$searchTerm"',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: searchController,
                  autofocus: false,
                  decoration: const InputDecoration(
                    hintText: 'Filter results...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  ),
                  onChanged: (val) {
                    setDialogState(() {
                      filtered = val.isEmpty
                          ? List.from(matches)
                          : matches.where((p) {
                        final name = p['Inventory Product Name']
                            ?.toString()
                            .toLowerCase() ??
                            '';
                        return name.contains(val.toLowerCase());
                      }).toList();
                    });
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  '${filtered.length} of ${matches.length} results',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: filtered.isEmpty
                  ? const Center(child: Text('No results match your filter'))
                  : ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final product = filtered[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    child: ListTile(
                      dense: true,
                      title: Text(
                        product['Inventory Product Name'] ?? 'Unknown',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        'Category: ${product['Category'] ?? 'N/A'}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () => Navigator.pop(context, product),
                    ),
                  );
                },
              ),
            ),
            actions: [
              // Skip this item entirely — leaves it unlinked
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Skip'),
              ),
              // None of the fuzzy suggestions are right — open the full browser
              OutlinedButton.icon(
                icon: const Icon(Icons.search, size: 16),
                label: const Text('Browse All'),
                onPressed: () => Navigator.pop(context, const {'__browse_all__': true}),
              ),
            ],
          );
        },
      ),
    );
  }

  // REPLACE the existing _showFullProductBrowser:
  Future<Map<String, dynamic>?> _showFullProductBrowser(
      BuildContext context,
      String searchTerm,
      ) async {
    final storage = context.read<OfflineStorage>();
    final allInventory = await storage.getAllInventory();
    final TextEditingController searchController =
    TextEditingController(text: searchTerm);
    List<Map<String, dynamic>> filtered = allInventory.where((p) {
      final name = p['Inventory Product Name']?.toString().toLowerCase() ?? '';
      return name.contains(searchTerm.toLowerCase());
    }).toList();

    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Search inventory for: "$searchTerm"',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Type to search all products...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                    EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  ),
                  onChanged: (val) {
                    setDialogState(() {
                      filtered = val.isEmpty
                          ? allInventory
                          : allInventory.where((p) {
                        final name =
                            p['Inventory Product Name']
                                ?.toString()
                                .toLowerCase() ??
                                '';
                        return name.contains(val.toLowerCase());
                      }).toList();
                    });
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  '${filtered.length} products',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: filtered.isEmpty
                  ? const Center(
                  child: Text('No products found — try a different search'))
                  : ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final product = filtered[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    child: ListTile(
                      dense: true,
                      title: Text(
                        product['Inventory Product Name'] ?? 'Unknown',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        'Category: ${product['Category'] ?? 'N/A'}  |  Barcode: ${product['Barcode'] ?? 'N/A'}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () => Navigator.pop(context, product),
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<String?> _showNoMatchDialog(BuildContext context, String description) async {
    // Skip the intermediate dialog — go straight to the full browser
    // so the user can immediately search the entire inventory.
    // Returns 'skip', 'add_new', or null (user dismissed).
    final selectedProduct = await _showFullProductBrowser(context, description);

    if (selectedProduct == null) {
      // User closed the browser — ask skip or add new
      return showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Still no match for "$description"'),
          content: const Text('What would you like to do?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'skip'),
              child: const Text('Skip'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, 'add_new'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text('Add New Product'),
            ),
          ],
        ),
      );
    }

    // User picked a product from the browser — handle it inline
    // by returning a sentinel so the caller knows a product was chosen
    // We store the selection in a temporary field and signal via sentinel
    _noMatchBrowserSelection = selectedProduct;
    return 'browser_selected';
  }

  Future<bool> _showSaveMappingDialog(
      BuildContext context,
      ParsedGrvLineItem item,
      String supplierId,
      Map<String, dynamic> selectedProduct,
      ) async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save PLU Mapping?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CSV PLU: ${item.plu}'),
            Text('CSV Description: ${item.description}'),
            const Divider(),
            Text('Mapped to: ${selectedProduct['Inventory Product Name']}'),
            const SizedBox(height: 8),
            Text('Supplier: $supplierId'),
            const SizedBox(height: 16),
            const Text('This will auto-match this PLU in future imports.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
            ),
            child: const Text('Yes, Save Mapping'),
          ),
        ],
      ),
    ) ?? false;
  }

  Future<String?> _findPluForProduct(Map<String, dynamic> product) async {
    final storage = context.read<OfflineStorage>();
    final productName = product['Inventory Product Name']?.toString();
    if (productName == null) return null;

    // 1. Try ItemsIssued (which now acts as primary for Sales items)
    try {
      final itemsIssued = await storage.getItemsIssued();
      final match = itemsIssued.firstWhere(
            (issue) => _fuzzyMatch(issue['Menu Item']?.toString() ?? '', productName),
        orElse: () => <String, dynamic>{},
      );
      if (match.isNotEmpty && match['PLU'] != null) {
        print('✅ Found PLU in ItemsIssued: ${match['PLU']} for $productName');
        return match['PLU'].toString();
      }
    } catch (e) {
      print('⚠️ ItemsIssued lookup failed: $e');
    }

    // 2. Try StockIssues (for internal items)
    try {
      final stockIssues = await storage.getStockIssues();
      final match = stockIssues.firstWhere(
            (issue) => _fuzzyMatch(issue['Name']?.toString() ?? issue['Item']?.toString() ?? '', productName),
        orElse: () => <String, dynamic>{},
      );
      if (match.isNotEmpty && match['Item'] != null) {
        print('✅ Found PLU in StockIssues: ${match['Item']} for $productName');
        return match['Item'].toString();
      }
    } catch (e) {
      print('⚠️ StockIssues lookup failed: $e');
    }

    // 🔴 3. CRITICAL FALLBACK: Use Barcode! This ensures mappings ALWAYS save!
    print('✅ Falling back to Barcode for mapping: ${product['Barcode']}');
    return product['Barcode']?.toString() ?? 'MAPPED_${DateTime.now().millisecondsSinceEpoch}';
  }

  //=========================================================================
  // HELPER METHODS - UI BUILDERS
  //=========================================================================
  // TODO: Add helper methods for building UI components
  // Example: _buildHeaderCard(), _buildEmptyState(), _buildItemList()

  //=========================================================================
  // UNLINKED ITEM RESOLUTION
  //=========================================================================

  /// Shows a dialog listing each unlinked item with three actions:
  ///   • Link   — opens the full inventory browser so the user can map it
  ///   • Skip   — removes the item from the list (won't be saved)
  ///   • Save as-is — marks the item with description only (no inventory link)
  ///
  /// Returns [true] when the user has dealt with every item and is ready to
  /// proceed with saving, or [false] if they cancel the whole dialog.
  Future<bool> _resolveUnlinkedItems(List<GrvLineItemDisplay> unmapped) async {
    // Work on a snapshot so we can track which items still need action.
    final pending = List<GrvLineItemDisplay>.from(unmapped);

    for (final item in pending) {
      if (!_isMounted()) return false;

      // Ask the user what to do with this specific item.
      final action = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Unlinked Item'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This item is not linked to inventory:',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.description,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'What would you like to do?',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
          actions: [
            // Cancel the whole save operation
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            // Remove this item from the GRV entirely
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'skip'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Remove'),
            ),
            // Save with description only — no inventory linkage
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, 'save_as_is'),
              child: const Text('Save as-is'),
            ),
            // Open full product browser to link it now
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'link'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              child: const Text('Link'),
            ),
          ],
        ),
      );

      if (action == null || action == 'cancel') return false;

      if (action == 'skip') {
        // Remove item from the live list
        if (_isMounted()) {
          setState(() {
            _items.remove(item);
            _calculateTotal();
          });
        }
        continue;
      }

      if (action == 'save_as_is') {
        // Stamp the item so isMatched returns true with description-only data.
        // We use the description as a stand-in productName and a sentinel
        // barcode so the save loop won't filter it out.
        if (_isMounted()) {
          setState(() {
            final idx = _items.indexOf(item);
            if (idx != -1) {
              _items[idx]
                ..productName = item.description
                ..barcode = 'UNLINKED_${DateTime.now().millisecondsSinceEpoch}'
                ..matchedBy = 'save_as_is';
            }
          });
        }
        continue;
      }

      if (action == 'link') {
        // Open the full inventory browser inline.
        final selectedProduct = await _showFullProductBrowser(context, item.description);

        if (selectedProduct != null && _isMounted()) {
          final productName = selectedProduct['Inventory Product Name']?.toString();
          final barcode = selectedProduct['Barcode']?.toString();

          // Try to look up the supplierBottleID from MasterCosts
          String? supplierBottleID;
          try {
            final storage = context.read<OfflineStorage>();
            final allSuppliers = await storage.getMasterSuppliers();
            final supplierID = _findSupplierId(allSuppliers);
            if (supplierID != null && productName != null) {
              final allMasterCosts = await storage.getMasterCosts();
              final costKey = '$supplierID|${productName.toLowerCase().trim()}';
              final costMatch = allMasterCosts.firstWhere(
                    (c) =>
                '${ c['supplierID']}|${c['Product Name']?.toString().toLowerCase().trim()}' == costKey,
                orElse: () => <String, dynamic>{},
              );
              if (costMatch.isNotEmpty) {
                supplierBottleID = costMatch['supplierBottleID']?.toString();
              }
            }
          } catch (_) {}

          setState(() {
            final idx = _items.indexOf(item);
            if (idx != -1) {
              _items[idx]
                ..productName = productName
                ..barcode = barcode
                ..supplierBottleID = supplierBottleID
                ..matchedBy = 'manual_browser';
            }
          });

          // Offer to save the PLU mapping for next time
          try {
            final storage = context.read<OfflineStorage>();
            final allSuppliers = await storage.getMasterSuppliers();
            final supplierID = _findSupplierId(allSuppliers);
            if (supplierID != null && (item.plu?.isNotEmpty ?? false) && productName != null) {
              final shouldSave = await _showSaveMappingDialog(
                context,
                item.toParsedLineItem(),
                supplierID,
                selectedProduct,
              );
              if (shouldSave) {
                final correctPlu = await _findPluForProduct(selectedProduct);
                if (correctPlu != null) {
                  final mapping = PluMapping(
                    csvPlu: item.plu!,
                    csvDescription: item.description,
                    correctPlu: correctPlu,
                    productName: productName,
                    supplierId: supplierID,
                    createdAt: DateTime.now(),
                  );
                  await storage.savePluMapping(mapping);
                  print('    💾 [MAPPING SAVED from resolution] ${item.plu} -> $correctPlu');
                }
              }
            }
          } catch (e) {
            print('⚠️ Could not save mapping during resolution: $e');
          }
        } else {
          // User dismissed the browser without selecting — ask again next loop
          // by re-inserting the item at the front of pending. Instead, we just
          // leave it unmatched and the outer save loop will silently skip it
          // (it won't pass the isMatched filter).  Show a snackbar so the user
          // knows it will be excluded.
          _safeShowSnackBar(
            '⚠️ "${item.description}" skipped — no product selected',
            backgroundColor: Colors.orange,
          );
        }
        continue;
      }
    }

    return true; // All items processed — proceed with save
  }

  Widget _buildSaveButton() {
    if (_isLoading) {
      return FloatingActionButton(
        onPressed: null,
        child: const CircularProgressIndicator(color: Colors.white),
      );
    }

    return FloatingActionButton.extended(
      onPressed: _saveAllItems,
      icon: const Icon(Icons.save),
      label: Text(
        _items.isEmpty ? 'SAVE 0 ITEMS' : 'SAVE ${_items.length} ITEMS',
        style: const TextStyle(fontSize: 16),
      ),
      backgroundColor: _items.isEmpty ? Colors.grey : Colors.green,
    );
  }

  //=========================================================================
  // CORE BUSINESS LOGIC - AUTO MATCHING
  //=========================================================================
  // TODO: Add helper methods to break down the matching logic
  // Example: _buildLookupMaps(), _processBatch(), _findBestMatch(), _lookupCost()

  Future<void> _autoMatchPluItems(
      List<ParsedGrvLineItem> items, {
        String? invoiceId,
      }) async {
    print('DEBUG: _autoMatchPluItems() called with ${items.length} items');
    if (!_isMounted()) return;
    setState(() => _isMatching = true);

    // 1. Only shows if > 20 items
    _showProgressDialogForLargeFile(items.length);

    final matchedItems = <GrvLineItemDisplay>[];
    int matchedCount = 0;

    try {
      final lookups = await _buildLookupMaps();

      final productByPlu = lookups['productByPlu'] as Map<String, Map<String, dynamic>>;
      final productByName = lookups['productByName'] as Map<String, Map<String, dynamic>>;
      final costsBySupplierAndProduct = lookups['costsBySupplierAndProduct'] as Map<String, Map<String, dynamic>>;
      final allSuppliers = lookups['allSuppliers'] as List<Map<String, dynamic>>;

      // Use the provided invoice ID or fallback to widget
      final effectiveInvoiceId = invoiceId ?? widget.invoiceDetailsID;
      print('📌 Using invoice ID: $effectiveInvoiceId');

      for (var i = 0; i < items.length; i++) {
        if (!_isMounted()) return;

        print('  🔄 Processing item ${i + 1}/${items.length}: "${items[i].description}"');

        final result = await _matchSingleItem(
          items[i],
          productByPlu,
          productByName,
          costsBySupplierAndProduct,
          allSuppliers,
        );

        matchedItems.add(result);
        if (result.isMatched) matchedCount++;

        // Update UI after each item so user sees progress
        if (_isMounted()) setState(() {});
      }
    } catch (e) {
      print('❌ Error during matching: $e');
    }

    if (!_isMounted()) return;

    // 2. Close progress dialog if it was opened
    if (items.length > 20) {
      Navigator.pop(context);
    }

    setState(() {
      _items.clear();
      _items.addAll(matchedItems);
      _calculateTotal();
      _isMatching = false;
    });

    // 3. Show notification that items are ready for review
    if (mounted) {
      _safeShowSnackBar(
        '✓ ${matchedItems.length} items ready for review. Tap SAVE to confirm.',
        backgroundColor: Colors.blue,
      );
    }
  }

  /// Generate an 8-character ID for new invoices
  String _generateInvoiceId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = math.Random();
    return String.fromCharCodes(Iterable.generate(
        8, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }

  //=========================================================================
  // CORE BUSINESS LOGIC - SAVE OPERATIONS
  //=========================================================================
  // TODO: Add helper methods for save operations
  // Example: _buildPurchaseMap(), _validateItem(), _updateInvoiceTotal()

  Future<void> _saveAllItems() async {
    print('DEBUG: _saveAllItems() called');
    print('  - Total items to save: ${_items.length}');
    print('  - Current invoice ID: ${_currentInvoiceId ?? widget.invoiceDetailsID}');
    print('  - GRV Reference: ${widget.grvReference}');  // 🔥 DEBUG

    if (!_isMounted()) return;

    if (_items.isEmpty) {
      print('DEBUG: No items to save');
      _safeShowSnackBar('⚠️ No items to save');
      return;
    }

    // Check for unmatched items and let the user resolve them before saving:
    final unmappedItems = _items.where((i) => !i.isMatched).toList();
    print('DEBUG: Unmapped items: ${unmappedItems.length}');

    if (unmappedItems.isNotEmpty) {
      final resolved = await _resolveUnlinkedItems(unmappedItems);
      if (!resolved) {
        return;
      }
      if (_items.isEmpty) {
        _safeShowSnackBar('⚠️ No items left to save', backgroundColor: Colors.orange);
        return;
      }
    }

    if (!_isMounted()) return;
    setState(() => _isLoading = true);

    try {
      final storage = context.read<OfflineStorage>();

      // Use the correct invoice ID
      final effectiveInvoiceId = _currentInvoiceId ?? widget.invoiceDetailsID;
      print('🔍 Using invoice ID: $effectiveInvoiceId');

      var invoice = await storage.getInvoiceDetails(effectiveInvoiceId);

      if (invoice == null) {
        print('ERROR: Invoice details not found for ID: $effectiveInvoiceId');

        // Try to create the invoice if it doesn't exist
        final supplierId = await _getSupplierId();
        final invoiceData = {
          'invoiceDetailsID': effectiveInvoiceId,
          'Invoice Number': _extractInvoiceNumber(),
          'GRV Reference': widget.grvReference,  // 🔥 ADD GRV TO INVOICE
          'supplierID': supplierId,
          'Supplier Name': widget.supplierName,
          'Date of Purchase': widget.deliveryDate.toIso8601String(),
          'Delivery Date': widget.deliveryDate.toIso8601String(),
          'Total Cost Ex Vat': 0.0,
          'syncStatus': 'pending',
        };
        await storage.saveInvoiceDetails(invoiceData);
        invoice = await storage.getInvoiceDetails(effectiveInvoiceId);

        if (invoice == null) {
          throw Exception('Invoice details not found for ID: $effectiveInvoiceId');
        }
      }

      print('DEBUG: Found invoice: ${invoice['Invoice Number']}');

      // 🔥🔥🔥 GRV DIAGNOSTIC 🔥🔥🔥
      print('🔥🔥🔥 GRV DIAGNOSTIC 🔥🔥🔥');
      print('  widget.grvReference = "${widget.grvReference}"');
      print('  widget.grvReference.isEmpty = ${widget.grvReference.isEmpty}');
      print('  effectiveInvoiceId = "$effectiveInvoiceId"');
      print('  invoice?["GRV Reference"] = "${invoice['GRV Reference']}"');

      // 🔥 FALLBACK: If widget.grvReference is empty, try to get it from invoice
      String grvToUse = widget.grvReference;
      if (grvToUse.isEmpty) {
        grvToUse = invoice['GRV Reference']?.toString() ?? '';
        if (grvToUse.isNotEmpty) {
          print('✅ Using GRV from invoice: "$grvToUse"');
        } else {
          print('⚠️ WARNING: No GRV found anywhere! Purchases will be created without GRV.');
        }
      }

      print('DEBUG: Saving ${_items.length} items...');

      // BUILD PURCHASE LIST FOR MERGE
      final purchasesToSave = <Map<String, dynamic>>[];
      int lineIndex = 0;

      final matchedItems = _items.where((item) => item.isMatched).toList();
      print('DEBUG: Processing ${matchedItems.length} matched items');

      for (var item in matchedItems) {
        if (!_isMounted()) return;

        print('DEBUG: Saving item - Product: ${item.productName}, Quantity: ${item.quantityCases}, Price: ${item.pricePerUnit}');

        Map<String, dynamic>? productDetails;
        if (item.productName != null) {
          productDetails = await _getProductDetailsByName(item.productName!);
        }

        final String productKey = item.plu?.isNotEmpty == true
            ? item.plu!
            : (item.barcode?.isNotEmpty == true ? item.barcode! : 'unknown');

        // 🔥 DEBUG: Check what grvToUse actually contains
        print('🔥🔥🔥 CRITICAL CHECK: grvToUse = "$grvToUse"');
        print('🔥🔥🔥 grvToUse.isEmpty = ${grvToUse.isEmpty}');

        if (grvToUse.isEmpty) {
          // 🔥 Force a value
          grvToUse = 'NOGRV';
          print('⚠️ Forcing grvToUse to "$grvToUse"');
        }

        final String purchaseId = 'purchase_${effectiveInvoiceId}_${grvToUse}_${productKey}_line$lineIndex';
        print('🔥 FINAL purchaseId: "$purchaseId"');

        final purchase = {
          'purchases_ID': purchaseId,
          'invoiceDetailsID': effectiveInvoiceId,
          'GRV Reference': grvToUse,  // 🔥 CRITICAL: Include GRV using grvToUse
          'Invoice Nr.': invoice['Invoice Number']?.toString() ?? '',
          'Inv. Date of Purchase': invoice['Date of Purchase']?.toString() ?? widget.deliveryDate.toIso8601String(),
          'supplierID': invoice['supplierID'] ?? '',
          'Supplier': widget.supplierName,
          'Barcode': item.barcode ?? productDetails?['Barcode'] ?? '',
          'Purchased Product Name': item.productName!,
          'supplierBottleID': item.supplierBottleID ?? '',
          'purSupplierBottleID': item.supplierBottleID ?? '',
          'plu': item.plu ?? '',
          'Main Category': productDetails?['Main Category'] ?? '',
          'Category': productDetails?['Category'] ?? '',
          'Single Unit Volume': productDetails?['Single Unit Volume'] ?? 0,
          'UoM': productDetails?['UoM'] ?? '',
          'Cost Per Bottle': item.pricePerUnit,
          'Stock Delivery Date': widget.deliveryDate.toIso8601String(),
          'Case/Pack Size': 'Case ${item.unitsPerCase}',
          'Qty Purchased': item.quantityCases.toDouble(),
          'Purchases Bottles': item.totalUnits.toDouble(),
          'Purchase Units': 0,
          'Cost of Purchases': item.totalValue,
          'syncStatus': 'pending',
        };

        purchasesToSave.add(purchase);
        lineIndex++;
      }

      // UPDATE INVOICE TOTAL
      final updatedInvoiceData = {...invoice, 'Total Cost Ex Vat': _totalValue};
      await storage.saveInvoiceDetails(updatedInvoiceData);
      print('DEBUG: Invoice total updated to: $_totalValue');

      // SAVE PURCHASES
      if (purchasesToSave.isNotEmpty) {
        print('DEBUG: Using merge strategy to save ${purchasesToSave.length} purchases');
        await storage.savePurchasesWithMerge(
          invoiceId: effectiveInvoiceId,
          newPurchases: purchasesToSave,
        );
      }

      if (_isMounted()) {
        print('DEBUG: Save completed successfully - ${purchasesToSave.length} items merged');
        if (Navigator.canPop(context)) {
          Navigator.pop(context, true);
        }
        _safeShowSnackBar('✓ Saved ${purchasesToSave.length} items to Purchases');
      }
    } catch (e) {
      print('ERROR: Save operation failed: $e');
      _safeShowSnackBar('Save failed: ${e.toString().split('\n').first}', backgroundColor: Colors.red);
    } finally {
      if (_isMounted()) setState(() => _isLoading = false);
    }
  }

  /// Helper to get supplier ID
  Future<String> _getSupplierId() async {
    final storage = context.read<OfflineStorage>();
    // 🔥 FIX: Use cached version
    final suppliers = await storage.getMasterSuppliersCached();
    final match = suppliers.firstWhere(
          (s) => s['Supplier']?.toString() == widget.supplierName,
      orElse: () => <String, dynamic>{},
    );
    return match['supplierID']?.toString() ?? '';
  }

  /// Helper to extract invoice number from items
  String _extractInvoiceNumber() {
    // Try to get from preloaded items
    if (widget.preloadedItems != null && widget.preloadedItems!.isNotEmpty) {
      // Use the first item's PLU or description as fallback
      return 'GRV_${DateTime.now().millisecondsSinceEpoch}';
    }
    return 'GRV_${DateTime.now().millisecondsSinceEpoch}';
  }

  //=========================================================================
  // NAVIGATION & USER FLOW
  //=========================================================================
  // TODO: Add helper methods for navigation and result handling
  // Example: _handleManualEntryResult(), _navigateToScreen()

  void _startManualEntry() async {
    print('DEBUG: _startManualEntry() called');
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GrvAddLineItemScreen(
          invoiceDetailsID: widget.invoiceDetailsID,
          supplierName: widget.supplierName,
          deliveryDate: widget.deliveryDate,
          grvReference: widget.grvReference,
        ),
      ),
    );

    print('DEBUG: Received result type: ${result.runtimeType}');
    print('DEBUG: Result value: $result');

    if (result is GrvLineItemDisplay) {
      print('DEBUG: Successfully received item: ${result.description}');
      _addItemSafely(result);
    } else {
      print('DEBUG: No item returned from manual entry screen');
      if (result != null) {
        print('DEBUG: Result was not GrvLineItemDisplay, it was: ${result.runtimeType}');
      }
    }
  }

  //=========================================================================
  // ITEM MANAGEMENT
  //=========================================================================
  // TODO: Add helper methods for managing items in the list
  // Example: _validateItem(), _checkDuplicate(), _updateItemQuantity()

  void _addItemSafely(GrvLineItemDisplay newItem) {
    if (!_isMounted()) return;

    final isDuplicate = _items.any((item) {
      if (item.productName == newItem.productName && item.plu == newItem.plu) {
        return true;
      }
      if (item.barcode != null &&
          newItem.barcode != null &&
          item.barcode == newItem.barcode) {
        return true;
      }
      return false;
    });

    if (isDuplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ ${newItem.description} already exists in list'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'ADD ANYWAY',
            textColor: Colors.white,
            onPressed: () {
              if (!_isMounted()) return;
              setState(() {
                _items.add(newItem);
                _calculateTotal();
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('✓ Added ${newItem.description}'),
                  backgroundColor: Colors.green,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
        ),
      );
      return;
    }

    setState(() {
      _items.add(newItem);
      _calculateTotal();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✓ Added ${newItem.description}'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  //=========================================================================
  // BUILD METHOD
  //=========================================================================
  @override
  Widget build(BuildContext context) {
    print('DEBUG: GrvLineItemsScreen.build() called - Items: ${_items.length}, Total Value: $_totalValue');

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text('GRV: ${widget.supplierName}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                widget.deliveryDate.toIso8601String().split('T')[0],
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Card
            Container(
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Supplier: ${widget.supplierName}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('Delivery: ${widget.deliveryDate.toIso8601String().split('T')[0]}', style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${_items.length} items', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('R${_totalValue.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.green)),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ADD ITEM Button (only button)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _startManualEntry,
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('ADD ITEM', style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Items List
            _items.isEmpty
                ? Center(
              child: Column(
                children: [
                  Icon(Icons.inventory_2, size: 48, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text('No items added yet',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Text('Tap ADD ITEM to start',
                      style:
                      TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            )
                : _buildItemsTable(),

            const SizedBox(height: 24),
          ],
        ),
      ),
      floatingActionButton: _buildSaveButton(),
    );
  }
  Widget _buildItemsTable() {
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);

    if (!isDesktop) {
      // Mobile: keep original card/list style
      return ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor:
                item.isMatched ? Colors.green.shade100 : Colors.red.shade100,
                child: Text(
                  item.plu?.substring(0, math.min(2, item.plu?.length ?? 0)) ??
                      '?',
                  style: TextStyle(
                    color: item.isMatched
                        ? Colors.green.shade900
                        : Colors.red.shade900,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Text(item.description),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '${item.quantityCases} × ${item.unitsPerCase} @ R${item.pricePerUnit.toStringAsFixed(2)}/unit'),
                  if (!item.isMatched)
                    Text('⚠️ Unmatched',
                        style: TextStyle(color: Colors.red)),
                ],
              ),
              trailing: Text('R${item.totalValue.toStringAsFixed(2)}',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          );
        },
      );
    }

    // Desktop: full data table
    return SizedBox(
      height: math.max(200, _items.length * 52.0 + 56),
      child: DataTable2(
        columnSpacing: 12,
        horizontalMargin: 12,
        minWidth: 700,
        headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),
        columns: const [
          DataColumn2(label: Text('Status'), fixedWidth: 72),
          DataColumn2(label: Text('PLU'), fixedWidth: 72),
          DataColumn2(label: Text('Description'), size: ColumnSize.L),
          DataColumn2(label: Text('Cases'), fixedWidth: 70, numeric: true),
          DataColumn2(label: Text('Units'), fixedWidth: 70, numeric: true),
          DataColumn2(label: Text('Price/Unit'), fixedWidth: 90, numeric: true),
          DataColumn2(label: Text('Total'), fixedWidth: 100, numeric: true),
          DataColumn2(label: Text(''), fixedWidth: 48),
        ],
        rows: List<DataRow>.generate(_items.length, (index) {
          final item = _items[index];
          return DataRow(
            cells: [
              // Status
              DataCell(
                Icon(
                  item.isMatched ? Icons.check_circle : Icons.warning_amber,
                  color: item.isMatched ? Colors.green : Colors.orange,
                  size: 18,
                ),
              ),
              // PLU
              DataCell(Text(
                item.plu ?? '—',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              )),
              // Description
              DataCell(Text(
                item.description,
                overflow: TextOverflow.ellipsis,
              )),
              // Cases
              DataCell(Text(item.quantityCases.toString())),
              // Units
              DataCell(Text(item.unitsPerCase.toString())),
              // Price per unit
              DataCell(Text(
                'R${item.pricePerUnit.toStringAsFixed(2)}',
              )),
              // Total
              DataCell(Text(
                'R${item.totalValue.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              )),
              // Edit/delete actions
              DataCell(
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (value) {
                    if (value == 'edit') {
                      _editItem(index);
                    } else if (value == 'delete') {
                      setState(() {
                        _items.removeAt(index);
                        _calculateTotal();
                      });
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  void _editItem(int index) async {
    final item = _items[index];
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GrvAddLineItemScreen(
          invoiceDetailsID: widget.invoiceDetailsID,
          supplierName: widget.supplierName,
          deliveryDate: widget.deliveryDate,
          initialItem: item, grvReference: '',
        ),
      ),
    );

    if (result is GrvLineItemDisplay) {
      setState(() {
        _items[index] = result;
        _calculateTotal();
      });
    }
  }
}