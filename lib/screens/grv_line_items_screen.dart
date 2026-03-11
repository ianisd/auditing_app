import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
  final List<ParsedGrvLineItem>? preloadedItems;

  const GrvLineItemsScreen({
    super.key,
    required this.invoiceDetailsID,
    required this.supplierName,
    required this.deliveryDate,
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

      // Handle arguments passed from Upload Screen
      if (args == null && widget.preloadedItems != null && widget.preloadedItems!.isNotEmpty) {

        // 🔴 FIX: Wait for the build to finish before running logic!
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _autoMatchPluItems(widget.preloadedItems!);
          }
        });

      }

      _hasInitialized = true;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  bool _isMounted() => mounted && !_isDisposed;

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
    final allSuppliers = await storage.getMasterSuppliers();
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
        // 🔴 FIX: Trust the saved mapping directly! Bypass strict validation.
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
      if (productName == null && productByPlu.containsKey(item.plu)) {
        final pluMatch = productByPlu[item.plu];
        productName = pluMatch?['productName']?.toString();
        matchedPlu = item.plu;
        matchedBy = 'plu_direct';
        print('    ✅ [PLU DIRECT] ${item.plu} -> $productName');
      }
    }

    // ------------------------------------------------------------------------
    // PHASE 2: Try fuzzy matching with scoring
    // ------------------------------------------------------------------------
    if (productName == null) {
      print('    🔍 [FUZZY] Attempting to match: "${item.description}"');

      final matches = _findBestProductMatches(item.description, productByName);

      if (matches.isNotEmpty) {
        if (matches.length == 1) {
          // Single clear match
          productName = matches.first['Inventory Product Name']?.toString();
          matchedBy = 'fuzzy_single';
          print('    ✅ [FUZZY] Single match: "$productName"');
        } else {
          // Multiple possible matches - MUST show dialog and wait
          print('    ⚠️ [FUZZY] ${matches.length} possible matches - showing dialog');

          // Use await directly - don't check _isMounted() here
          final selectedProduct = await _showProductSelectionDialog(
            context,
            item.description,
            matches,
          );

          if (selectedProduct != null) {
            productName = selectedProduct['Inventory Product Name']?.toString();
            barcode = selectedProduct['Barcode']?.toString();
            matchedBy = 'manual_selection';
            print('    ✅ [MANUAL] User selected: "$productName"');

            // Offer to save mapping
            if (supplierID != null && item.plu.isNotEmpty) {
              final shouldSave = await _showSaveMappingDialog(
                context,
                item,
                supplierID,
                selectedProduct,
              );

              if (shouldSave) {
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
            print('    ⚠️ [MANUAL] User cancelled selection');
          }
        }
      } else {
        print('    ❌ [FUZZY] No matches found');

        if (_isMounted()) {
          // Show options: Try again or Add New Product
          final String? action = await _showNoMatchDialog(context, item.description);

          if (action == 'add_new') {
            print('    ➕ User chose to add new product');
            // Navigate to AddProductScreen
            final newProduct = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => AddProductScreen(
                  initialName: item.description, // Pre-fill with CSV description
                ),
              ),
            );

            if (newProduct != null && newProduct is Map<String, dynamic>) {
              productName = newProduct['Inventory Product Name']?.toString();
              barcode = newProduct['Barcode']?.toString();
              matchedBy = 'new_product';
              print('    ✅ New product created: "$productName"');

              // Save mapping if PLU exists
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
          } else if (action == 'search_again') {
            print('    🔍 User chose to search again');
            // Show full product browser
            final selectedProduct = await _showFullProductBrowser(
              context,
              item.description,
            );

            if (selectedProduct != null) {
              productName = selectedProduct['Inventory Product Name']?.toString();
              barcode = selectedProduct['Barcode']?.toString();
              matchedBy = 'manual_browser';
              print('    ✅ Selected from browser: "$productName"');

              // Save mapping if PLU exists
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
                }
              }
            }
          } else {
            print('    ⏭️ User chose to skip');
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
        int maxResults = 5,
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

    return scored.take(maxResults).map((e) => e.key).toList();
  }

  // Add this method near the other helper methods (around line 200)
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
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Select Product for "$searchTerm"'),
        content: Container(
          width: double.maxFinite,
          constraints: const BoxConstraints(maxHeight: 400),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: matches.length,
            itemBuilder: (context, index) {
              final product = matches[index];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(product['Inventory Product Name'] ?? 'Unknown'),
                  subtitle: Text('Category: ${product['Category'] ?? 'N/A'}'),
                  onTap: () => Navigator.pop(context, product),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Skip'),
          ),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>?> _showFullProductBrowser(
      BuildContext context,
      String searchTerm,
      ) async {
    final storage = context.read<OfflineStorage>();
    final allInventory = await storage.getAllInventory();

    // Filter by search term
    final filtered = allInventory.where((p) {
      final name = p['Inventory Product Name']?.toString().toLowerCase() ?? '';
      return name.contains(searchTerm.toLowerCase());
    }).toList();

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Search Products: "$searchTerm"'),
        content: Container(
          width: double.maxFinite,
          height: 400,
          child: filtered.isEmpty
              ? const Center(child: Text('No products found'))
              : ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final product = filtered[index];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(product['Inventory Product Name'] ?? 'Unknown'),
                  subtitle: Text('Barcode: ${product['Barcode'] ?? 'N/A'}'),
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
      ),
    );
  }

  Future<String?> _showNoMatchDialog(BuildContext context, String description) async {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('No matches for "$description"'),
        content: const Text('What would you like to do?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'skip'),
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'search_again'),
            child: const Text('Search Again'),
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

  Future<void> _autoMatchPluItems(List<ParsedGrvLineItem> items) async {
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

      const batchSize = 5;
      for (var i = 0; i < items.length; i += batchSize) {
        if (!_isMounted()) return;

        final batch = items.skip(i).take(batchSize).toList();
        print('  🔄 Processing batch ${i ~/ batchSize + 1}/${(items.length / batchSize).ceil()}');

        final batchResults = await Future.wait(
          batch.map((item) => _matchSingleItem(
            item,
            productByPlu,
            productByName,
            costsBySupplierAndProduct,
            allSuppliers,
          )),
        );

        matchedItems.addAll(batchResults);
        matchedCount += batchResults.where((item) => item.isMatched).length;

        // Optional: Update UI for really large batches
        if (items.length > 50 && _isMounted()) {
          setState(() {});
        }
      }
    } catch (e) {
      print('❌ Error during matching: $e');
    }

    if (!_isMounted()) return;

    // 2. 🔴 CRITICAL FIX: Ensure this number matches the one in _showProgressDialogForLargeFile
    // If it opened for > 20, it must close for > 20.
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

  //=========================================================================
  // CORE BUSINESS LOGIC - SAVE OPERATIONS
  //=========================================================================
  // TODO: Add helper methods for save operations
  // Example: _buildPurchaseMap(), _validateItem(), _updateInvoiceTotal()

  Future<void> _saveAllItems() async {
    print('DEBUG: _saveAllItems() called');
    print('  - Total items to save: ${_items.length}');

    if (!_isMounted()) return;

    if (_items.isEmpty) {
      print('DEBUG: No items to save');
      _safeShowSnackBar('⚠️ No items to save');
      return;
    }

    final unmappedCount = _items.where((i) => !i.isMatched).length;
    print('DEBUG: Unmapped items: $unmappedCount');

    if (unmappedCount > 0) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Unmapped Items'),
          content: Text('$unmappedCount item(s) not linked to inventory.\n\nSave mapped items only?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save Mapped Items'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            ),
          ],
        ),
      );
      if (confirm != true) {
        print('DEBUG: Save operation cancelled by user');
        return;
      }
    }

    if (!_isMounted()) return;
    setState(() => _isLoading = true);

    try {
      final storage = context.read<OfflineStorage>();
      final invoice = await storage.getInvoiceDetails(widget.invoiceDetailsID);

      if (invoice == null) {
        print('ERROR: Invoice details not found for ID: ${widget.invoiceDetailsID}');
        throw Exception('Invoice details not found');
      }

      print('DEBUG: Found invoice: ${invoice['Invoice Number']}');
      print('DEBUG: Saving ${_items.length} items...');

      int savedCount = 0;
      const batchSize = 20;

      for (var i = 0; i < _items.length; i += batchSize) {
        if (!_isMounted()) return;

        final batch = _items.skip(i).take(batchSize).where((item) =>
        item.isMatched).toList();
        print('DEBUG: Processing batch ${i ~/ batchSize + 1} with ${batch
            .length} items');

        int batchItemCounter = 0;
        for (var item in batch) {
          if (!_isMounted()) return;

          print('DEBUG: Saving item - Product: ${item
              .productName}, Quantity: ${item.quantityCases}, Price: ${item
              .pricePerUnit}');

          // Get product details using cached helper method
          Map<String, dynamic>? productDetails;
          if (item.productName != null) {
            productDetails = await _getProductDetailsByName(item.productName!);
          }

          // 🔴 STABLE ID GENERATION
          // Use invoice ID + product identifier to create a stable, repeatable ID
          final String productKey = item.plu ??
              item.barcode ??
              item.productName?.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '') ??
              'item_$batchItemCounter';

          final String purchaseId = 'purchase_${widget
              .invoiceDetailsID}_$productKey';

          final purchase = {
            'purchases_ID': purchaseId,
            // Stable ID that won't change between syncs
            'invoiceDetailsID': widget.invoiceDetailsID,
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

          await storage.savePurchase(purchase);
          savedCount++;
          batchItemCounter++;

          print('DEBUG: Purchase saved - ID: ${purchase['purchases_ID']}');
          print('DEBUG:   supplierBottleID: ${purchase['supplierBottleID']}');
          if (productDetails != null) {
            print(
                'DEBUG:   Category: ${productDetails['Category']}, Volume: ${productDetails['Single Unit Volume']}');
          }
        }

        if (i + batchSize < _items.length) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }

      await storage.saveInvoiceDetails({...invoice, 'Total Cost Ex Vat': _totalValue});
      print('DEBUG: Invoice total updated to: $_totalValue');

      if (_isMounted()) {
        print('DEBUG: Save completed successfully - $savedCount items saved');
        Navigator.pop(context, true);
        _safeShowSnackBar('✓ Saved $savedCount items to Purchases');
      }
    } catch (e) {
      print('ERROR: Save operation failed: $e');
      _safeShowSnackBar('Save failed: ${e.toString().split('\n').first}', backgroundColor: Colors.red);
    } finally {
      if (_isMounted()) setState(() => _isLoading = false);
    }
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
      appBar: AppBar(title: const Text('GRV: Line Items')),
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
                  Text('No items added yet', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Text('Tap ADD ITEM to start', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            )
                : ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: item.isMatched ? Colors.green.shade100 : Colors.red.shade100,
                      child: Text(
                        item.plu?.substring(0, math.min(2, item.plu?.length ?? 0)) ?? '?',
                        style: TextStyle(
                          color: item.isMatched ? Colors.green.shade900 : Colors.red.shade900,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(item.description),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${item.quantityCases} × ${item.unitsPerCase} @ R${item.pricePerUnit.toStringAsFixed(2)}/unit'),
                        if (!item.isMatched) Text('⚠️ Unmatched', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                    trailing: Text('R${item.totalValue.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                );
              },
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
      floatingActionButton: _buildSaveButton(),
    );
  }
}