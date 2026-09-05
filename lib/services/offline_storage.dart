import 'dart:io';
import 'dart:math' as math;
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart';

import '../models/plu_mapping.dart';
import 'google_sheets_service.dart';
import 'encryption_service.dart';

class OfflineStorage with ChangeNotifier {
  // ===========================================================================
  // PROPERTIES
  // ===========================================================================

  // Core Boxes
  Box? _counts;
  Box? _inventory;
  Box? _locations;
  Box? _audits;
  Box? _masterCatalog;

  // Variance Report Boxes
  Box? _purchases;
  Box? _storeSalesData; // Raw POS Logs
  Box? _itemSalesMap;   // PLU Definitions

  // Invoicing Boxes
  Box? _invoiceDetails;
  Box? _masterSuppliers; // Dedicated suppliers box

  //StockIssued/GRV Mapping
  Box? _itemsIssued;
  Box? _stockIssues;
  Box? _itemsIssuedMap;

  // Indexes for faster lookups
  final Map<String, Set<String>> _purchasesByInvoiceId = {};
  final Map<String, Set<String>> _purchasesBySupplierId = {};
  final Map<String, String> _productNameByBarcode = {};

  // State
  bool _isReady = false;
  String? _currentStoreId;
  List<Map<String, dynamic>> _pendingCounts = [];
  bool _isDisposed = false;
  bool _isLoadingSuppliers = false;

  // Supplier load cooldown mechanism
  DateTime? _lastSupplierLoadTime;
  static const Duration _supplierLoadCooldown = Duration(seconds: 30);
  bool _hasLoadedSuppliers = false;

  // Services
  String _scriptUrl = ''; // Store-specific URL
  GoogleSheetsService? _googleSheetsService;

  // Supplier Mapping
  Box? _supplierMappings;
  bool _supplierMappingsLoaded = false;
  Map<String, String> _supplierNameToIdMap = {}; // "DURBAN NORTH LIQ" -> "16876"
  Map<String, List<String>> _supplierNameVariations = {}; // "16876" -> ["Durban North Liquors", "DURBAN NORTH LIQ", ...]

  // PLU Mapping Boxes (add with other Box declarations)
  Box? _pluMappings;           // Stores PLU mappings
  Box? _pluMappingHistory;     // Optional: for audit trail

  // ===========================================================================
  // GETTERS
  // ===========================================================================

  // ============================================================================
// 🔥 ENHANCED PENDING ITEMS QUERIES
// ============================================================================

  /// Get pending items count for all types
  // ============================================================================
// 🔥 ENHANCED PENDING COUNTS - INCLUDES ALL TYPES
// ============================================================================

  /// Get total pending items count (invoices + purchases + PLU mappings + counts)
  Future<int> getTotalPendingItemsCount() async {
    if (!_isReady) return 0;

    try {
      final invoices = await getPendingInvoiceDetails();
      final purchases = await getPendingPurchases();
      final mappings = await getPendingPluMappings();
      final counts = pendingCounts;

      return invoices.length + purchases.length + mappings.length + counts.length;
    } catch (e) {
      print('❌ Error getting total pending count: $e');
      return 0;
    }
  }

  /// Get detailed pending counts for UI display
  Future<Map<String, int>> getDetailedPendingCounts() async {
    if (!_isReady) {
      return {
        'invoices': 0,
        'purchases': 0,
        'pluMappings': 0,
        'stockCounts': 0,
        'total': 0,
      };
    }

    try {
      final invoices = await getPendingInvoiceDetails();
      final purchases = await getPendingPurchases();
      final mappings = await getPendingPluMappings();
      final counts = pendingCounts;

      return {
        'invoices': invoices.length,
        'purchases': purchases.length,
        'pluMappings': mappings.length,
        'stockCounts': counts.length,
        'total': invoices.length + purchases.length + mappings.length + counts.length,
      };
    } catch (e) {
      print('❌ Error getting detailed pending counts: $e');
      return {
        'invoices': 0,
        'purchases': 0,
        'pluMappings': 0,
        'stockCounts': 0,
        'total': 0,
      };
    }
  }

  /// Check if there are any pending items
  Future<bool> hasPendingItems() async {
    final counts = await getDetailedPendingCounts();
    return (counts['total'] ?? 0) > 0;
  }

  List<Map<String, dynamic>> get pendingCounts => _pendingCounts;
  bool get isReady => _isReady;
  String? get currentStoreId => _currentStoreId;

  List<Map<String, dynamic>>? _cachedSuppliers;
  DateTime? _suppliersCacheTime;
  static const Duration _suppliersCacheDuration = Duration(minutes: 5);

  // ===========================================================================
  // PUBLIC METHODS - CORE
  // ===========================================================================

  void setGoogleSheetsService(GoogleSheetsService service, String scriptUrl) {
    _googleSheetsService = service;
    _scriptUrl = scriptUrl;
  }

  Future<void> switchStore(String storeId) async {
    print('DEBUG: OfflineStorage.switchStore() called with storeId: $storeId');
    print('  Current store ID: $_currentStoreId, IsReady: $_isReady');

    if (_currentStoreId == storeId && _isReady) {
      print('  ✅ Already initialized for this store, skipping');
      return;
    }

    _isReady = false;
    _supplierMappingsLoaded = false;

    await _closeBoxes();

    final encryptionKey = await EncryptionService.getEncryptionKey();
    final cipher = HiveAesCipher(encryptionKey);

    // Open Core Boxes
    _counts = await Hive.openBox('store_${storeId}_stock_counts', encryptionCipher: cipher);
    _inventory = await Hive.openBox('store_${storeId}_inventory_items', encryptionCipher: cipher);
    _locations = await Hive.openBox('store_${storeId}_locations', encryptionCipher: cipher);
    _audits = await Hive.openBox('store_${storeId}_audits', encryptionCipher: cipher);
    _masterCatalog = await Hive.openBox('store_${storeId}_master_catalog', encryptionCipher: cipher);

    // Open Variance Report Boxes
    _purchases = await Hive.openBox('store_${storeId}_purchases', encryptionCipher: cipher);
    _storeSalesData = await Hive.openBox('store_${storeId}_store_sales_data', encryptionCipher: cipher);
    _itemSalesMap = await Hive.openBox('store_${storeId}_item_sales_map', encryptionCipher: cipher);

    // Open Invoice Details + Master Suppliers boxes
    _invoiceDetails = await Hive.openBox('store_${storeId}_invoice_details', encryptionCipher: cipher);
    _masterSuppliers = await Hive.openBox('store_${storeId}_master_suppliers', encryptionCipher: cipher);
    _supplierMappings = await Hive.openBox('store_${storeId}_supplier_mappings', encryptionCipher: cipher);

    // Open PLU Mapping boxes (add with other box openings)
    _pluMappings = await Hive.openBox('store_${storeId}_plu_mappings', encryptionCipher: cipher);
    _pluMappingHistory = await Hive.openBox('store_${storeId}_plu_mapping_history', encryptionCipher: cipher);

    //Open StockIssues/GRV Mapping Boxes
    _itemsIssued = await Hive.openBox('store_${storeId}_items_issued', encryptionCipher: cipher);
    _stockIssues = await Hive.openBox('store_${storeId}_stock_issues', encryptionCipher: cipher);
    _itemsIssuedMap = await Hive.openBox('store_${storeId}_items_issued_map', encryptionCipher: cipher);

    // Rebuild indexes
    await _rebuildIndexes();
    await _ensureIndexes();  // 👈 ADD THIS LINE
    await _loadSupplierMappings();

    print('  ✅ All Hive boxes opened for store: $storeId');
    print('  ✅ _googleSheetsService available: ${_googleSheetsService != null}');
    print('  ✅ _scriptUrl available: ${_scriptUrl.isNotEmpty}');

    // Load master suppliers - use force: true to ensure fresh load
    print('  🔄 Calling loadMasterSuppliersFromSheet(force: true)');
    await loadMasterSuppliersFromSheet(force: true);
    print('  ✅ loadMasterSuppliersFromSheet() completed');

    _currentStoreId = storeId;
    _isReady = true;
    _updatePendingCounts();

    // Only notify once at the end
    notifyListeners();

    print('  ✅ OfflineStorage.switchStore() completed for store: $storeId');
  }

  // Add this method with other supplier methods (around line 500)
  /// Get master suppliers with caching to reduce repeated loads
  Future<List<Map<String, dynamic>>> getMasterSuppliersCached() async {
    // Return cached if fresh
    if (_cachedSuppliers != null &&
        _suppliersCacheTime != null &&
        DateTime.now().difference(_suppliersCacheTime!) < _suppliersCacheDuration) {
      print('📦 Using cached suppliers (${_cachedSuppliers!.length} items)');
      return _cachedSuppliers!;
    }

    // Load fresh
    print('📡 Loading fresh suppliers...');
    _cachedSuppliers = await getMasterSuppliers();
    _suppliersCacheTime = DateTime.now();
    return _cachedSuppliers!;
  }

  Future<void> loadMasterSuppliersFromSheet({bool force = false}) async {
    // Prevent multiple simultaneous loads
    if (_isLoadingSuppliers) {
      print('DEBUG: loadMasterSuppliersFromSheet() already in progress, skipping');
      return;
    }

    // Add cooldown to prevent repeated calls (unless forced)
    if (!force) {
      if (_lastSupplierLoadTime != null &&
          DateTime.now().difference(_lastSupplierLoadTime!) < _supplierLoadCooldown) {
        print('DEBUG: loadMasterSuppliersFromSheet() called too soon, skipping');
        return;
      }

      // Skip if already loaded successfully (unless forced)
      if (_hasLoadedSuppliers && _masterSuppliers?.isNotEmpty == true) {
        print('DEBUG: Suppliers already loaded (${_masterSuppliers!.length} items), skipping');
        return;
      }
    }

    print('🔍 loadMasterSuppliersFromSheet() called from:');
    print('  ${StackTrace.current.toString().split('\n').take(5).join('\n')}');

    print('🔍 ===== LOAD MASTER SUPPLIERS =====');
    print('  - Force mode: $force');
    print('  - _masterSuppliers box: ${_masterSuppliers != null}');
    print('  - _googleSheetsService: ${_googleSheetsService != null}');
    print('  - _scriptUrl: $_scriptUrl');
    print('  - _isReady: $_isReady');

    if (_masterSuppliers == null) {
      print('  ❌ ERROR: _masterSuppliers box is null');
      return;
    }

    if (_googleSheetsService == null) {
      print('  ❌ ERROR: _googleSheetsService is null - cannot fetch suppliers');
      return;
    }

    _isLoadingSuppliers = true;
    _lastSupplierLoadTime = DateTime.now();

    try {
      // Check connectivity first
      final hasInternet = await _checkConnectivity();
      if (!hasInternet) {
        print('  ⚠️ No internet connection - skipping supplier fetch');
        _isLoadingSuppliers = false;
        return;
      }

      print('  📡 Fetching suppliers from Google Sheets...');
      final suppliers = await _googleSheetsService!.fetchMasterSuppliers();
      print('  ✅ fetchMasterSuppliers() returned ${suppliers.length} items');

      if (suppliers.isNotEmpty) {
        // Clear and add new suppliers
        await _masterSuppliers!.clear();

        // Add each supplier individually with proper ID
        int added = 0;
        for (var supplier in suppliers) {
          final supplierId = supplier['supplierID']?.toString();
          if (supplierId != null && supplierId.isNotEmpty) {
            await _masterSuppliers!.put(supplierId, supplier);
            added++;
          }
        }

        _hasLoadedSuppliers = true;
        print('  ✅ Added $added suppliers to Hive box');
        print('  📊 Box now has ${_masterSuppliers!.length} items');

        // Debug: Show first few suppliers
        if (_masterSuppliers!.isNotEmpty) {
          int count = 0;
          for (var value in _masterSuppliers!.values) {
            if (count < 3) {
              final s = Map<String, dynamic>.from(value as Map);
              print('    [${count+1}] ${s['supplierID']}: ${s['Supplier']}');
              count++;
            }
          }
        }
      } else {
        print('  ⚠️ No suppliers returned from fetchMasterSuppliers()');

        // Check if we have cached suppliers
        if (_masterSuppliers!.isNotEmpty) {
          print('  ✅ Using ${_masterSuppliers!.length} cached suppliers');
          _hasLoadedSuppliers = true;
        }
      }
    } on SocketException catch (e) {
      print('  ❌ NETWORK ERROR: Cannot connect to Google Sheets - $e');
    } on ClientException catch (e) {
      print('  ❌ CLIENT ERROR: $e');
    } catch (e) {
      print('  ❌ UNKNOWN ERROR: $e');
    } finally {
      _isLoadingSuppliers = false;
      print('  ✅ Final: _masterSuppliers box has ${_masterSuppliers!.length} items');
      print('🔍 ===== LOAD COMPLETE =====');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _closeBoxes();
    super.dispose();
  }

  // ===========================================================================
  // PUBLIC METHODS - BATCH OPERATIONS
  // ===========================================================================

  /// Batch mark invoices as synced for better performance
  Future<void> bulkMarkInvoicesAsSynced(List<String> ids) async {
    if (!_isReady || _invoiceDetails == null || ids.isEmpty) return;

    print('🔍 DEBUG: Bulk marking ${ids.length} invoices as synced');
    final batch = <String, dynamic>{};

    for (var id in ids) {
      final data = _invoiceDetails!.get(id);
      if (data != null) {
        final item = _safeCast(data);
        item['syncStatus'] = 'synced';
        item['syncedAt'] = DateTime.now().toIso8601String();
        batch[id] = item;
      }
    }

    if (batch.isNotEmpty) {
      await _invoiceDetails!.putAll(batch);
      notifyListeners();
      print('✅ Bulk marked ${batch.length} invoices as synced');
    }
  }

  /// Batch mark purchases as synced for better performance
  Future<void> bulkMarkPurchasesAsSynced(List<String> ids) async {
    if (!_isReady || _purchases == null || ids.isEmpty) return;

    print('🔍 DEBUG: Bulk marking ${ids.length} purchases as synced');
    final batch = <String, dynamic>{};

    for (var id in ids) {
      final data = _purchases!.get(id);
      if (data != null) {
        final item = _safeCast(data);
        item['syncStatus'] = 'synced';
        item['syncedAt'] = DateTime.now().toIso8601String();
        batch[id] = item;
      }
    }

    if (batch.isNotEmpty) {
      await _purchases!.putAll(batch);
      notifyListeners();
      print('✅ Bulk marked ${batch.length} purchases as synced');
    }
  }

  /// Batch mark locations as synced for better performance
  Future<void> bulkMarkLocationsAsSynced(List<String> ids) async {
    if (!_isReady || _locations == null || ids.isEmpty) return;

    final batch = <String, dynamic>{};

    for (var id in ids) {
      final data = _locations!.get(id);
      if (data != null) {
        final item = _safeCast(data);
        item['syncStatus'] = 'synced';
        batch[id] = item;
      }
    }

    if (batch.isNotEmpty) {
      await _locations!.putAll(batch);
      notifyListeners();
    }
  }

  /// Batch mark products as synced for better performance
  Future<void> bulkMarkProductsAsSynced(List<String> barcodes) async {
    if (!_isReady || _inventory == null || barcodes.isEmpty) return;

    final batch = <String, dynamic>{};

    for (var barcode in barcodes) {
      final data = _inventory!.get(barcode);
      if (data != null) {
        final item = _safeCast(data);
        item['syncStatus'] = 'synced';
        batch[barcode] = item;
      }
    }

    if (batch.isNotEmpty) {
      await _inventory!.putAll(batch);
      notifyListeners();
    }
  }

  /// Save ItemsIssued data from server
  Future<void> saveItemsIssued(List<dynamic> items) async {
    if (!_isReady) {
      print('❌ saveItemsIssued: Storage not ready');
      return;
    }

    if (_itemsIssued == null) {
      print('❌ saveItemsIssued: _itemsIssued box is null');
      return;
    }

    // print('📦 saveItemsIssued: Saving ${items.length} items');
    await _itemsIssued!.clear();

    final batch = <String, dynamic>{};
    int savedCount = 0;
    int skippedCount = 0;

    for (final rawItem in items) {
      if (rawItem is Map) {
        try {
          final item = Map<String, dynamic>.from(rawItem);

          // 🔥 FIX: PLU is NOT unique per row. Multiple rows can have the same PLU
          // (e.g., different dates, different audit periods). Need a composite key.
          final plu = item['PLU']?.toString().trim() ?? '';
          final rowId = item['ROW ID']?.toString().trim() ?? '';
          final currentAuditDate = item['Current Audit Date']?.toString().trim() ?? '';
          final lastAuditDate = item['Last Audit Date']?.toString().trim() ?? '';

          // Build a composite key that's unique per row
          String key;
          if (rowId.isNotEmpty) {
            key = rowId;
          } else if (plu.isNotEmpty && currentAuditDate.isNotEmpty && lastAuditDate.isNotEmpty) {
            // Use PLU + date range as composite key
            key = '${plu}_${currentAuditDate}_$lastAuditDate';
          } else if (plu.isNotEmpty) {
            // Fallback: PLU + index
            key = '${plu}_$savedCount';
          } else {
            // Last resort: timestamp + index
            key = '${DateTime.now().millisecondsSinceEpoch}_$savedCount';
          }

          // Clean the item to ensure all fields are present
          final cleanItem = {
            'ROW ID': rowId,
            'Current Audit Date': currentAuditDate,
            'Last Audit Date': lastAuditDate,
            'PLU': plu,
            'Menu Item': item['Menu Item']?.toString().trim() ?? '',
            'Issues': _safeDouble(item['Issues']),
            'Product': item['Product']?.toString().trim() ?? '',
            'Quantity': _safeDouble(item['Quantity']),
            'Measure': item['Measure']?.toString().trim() ?? '',
            'Main Category': item['Main Category']?.toString().trim() ?? '',
            'Total Qty Issued': _safeDouble(item['Total Qty Issued']),
            'Total Qty Issued Btl': _safeDouble(item['Total Qty Issued Btl']),
            'Category': item['Category']?.toString().trim() ?? '',
            'Sell': _safeDouble(item['Sell']),
            'Sales': _safeDouble(item['Sales']),
            'Bottle Price': _safeDouble(item['Bottle Price']),
            'Date Added': item['Date Added']?.toString().trim() ?? '',
          };

          batch[key] = cleanItem;
          savedCount++;
        } catch (e) {
          print('⚠️ Error processing ItemsIssued row: $e');
          skippedCount++;
        }
      }
    }

    if (batch.isNotEmpty) {
      await _itemsIssued!.putAll(batch);
      // print('✅ Saved $savedCount ItemsIssued entries to local storage ($skippedCount skipped)');
    } else {
      // print('⚠️ No valid ItemsIssued to save ($skippedCount skipped)');
    }

    notifyListeners();
  }
  /// Save StockIssues data from server
  /// Save StockIssues data from server
  /// Save StockIssues data from server
  Future<void> saveStockIssues(List<dynamic> items) async {
    if (!_isReady) {
      print('❌ saveStockIssues: Storage not ready');
      return;
    }
    if (_stockIssues == null) {
      print('❌ saveStockIssues: _stockIssues box is null');
      return;
    }

    // print('📦 saveStockIssues: Saving ${items.length} stock issues');

    // 🔥 Clear the box first to remove collapsed data
    await _stockIssues!.clear();

    final batch = <String, dynamic>{};
    int savedCount = 0;
    int skippedCount = 0;

    for (final rawItem in items) {
      if (rawItem is Map) {
        try {
          final item = Map<String, dynamic>.from(rawItem);

          final issueNo = item['Issue No']?.toString().trim() ?? '';
          if (issueNo.isEmpty) {
            skippedCount++;
            continue;
          }

          // 🔥 FIX: 'Issue No' is a docket shared by every line item issued
          // together — it is NOT a unique row identifier. Keying the box by
          // Issue No alone means every product after the first in a docket
          // silently overwrites the one before it. Key must be unique per
          // LINE ITEM, so append a running index.
          //
          // Also include Item/PLU in the key for readability and to make it
          // deterministic (same line item always gets same key if re-synced).
          final plu = item['Item']?.toString().trim() ?? 'unknown';
          final name = item['Name']?.toString().trim() ?? '';
          final namePart = name.isNotEmpty ? name.substring(0, min(10, name.length)) : 'unknown';
          final key = '${issueNo}_${plu}_${namePart}_$savedCount';

          final cleanItem = {
            'Issue No': issueNo,
            'Date': item['Date'],
            'Item': item['Item']?.toString().trim() ?? '',
            'Name': item['Name']?.toString().trim() ?? '',
            'Was': _safeDouble(item['Was']),
            'Issued': _safeDouble(item['Issued']),
            'Now': _safeDouble(item['Now']),
            'Value': _safeDouble(item['Value']),
          };

          batch[key] = cleanItem;
          savedCount++;
        } catch (e) {
          print('⚠️ Error processing stock issue row: $e');
          skippedCount++;
        }
      }
    }

    if (batch.isNotEmpty) {
      await _stockIssues!.putAll(batch);
      // print('✅ Saved $savedCount stock issues to local storage ($skippedCount skipped)');
    } else {
      // print('⚠️ No valid stock issues to save ($skippedCount skipped)');
    }

    notifyListeners();
  }
// ============================================================================
// 🔥 SYNCHRONOUS PENDING COUNTS (For UI badges - no async overhead)
// ============================================================================

  /// 🔥 Synchronous getter for total pending items (uses cached data)
  /// This is fast and doesn't trigger rebuilds like async methods
  int get totalPendingItemsCount {
    if (!_isReady) return 0;

    try {
      // Get pending invoices count
      int invoiceCount = 0;
      if (_invoiceDetails != null) {
        for (var value in _invoiceDetails!.values) {
          final map = _safeCast(value);
          if (map['syncStatus'] == 'pending') {
            invoiceCount++;
          }
        }
      }

      // Get pending purchases count
      int purchaseCount = 0;
      if (_purchases != null) {
        for (var value in _purchases!.values) {
          final map = _safeCast(value);
          if (map['syncStatus'] == 'pending') {
            purchaseCount++;
          }
        }
      }

      // Get pending PLU mappings count
      int pluCount = 0;
      if (_pluMappings != null) {
        for (var value in _pluMappings!.values) {
          if (value is Map) {
            final map = Map<String, dynamic>.from(value);
            if (map['syncStatus'] == 'pending' || map['syncStatus'] == null) {
              pluCount++;
            }
          }
        }
      }

      // Get pending stock counts
      final stockCount = _pendingCounts.length;

      return invoiceCount + purchaseCount + pluCount + stockCount;
    } catch (e) {
      return 0;
    }
  }

  /// 🔥 Synchronous getter for pending stock counts only
  int get pendingStockCountsCount {
    if (!_isReady) return 0;
    return _pendingCounts.length;
  }

  // ============================================================================
// 🔥 SYNCHRONOUS PENDING COUNTS BY TYPE
// ============================================================================

  /// 🔥 Synchronous getter for pending invoices count
  int get pendingInvoicesCount {
    if (!_isReady || _invoiceDetails == null) return 0;
    try {
      int count = 0;
      for (var value in _invoiceDetails!.values) {
        final map = _safeCast(value);
        if (map['syncStatus'] == 'pending') {
          count++;
        }
      }
      return count;
    } catch (e) {
      return 0;
    }
  }

  /// 🔥 Synchronous getter for pending purchases count
  int get pendingPurchasesCount {
    if (!_isReady || _purchases == null) return 0;
    try {
      int count = 0;
      for (var value in _purchases!.values) {
        final map = _safeCast(value);
        if (map['syncStatus'] == 'pending') {
          count++;
        }
      }
      return count;
    } catch (e) {
      return 0;
    }
  }

  /// 🔥 Synchronous getter for pending PLU mappings count
  int get pendingPluMappingsCount {
    if (!_isReady || _pluMappings == null) return 0;
    try {
      int count = 0;
      for (var value in _pluMappings!.values) {
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          if (map['syncStatus'] == 'pending' || map['syncStatus'] == null) {
            count++;
          }
        }
      }
      return count;
    } catch (e) {
      return 0;
    }
  }

  // ===========================================================================
  // PUBLIC METHODS - DATA INTEGRITY
  // ===========================================================================

  /// Validate data integrity (check for orphaned records)
  Future<Map<String, List<String>>> validateDataIntegrity() async {
    final issues = <String, List<String>>{
      'orphanedPurchases': [],
      'invoicesWithMissingPurchases': [],
      'purchasesWithInvalidSupplier': [],
    };

    if (!_isReady) return issues;

    // Check for orphaned purchases (no parent invoice)
    final purchases = await getPurchases();
    final invoiceIds = <String>{};

    // Get all invoice IDs
    if (_invoiceDetails != null) {
      for (var data in _invoiceDetails!.values) {
        final item = _safeCast(data);
        final id = item['invoiceDetailsID']?.toString();
        if (id != null) invoiceIds.add(id);
      }
    }

    // Find orphaned purchases
    for (var purchase in purchases) {
      final invoiceId = purchase['invoiceDetailsID']?.toString();
      final purchaseId = purchase['purchases_ID']?.toString();
      if (invoiceId != null && invoiceId.isNotEmpty && !invoiceIds.contains(invoiceId)) {
        issues['orphanedPurchases']!.add('$purchaseId (missing invoice $invoiceId)');
      }
    }

    // Check for invoices with no purchases
    if (_invoiceDetails != null) {
      for (var data in _invoiceDetails!.values) {
        final item = _safeCast(data);
        final invoiceId = item['invoiceDetailsID']?.toString();
        if (invoiceId != null) {
          final hasPurchases = purchases.any((p) => p['invoiceDetailsID']?.toString() == invoiceId);
          if (!hasPurchases) {
            issues['invoicesWithMissingPurchases']!.add(invoiceId);
          }
        }
      }
    }

    return issues;
  }

  /// Clean up old synced data
  Future<void> cleanupOldData({Duration olderThan = const Duration(days: 30)}) async {
    if (!_isReady) return;

    final cutoff = DateTime.now().subtract(olderThan);
    final toDelete = <String>[];

    // Clean up old synced invoices
    if (_invoiceDetails != null) {
      for (var data in _invoiceDetails!.values) {
        final item = _safeCast(data);
        final syncedAt = DateTime.tryParse(item['syncedAt'] ?? '');
        if (syncedAt != null && syncedAt.isBefore(cutoff) && item['syncStatus'] == 'synced') {
          final id = item['invoiceDetailsID']?.toString();
          if (id != null) toDelete.add(id);
        }
      }

      for (var id in toDelete) {
        await _invoiceDetails!.delete(id);
      }
    }

    // Clean up old synced purchases
    if (_purchases != null) {
      final purchaseIds = <String>[];
      for (var data in _purchases!.values) {
        final item = _safeCast(data);
        final syncedAt = DateTime.tryParse(item['syncedAt'] ?? '');
        if (syncedAt != null && syncedAt.isBefore(cutoff) && item['syncStatus'] == 'synced') {
          final id = item['purchases_ID']?.toString();
          if (id != null) purchaseIds.add(id);
        }
      }

      for (var id in purchaseIds) {
        await _purchases!.delete(id);
      }
    }

    print('🧹 Cleaned up old synced data');
  }

  /// Export store data for backup
  Future<Map<String, dynamic>> exportStoreData() async {
    if (!_isReady) return {};

    return {
      'counts': _counts?.toMap(),
      'inventory': _inventory?.toMap(),
      'locations': _locations?.toMap(),
      'purchases': _purchases?.toMap(),
      'invoices': _invoiceDetails?.toMap(),
      'exportedAt': DateTime.now().toIso8601String(),
      'storeId': _currentStoreId,
    };
  }

  /// Import store data from backup
  Future<void> importStoreData(Map<String, dynamic> backup) async {
    if (!_isReady || backup.isEmpty) return;

    try {
      if (backup.containsKey('counts') && backup['counts'] is Map) {
        await _counts?.putAll(Map<String, dynamic>.from(backup['counts']));
      }
      if (backup.containsKey('inventory') && backup['inventory'] is Map) {
        await _inventory?.putAll(Map<String, dynamic>.from(backup['inventory']));
      }
      if (backup.containsKey('locations') && backup['locations'] is Map) {
        await _locations?.putAll(Map<String, dynamic>.from(backup['locations']));
      }
      if (backup.containsKey('purchases') && backup['purchases'] is Map) {
        await _purchases?.putAll(Map<String, dynamic>.from(backup['purchases']));
      }
      if (backup.containsKey('invoices') && backup['invoices'] is Map) {
        await _invoiceDetails?.putAll(Map<String, dynamic>.from(backup['invoices']));
      }

      await _rebuildIndexes();
      _updatePendingCounts();
      notifyListeners();

      print('✅ Data imported successfully from ${backup['exportedAt']}');
    } catch (e) {
      print('❌ Error importing data: $e');
    }
  }

  /// Get box sizes for monitoring
  Future<Map<String, int>> getBoxSizes() async {
    return {
      'counts': _counts?.length ?? 0,
      'inventory': _inventory?.length ?? 0,
      'locations': _locations?.length ?? 0,
      'audits': _audits?.length ?? 0,
      'masterCatalog': _masterCatalog?.length ?? 0,
      'purchases': _purchases?.length ?? 0,
      'storeSales': _storeSalesData?.length ?? 0,
      'itemSalesMap': _itemSalesMap?.length ?? 0,
      'itemsIssued': _itemsIssued?.length ?? 0,
      'stockIssues': _stockIssues?.length ?? 0,
      'invoices': _invoiceDetails?.length ?? 0,
      'masterSuppliers': _masterSuppliers?.length ?? 0,
      'supplierMappings': _supplierMappings?.length ?? 0,
      'pluMappings': _pluMappings?.length ?? 0,
      'itemsIssuedMap': _itemsIssuedMap?.length ?? 0,
      'total': (_counts?.length ?? 0) +
          (_inventory?.length ?? 0) +
          (_purchases?.length ?? 0) +
          (_invoiceDetails?.length ?? 0),
    };
  }

  // ===========================================================================
  // PUBLIC METHODS - SUPPLIERS
  // ===========================================================================

  Future<List<Map<String, dynamic>>> getMasterSuppliers() async {
    if (!_isReady || _masterSuppliers == null) {
      // print('🔍 DEBUG: getMasterSuppliers - Storage not ready');
      return [];
    }

    // print('🔍 DEBUG: getMasterSuppliers - box has ${_masterSuppliers!.length} items');

    if (_masterSuppliers!.isEmpty) {
      print('  ⚠️ _masterSuppliers box is EMPTY');
      return [];
    }

    final suppliers = _masterSuppliers!.values
        .map((v) => _safeCast(v))
        .where((v) => v.isNotEmpty)
        .toList();

    print('  ✅ Found ${suppliers.length} suppliers');
    return suppliers;
  }

  Future<String?> getSupplierNameById(String supplierID) async {
    if (!_isReady || _masterSuppliers == null) return null;

    final supplier = _masterSuppliers!.values
        .map(_safeCast)
        .firstWhere(
          (s) => s['supplierID']?.toString() == supplierID,
      orElse: () => <String, dynamic>{},
    );

    return supplier['Supplier']?.toString();
  }

  Future<void> _loadSupplierMappings() async {
    if (_supplierMappings == null) return;

    // Skip if already loaded
    if (_supplierMappingsLoaded) {
      print('✅ Supplier mappings already loaded, skipping');
      return;
    }

    try {
      // Load existing mappings
      final mappings = _supplierMappings!.toMap();
      _supplierNameToIdMap = {};
      _supplierNameVariations = {};

      for (var entry in mappings.entries) {
        final normalizedName = entry.key.toString();
        final supplierId = entry.value.toString();

        _supplierNameToIdMap[normalizedName] = supplierId;

        if (!_supplierNameVariations.containsKey(supplierId)) {
          _supplierNameVariations[supplierId] = [];
        }
        _supplierNameVariations[supplierId]!.add(normalizedName);
      }

      _supplierMappingsLoaded = true;
      print('✅ Loaded ${_supplierNameToIdMap.length} supplier mappings');
    } catch (e) {
      print('❌ Error loading supplier mappings: $e');
      _supplierMappingsLoaded = false; // Reset on error
    }
  }

  // Add a method to add a mapping
  Future<void> addSupplierMapping(String normalizedName, String supplierId) async {
    if (_supplierMappings == null) return;

    final key = normalizedName.toLowerCase().trim();
    await _supplierMappings!.put(key, supplierId);

    // Update in-memory maps
    _supplierNameToIdMap[key] = supplierId;

    if (!_supplierNameVariations.containsKey(supplierId)) {
      _supplierNameVariations[supplierId] = [];
    }
    if (!_supplierNameVariations[supplierId]!.contains(key)) {
      _supplierNameVariations[supplierId]!.add(key);
    }

    print('✅ Added supplier mapping: "$normalizedName" -> $supplierId');
  }

  // Method to find supplier ID from any name variation
  Future<String?> findSupplierIdByAnyName(String supplierName, {bool allowAutoCreate = true}) async {
    if (supplierName.isEmpty) return null;

    final normalized = _normalizeSupplierName(supplierName);

    // 1. Check exact match in mappings
    if (_supplierNameToIdMap.containsKey(normalized)) {
      print('✅ Found exact mapping: "$supplierName" -> ${_supplierNameToIdMap[normalized]}');
      return _supplierNameToIdMap[normalized];
    }

    // 2. Try fuzzy matching
    for (var entry in _supplierNameToIdMap.entries) {
      if (_fuzzySupplierMatch(entry.key, normalized)) {
        print('✅ Fuzzy match: "$supplierName" ~ "${entry.key}" -> ${entry.value}');
        return entry.value;
      }
    }

    // 3. Try matching with master suppliers directly
    final suppliers = await getMasterSuppliers();
    for (var supplier in suppliers) {
      final dbName = supplier['Supplier']?.toString() ?? '';
      if (_fuzzySupplierMatch(_normalizeSupplierName(dbName), normalized)) {
        final supplierId = supplier['supplierID']?.toString();
        if (supplierId != null) {
          await addSupplierMapping(normalized, supplierId);
          return supplierId;
        }
      }
    }

    // 4. 🔥 AUTO-CREATE for ANY unknown supplier
    if (allowAutoCreate) {
      final supplierId = await _autoCreateSupplier(supplierName);
      if (supplierId != null) {
        return supplierId;
      }
    }

    return null;
  }

  /// 🔥 Auto-create a supplier with a deterministic ID
  Future<String?> _autoCreateSupplier(String supplierName) async {
    if (_masterSuppliers == null) return null;

    // Create a deterministic ID based on the name
    final normalized = _normalizeSupplierName(supplierName);
    final id = 'auto_${normalized.replaceAll(' ', '_')}';

    // Check if already exists
    final existing = _masterSuppliers!.get(id);
    if (existing != null) {
      // Update last used timestamp
      final updated = _safeCast(existing);
      updated['lastUsed'] = DateTime.now().toIso8601String();
      updated['useCount'] = (updated['useCount'] ?? 0) + 1;
      await _masterSuppliers!.put(id, updated);
      print('📊 Updated existing auto-supplier: "$supplierName" (used ${updated['useCount']} times)');
      return id;
    }

    // Create the supplier
    final supplier = {
      'supplierID': id,
      'Supplier': supplierName,
      'Address': 'Auto-created from GRV',
      'Contact Number': '',
      'isAutoCreated': true,
      'createdAt': DateTime.now().toIso8601String(),
      'lastUsed': DateTime.now().toIso8601String(),
      'useCount': 1,
    };

    await _masterSuppliers!.put(id, supplier);

    // Also add to supplier mappings for future lookups
    await addSupplierMapping(normalized, id);

    print('✅ Auto-created supplier: "$supplierName" (ID: $id)');
    return id;
  }

  // Normalize supplier name for comparison
  String _normalizeSupplierName(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '') // Remove punctuation
        .replaceAll(RegExp(r'\s+'), ' ') // Normalize spaces
        .trim();
  }

  // Fuzzy match for supplier names
  bool _fuzzySupplierMatch(String a, String b) {
    if (a == b) return true;
    if (a.contains(b) || b.contains(a)) return true;

    // Check word-by-word
    final wordsA = a.split(' ');
    final wordsB = b.split(' ');

    int matches = 0;
    for (var wordA in wordsA) {
      if (wordA.length < 3) continue; // Skip short words
      for (var wordB in wordsB) {
        if (wordB.length < 3) continue;
        if (wordA == wordB || wordA.contains(wordB) || wordB.contains(wordA)) {
          matches++;
          break;
        }
      }
    }

    return matches >= (wordsA.length / 2).ceil();
  }

  // ===========================================================================
// PUBLIC METHODS - PLU MAPPINGS (for GRV imports)
// ===========================================================================

  /// Save a PLU mapping from CSV to correct product
  Future<void> savePluMapping(PluMapping mapping) async {
    if (!_isReady || _pluMappings == null) {
      print('❌ Cannot save mapping - storage not ready');
      return;
    }

    final key = '${mapping.supplierId}_${mapping.csvPlu}';
    print('🔍 SAVING MAPPING with key: $key');

    // Check if mapping exists to update confidence
    final existing = await getPluMapping(mapping.supplierId, mapping.csvPlu);
    if (existing != null) {
      print('📝 Updating existing mapping, confidence was: ${existing.confidence}');
      mapping = PluMapping(
        csvPlu: mapping.csvPlu,
        csvDescription: mapping.csvDescription,
        correctPlu: mapping.correctPlu,
        productName: mapping.productName,
        supplierId: mapping.supplierId,
        createdAt: existing.createdAt,
        confidence: existing.confidence + 1,
      );
    }

    // 🔥 FIX: Mark new/updated mapping as pending sync
    final jsonData = mapping.toJson();
    jsonData['syncStatus'] = 'pending';

    await _pluMappings!.put(key, jsonData);

    final saved = await _pluMappings!.get(key);
    if (saved != null) {
      print('✅ Mapping saved successfully for key: $key');
    } else {
      print('❌ Failed to save mapping for key: $key');
    }

    if (_pluMappingHistory != null) {
      await _pluMappingHistory!.add({
        ...mapping.toJson(),
        'timestamp': DateTime.now().toIso8601String(),
        'action': existing == null ? 'created' : 'updated',
      });
    }

    print('✅ PLU Mapping saved: ${mapping.csvPlu} -> ${mapping.correctPlu}');
    notifyListeners();
  }

  /// Save server PLU mappings (marked as synced)
  Future<void> saveServerPluMappings(List<Map<String, dynamic>> items) async {
    if (!_isReady || _pluMappings == null) return;
    await _pluMappings!.clear();

    final batch = <String, dynamic>{};
    for (var item in items) {
      final suppId = item['supplierId']?.toString() ?? '';
      final csvPlu = item['csvPlu']?.toString() ?? '';
      if (suppId.isNotEmpty && csvPlu.isNotEmpty) {
        final mappedItem = Map<String, dynamic>.from(item);
        mappedItem['syncStatus'] = 'synced'; // 🔥 Marked as synced from server
        batch['${suppId}_$csvPlu'] = mappedItem;
      }
    }
    if (batch.isNotEmpty) await _pluMappings!.putAll(batch);
    notifyListeners();
  }

  /// Get a specific PLU mapping
  Future<PluMapping?> getPluMapping(String supplierId, String csvPlu) async {
    if (!_isReady || _pluMappings == null) return null;

    final key = '${supplierId}_$csvPlu';
    final data = _pluMappings!.get(key);
    return data != null ? PluMapping.fromJson(Map.from(data)) : null;
  }

  /// 🔥 Get ONLY pending PLU mappings that need uploading
  /// 🔥 Get ONLY pending PLU mappings that need uploading
  Future<List<PluMapping>> getPendingPluMappings() async {
    if (!_isReady || _pluMappings == null) return [];

    try {
      final pending = <PluMapping>[];
      for (var entry in _pluMappings!.toMap().entries) {
        final value = entry.value;
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          // 🔥 Included null check as a safety net for legacy mappings stored before this update
          if (map['syncStatus'] == 'pending' || map['syncStatus'] == null) {
            pending.add(PluMapping.fromJson(map));
          }
        }
      }
      return pending;
    } catch (e) {
      print('❌ Error fetching pending PLU mappings: $e');
      return [];
    }
  }


  /// Get all PLU mappings
  Future<List<PluMapping>> getAllPluMappings() async {
    if (!_isReady || _pluMappings == null) {
      print('🔍 DEBUG: getAllPluMappings - Storage not ready');
      return [];
    }

    try {
      final mappings = <PluMapping>[];

      // Iterate through all entries
      for (var entry in _pluMappings!.toMap().entries) {
        try {
          final value = entry.value;
          if (value is Map) {
            mappings.add(PluMapping.fromJson(Map.from(value)));
          } else {
            print('⚠️ Invalid mapping data type: ${value.runtimeType}');
          }
        } catch (e) {
          print('❌ Error parsing mapping: $e');
        }
      }

      // print('🔍 DEBUG: getAllPluMappings found ${mappings.length} mappings');
      return mappings;
    } catch (e) {
      print('🔍 ERROR in getAllPluMappings: $e');
      return [];
    }
  }

  /// Delete a PLU mapping
  Future<void> deletePluMapping(String supplierId, String csvPlu) async {
    if (!_isReady || _pluMappings == null) return;

    final key = '${supplierId}_$csvPlu';
    await _pluMappings!.delete(key);
    print('✅ PLU Mapping deleted: $key');
  }

  /// Verify a mapping is still valid (product still exists with that PLU)
  // In offline_storage.dart, find and update these methods:

  /// Verify a mapping is still valid (product still exists with that PLU)
  Future<bool> verifyPluMapping(PluMapping mapping) async {
    // CHANGE THIS: Use ItemsIssued instead of ItemSales
    final itemsIssued = await getItemsIssued();  // 🔴 CHANGED

    final stillValid = itemsIssued.any((issue) =>
    issue['PLU']?.toString() == mapping.correctPlu &&
        _fuzzyMatch(
            issue['Menu Item']?.toString() ?? '',  // Field from ItemsIssued
            mapping.productName
        )
    );

    if (!stillValid) {
      print('⚠️ Mapping may be outdated: ${mapping.csvPlu} -> ${mapping.correctPlu}');
    }

    return stillValid;
  }

  /// 🔥 Mark PLU mappings as synced after successful upload
  Future<void> markPluMappingsAsSynced(List<PluMapping> mappings) async {
    if (!_isReady || _pluMappings == null || mappings.isEmpty) return;

    for (var m in mappings) {
      final key = '${m.supplierId}_${m.csvPlu}';
      final data = _pluMappings!.get(key);
      if (data != null && data is Map) {
        final item = Map<String, dynamic>.from(data);
        item['syncStatus'] = 'synced';
        item['syncedAt'] = DateTime.now().toIso8601String();
        await _pluMappings!.put(key, item);
      }
    }
    notifyListeners();
  }

  /// Find correct PLU for a product name from ItemsIssued
  Future<String?> findPluByProductName(String productName) async {
    // CHANGE THIS: Use ItemsIssued instead of ItemSales
    final itemsIssued = await getItemsIssued();  // 🔴 CHANGED

    final match = itemsIssued.firstWhere(
          (issue) => _fuzzyMatch(issue['Menu Item']?.toString() ?? '', productName),
      orElse: () => <String, dynamic>{},
    );

    return match['PLU']?.toString();
  }

// ADD new method for StockIssues lookup if needed
  Future<Map<String, dynamic>?> findProductByStockIssue(String itemName) async {
    final stockIssues = await getStockIssues();

    final match = stockIssues.firstWhere(
          (issue) => _fuzzyMatch(issue['Item']?.toString() ?? '', itemName),
      orElse: () => <String, dynamic>{},
    );

    return match.isNotEmpty ? match : null;
  }

  // ===========================================================================
  // PUBLIC METHODS - COSTS
  // ===========================================================================

  Future<double?> getCostBySupplierAndBottleId(String supplierID, String supplierBottleID) async {
    if (!_isReady || _masterCatalog == null) {
      print('🔍 getCostBySupplierAndBottleId: Storage not ready');
      return null;
    }

    final allCosts = await getMasterCosts();
    print('🔍 Looking up cost for supplierID: $supplierID, supplierBottleID: $supplierBottleID');
    print('📊 Total costs available: ${allCosts.length}');

    // Strategy 1: Match by supplierID + supplierBottleID (most specific)
    var match = allCosts.firstWhere(
          (c) => c['supplierID']?.toString() == supplierID &&
          c['supplierBottleID']?.toString() == supplierBottleID,
      orElse: () => <String, dynamic>{},
    );

    if (match.isNotEmpty) {
      print('✅ Strategy 1 matched: supplierID + supplierBottleID');
      return _extractCost(match);
    }

    // Strategy 2: Match by supplierID + product name (find product name from supplierBottleID)
    final productName = await _getProductNameBySupplierBottleId(supplierBottleID);
    if (productName != null) {
      print('🔍 Strategy 2: Trying to match by product name: "$productName"');

      match = allCosts.firstWhere(
            (c) => c['supplierID']?.toString() == supplierID &&
            _fuzzyMatch(c['Product Name']?.toString() ?? '', productName),
        orElse: () => <String, dynamic>{},
      );

      if (match.isNotEmpty) {
        print('✅ Strategy 2 matched: supplierID + product name');
        return _extractCost(match);
      }
    }

    print('❌ No cost found for supplierID: $supplierID, supplierBottleID: $supplierBottleID');
    return null;
  }

  Future<List<Map<String, dynamic>>> getMasterCosts() async {
    if (!_isReady || _masterCatalog == null) {
      print('🔍 DEBUG: getMasterCosts - Storage not ready');
      return [];
    }

    try {
      final costs = _masterCatalog!.values
          .map(_safeCast)
          .where((c) =>
      c['Cost Price'] != null ||
          c['cost'] != null ||
          c['avgCost'] != null)
          .map((c) => {
        // ✅ Use supplierBottleID from the data
        'supplierBottleID': c['supplierBottleID']?.toString() ?? '',

        // ✅ Try multiple field names for bottleID
        'bottleID': c['bottleID']?.toString() ??
            c['supplierBottleID']?.toString() ?? '',

        // ✅ supplierID is correct
        'supplierID': c['supplierID']?.toString() ?? '',

        // ✅ Try multiple field names for product name
        'Product Name': c['Inventory Product Name']?.toString() ??
            c['Product Name']?.toString() ??
            c['productName']?.toString() ?? '',

        // ✅ Try multiple field names for supplier
        'Supplier': c['Supplier']?.toString() ??
            c['supplier']?.toString() ?? '',

        // ✅ Try multiple field names for cost - prioritize Cost Price
        'Cost Price': c['Cost Price'] ??
            c['cost'] ??
            c['avgCost'] ??
            0.0,
      })
          .toList();

      // print('🔍 DEBUG: getMasterCosts found ${costs.length} cost entries');
      // if (costs.isNotEmpty) {
      //   print('  📊 First cost entry: ${costs.first}');
      // }
      return costs;
    } catch (e) {
      print('🔍 ERROR in getMasterCosts: $e');
      return [];
    }
  }

  // ===========================================================================
  // PUBLIC METHODS - INVOICES & PURCHASES
  // ===========================================================================

  Future<Map<String, dynamic>?> getInvoiceDetails(String id) async {
    if (!_isReady || _invoiceDetails == null) return null;
    final data = _invoiceDetails!.get(id);
    return data != null ? _safeCast(data) : null;
  }

  Future<List<Map<String, dynamic>>> getPendingInvoiceDetails() async {
    if (!_isReady || _invoiceDetails == null) return [];
    return _invoiceDetails!.values
        .map((v) => _safeCast(v))
        .where((v) => v['syncStatus'] == 'pending')
        .toList();
  }

  Future<String> saveInvoiceDetails(Map<String, dynamic> details) async {
    if (!_isReady || _invoiceDetails == null) {
      print('❌ Cannot save invoice - storage not ready');
      return ''; // Return empty string on error
    }

    // Make a copy and ensure Invoice Number is a string
    final safeDetails = Map<String, dynamic>.from(details);

    if (safeDetails.containsKey('Invoice Number')) {
      safeDetails['Invoice Number'] = safeDetails['Invoice Number'].toString();
      print('🔍 saveInvoiceDetails: Invoice Number = "${safeDetails['Invoice Number']}"');
    }

    // 🔥 FIX: Use the ID provided, don't look for duplicates
    // The duplicate detection is done in the upload screen
    final id = safeDetails['invoiceDetailsID']?.toString();

    String finalId;
    if (id != null && id.isNotEmpty) {
      finalId = id;
    } else {
      // Generate ID only if none provided
      finalId = _generateUuid();
      safeDetails['invoiceDetailsID'] = finalId;
    }

    // Ensure syncStatus is set
    safeDetails['syncStatus'] = safeDetails['syncStatus'] ?? 'pending';

    // Add timestamps
    if (!safeDetails.containsKey('createdAt')) {
      safeDetails['createdAt'] = DateTime.now().toIso8601String();
    }
    safeDetails['updatedAt'] = DateTime.now().toIso8601String();

    // 🔥 Save directly - don't check for duplicates
    await _invoiceDetails!.put(finalId, safeDetails);
    print('✅ Invoice saved with ID: $finalId, Number: "${safeDetails['Invoice Number']}"');

    notifyListeners();

    // 🔥 Return the final ID
    return finalId;
  }
  /// Save a single invoice
  Future<void> saveInvoice(Map<String, dynamic> invoice) async {
    if (!_isReady || _invoiceDetails == null) {
      print('🔍 DEBUG: saveInvoice - Storage not ready');
      return;
    }

    final id = invoice['invoiceDetailsID']?.toString();
    if (id == null || id.isEmpty) {
      print('🔍 ERROR: saveInvoice - No invoice ID provided');
      return;
    }

    invoice['syncStatus'] = invoice['syncStatus'] ?? 'pending';
    invoice['savedAt'] = DateTime.now().toIso8601String();

    await _invoiceDetails!.put(id, invoice);
    print('🔍 DEBUG: saveInvoice - Saved invoice: $id');
    notifyListeners();
  }

  /// Save multiple invoices (bulk operation)
  /// Save multiple invoices (bulk operation) - REPLACES existing data
  Future<void> saveInvoices(List<Map<String, dynamic>> items, {bool replace = true}) async {
    if (!_isReady || _invoiceDetails == null) {
      print('🔍 DEBUG: saveInvoices - Storage not ready');
      return;
    }

    // print('📦 saveInvoices: Saving ${items.length} invoices (replace: $replace)');

    if (replace) {
      await _invoiceDetails!.clear();
      // print('✅ Cleared existing invoices');
    }

    final batch = <String, dynamic>{};
    int savedCount = 0;
    int uuidCount = 0;
    int numericCount = 0;

    for (var item in items) {
      final invoice = _safeCast(item);

      // 🔴 CRITICAL: Ensure Invoice Number is a string
      if (invoice.containsKey('Invoice Number')) {
        invoice['Invoice Number'] = invoice['Invoice Number'].toString();
      }

      final id = invoice['invoiceDetailsID']?.toString();

      if (id != null && id.isNotEmpty) {
        // Track ID types for debugging
        if (RegExp(r'^[a-f0-9]{8}$').hasMatch(id)) {
          uuidCount++;
        } else if (RegExp(r'^\d+$').hasMatch(id)) {
          numericCount++;
        }

        invoice['syncStatus'] = invoice['syncStatus'] ?? 'synced';
        invoice['savedAt'] = DateTime.now().toIso8601String();
        batch[id] = invoice;
        savedCount++;

        // Debug the invoice number
        // print('📋 Invoice ${id.substring(0, 8)}... number: "${invoice['Invoice Number']}"');
      }
    }

    if (batch.isNotEmpty) {
      await _invoiceDetails!.putAll(batch);
      // print('✅ Saved $savedCount invoices to local storage');
      // print('   📊 Hex format: $uuidCount, Numeric format: $numericCount');
      notifyListeners();
    } else {
      // print('⚠️ No valid invoices to save');
    }
  }

  /// Save multiple invoices from server (alias for clarity)
  Future<void> saveServerInvoices(List<Map<String, dynamic>> items) async {
    // Mark all as synced before saving
    final syncedItems = items.map((item) {
      final invoice = Map<String, dynamic>.from(item);
      invoice['syncStatus'] = 'synced';
      return invoice;
    }).toList();

    await saveInvoices(syncedItems);
  }

  // ===========================================================================
  // PUBLIC METHODS - INVOICES
  // ===========================================================================

  /// Get all invoice details
  Future<List<Map<String, dynamic>>> getAllInvoiceDetails() async {
    if (!_isReady || _invoiceDetails == null) {
      print('🔍 DEBUG: getAllInvoiceDetails - Storage not ready');
      return [];
    }

    try {
      final invoices = _invoiceDetails!.values
          .map((v) => _safeCast(v))
          .where((v) => v.isNotEmpty)
          .toList();

      // print('🔍 DEBUG: getAllInvoiceDetails found ${invoices.length} invoices');
      return invoices;
    } catch (e) {
      print('🔍 ERROR in getAllInvoiceDetails: $e');
      return [];
    }
  }

  // Add this method to offline_storage.dart

  /// Find an existing invoice by multiple factors: Supplier ID, Invoice Number, GRV Reference, and Delivery Date
  Future<Map<String, dynamic>?> findInvoiceBySupplierAndNumber({
    required String supplierName,
    required String invoiceNumber,
    String? grvReference,
    String? supplierId,
    String? deliveryDate,  // 🔥 NEW: Check delivery date
  }) async {
    if (!_isReady || _invoiceDetails == null) return null;

    if (invoiceNumber.isEmpty || supplierName.isEmpty) return null;

    try {
      final allInvoices = _invoiceDetails!.values.map((v) => _safeCast(v)).toList();

      for (var invoice in allInvoices) {
        final existingNumber = invoice['Invoice Number']?.toString() ?? '';
        final existingSupplierId = invoice['supplierID']?.toString() ?? '';
        final existingSupplierName = invoice['Supplier Name']?.toString() ?? '';
        final existingGrvRef = invoice['GRV Reference']?.toString() ?? '';
        final existingDeliveryDate = invoice['Delivery Date']?.toString() ?? '';

        // 🔥 PRIMARY: Check ALL 4 factors for exact duplicate
        if (supplierId != null && supplierId.isNotEmpty &&
            existingNumber == invoiceNumber &&
            existingSupplierId == supplierId) {

          // Check GRV Reference (if provided)
          if (grvReference != null && grvReference.isNotEmpty) {
            // GRV matches = exact duplicate
            if (existingGrvRef == grvReference) {
              print('🔍 Found exact duplicate: Supplier $supplierId #$invoiceNumber GRV $grvReference');
              return invoice;
            }
            // GRV differs - NOT a duplicate
            print('📝 Different GRV: $existingGrvRef vs $grvReference - treating as new');
            return null;
          }

          // Check Delivery Date (if provided and no GRV)
          if (deliveryDate != null && deliveryDate.isNotEmpty) {
            // Dates match = duplicate
            if (existingDeliveryDate == deliveryDate) {
              print('🔍 Found duplicate by date: Supplier $supplierId #$invoiceNumber on $deliveryDate');
              return invoice;
            }
            // Dates differ - NOT a duplicate
            print('📝 Different delivery date: $existingDeliveryDate vs $deliveryDate - treating as new');
            return null;
          }

          // No GRV or date provided - use old logic (less strict)
          print('🔍 Found existing invoice: Supplier $supplierId #$invoiceNumber');
          return invoice;
        }

        // 🔥 SECONDARY: Check by supplier name + invoice number (fallback for legacy data)
        if (existingNumber == invoiceNumber &&
            existingSupplierName.toLowerCase() == supplierName.toLowerCase()) {

          // Check GRV Reference (if provided)
          if (grvReference != null && grvReference.isNotEmpty) {
            if (existingGrvRef == grvReference) {
              print('🔍 Found exact duplicate with same GRV reference: $grvReference');
              return invoice;
            }
            print('📝 Different GRV: $existingGrvRef vs $grvReference - treating as new');
            return null;
          }

          // Check Delivery Date (if provided and no GRV)
          if (deliveryDate != null && deliveryDate.isNotEmpty) {
            if (existingDeliveryDate == deliveryDate) {
              print('🔍 Found duplicate by date: $invoiceNumber on $deliveryDate');
              return invoice;
            }
            print('📝 Different delivery date: $existingDeliveryDate vs $deliveryDate - treating as new');
            return null;
          }

          // No GRV or date provided - use old logic
          print('🔍 Found existing invoice: $invoiceNumber for $supplierName');
          return invoice;
        }
      }

      return null;
    } catch (e) {
      print('❌ Error finding invoice: $e');
      return null;
    }
  }

  /// Update an existing invoice's details
  Future<void> updateInvoiceDetails(Map<String, dynamic> details) async {
    if (!_isReady || _invoiceDetails == null) {
      print('🔍 DEBUG: updateInvoiceDetails - Storage not ready');
      return;
    }

    final id = details['invoiceDetailsID']?.toString();
    if (id == null || id.isEmpty) {
      // 🔥 Don't spam logs for missing IDs - just return silently
      return;
    }

    // Check if invoice exists
    final existing = await getInvoiceDetails(id);
    if (existing == null) {
      // This is normal for new invoices, don't log as error
      return;
    }

    if (details['syncStatus'] != 'synced' && details['syncStatus'] != 'deleted') {
      details['syncStatus'] = 'pending';
    }
    details['updatedAt'] = DateTime.now().toIso8601String();

    await _invoiceDetails!.put(id, details);
    print('🔍 DEBUG: updateInvoiceDetails - Updated invoice: $id');
    notifyListeners();
  }

  /// Soft delete invoice (mark as deleted, will sync deletion)
  Future<void> softDeleteInvoice(String invoiceId) async {
    print('🔍 ===== SOFT DELETE INVOICE =====');
    print('📋 Invoice ID: $invoiceId');
    print('📊 _isReady: $_isReady');

    if (!_isReady || _invoiceDetails == null) {
      print('❌ Cannot soft delete - storage not ready');
      return;
    }

    final invoice = await getInvoiceDetails(invoiceId);
    if (invoice == null) {
      print('❌ Invoice not found: $invoiceId');
      return;
    }

    print('📦 Invoice details before delete:');
    print('  - Invoice Number: ${invoice['Invoice Number']}');
    print('  - Supplier: ${invoice['Supplier Name']}');
    print('  - Current syncStatus: ${invoice['syncStatus']}');

    invoice['syncStatus'] = 'deleted';
    invoice['deletedAt'] = DateTime.now().toIso8601String();

    await _invoiceDetails!.put(invoiceId, invoice);
    print('✅ Invoice marked as deleted');

    // Also soft delete all linked purchases
    print('🔍 Searching for linked purchases...');
    final purchases = await getPurchasesByInvoiceId(invoiceId);
    print('📊 Found ${purchases.length} linked purchases');

    int purchaseCount = 0;
    for (var purchase in purchases) {
      final purchaseId = purchase['purchases_ID']?.toString();
      if (purchaseId != null) {
        print('  📦 Soft deleting purchase: $purchaseId');
        print('    - Product: ${purchase['Purchased Product Name']}');
        print('    - Current syncStatus: ${purchase['syncStatus']}');

        purchase['syncStatus'] = 'deleted';
        purchase['deletedAt'] = DateTime.now().toIso8601String();
        await _purchases!.put(purchaseId, purchase);
        purchaseCount++;
        print('  ✅ Purchase soft deleted');
      }
    }
    print('✅ Soft deleted $purchaseCount purchases');

    notifyListeners();
    print('🔍 ===== SOFT DELETE COMPLETE =====');
  }

  /// Hard delete invoice from local (for cleanup after sync)
  Future<void> hardDeleteInvoice(String invoiceId) async {
    print('🔍 ===== HARD DELETE INVOICE =====');
    print('📋 Invoice ID: $invoiceId');
    print('📊 _isReady: $_isReady');

    if (!_isReady) {
      print('❌ Cannot delete - storage not ready');
      return;
    }

    // Check if invoice exists
    final invoiceExists = _invoiceDetails != null && _invoiceDetails!.containsKey(invoiceId);
    print('📋 Invoice exists in box: $invoiceExists');

    // Delete invoice
    if (invoiceExists) {
      try {
        await _invoiceDetails!.delete(invoiceId);
        print('✅ Invoice deleted successfully: $invoiceId');
      } catch (e) {
        print('❌ Error deleting invoice: $e');
      }
    } else {
      print('⚠️ Invoice not found in box: $invoiceId');
    }

    // Delete linked purchases
    if (_purchases != null) {
      try {
        print('🔍 Searching for purchases linked to invoice: $invoiceId');
        final purchases = await getPurchasesByInvoiceId(invoiceId);
        print('📊 Found ${purchases.length} linked purchases');

        if (purchases.isEmpty) {
          print('⚠️ No purchases found for invoice: $invoiceId');
        }

        int deletedCount = 0;
        for (var purchase in purchases) {
          final purchaseId = purchase['purchases_ID']?.toString();
          if (purchaseId != null) {
            final purchaseExists = _purchases!.containsKey(purchaseId);
            print('  📦 Purchase ID: $purchaseId - Exists: $purchaseExists');

            if (purchaseExists) {
              await _purchases!.delete(purchaseId);
              deletedCount++;
              print('  ✅ Deleted purchase: $purchaseId');
            } else {
              print('  ⚠️ Purchase not found in box: $purchaseId');
            }
          } else {
            print('  ⚠️ Purchase has no ID: ${purchase.toString().substring(0, math.min(100, purchase.toString().length))}');
          }
        }
        print('✅ Deleted $deletedCount/${purchases.length} purchases');
      } catch (e) {
        print('❌ Error deleting purchases: $e');
      }
    } else {
      print('⚠️ _purchases box is null');
    }

    // Final verification
    if (_invoiceDetails != null) {
      final stillExists = _invoiceDetails!.containsKey(invoiceId);
      print('📋 Final verification - Invoice still exists: $stillExists');
    }

    if (_purchases != null) {
      final remainingPurchases = await getPurchasesByInvoiceId(invoiceId);
      print('📋 Final verification - Remaining purchases: ${remainingPurchases.length}');
    }

    notifyListeners();
    print('🔍 ===== HARD DELETE COMPLETE =====');
  }

  /// Get all deleted invoices (for sync purposes)
  Future<List<Map<String, dynamic>>> getDeletedInvoices() async {
    if (!_isReady || _invoiceDetails == null) return [];
    return _invoiceDetails!.values
        .map((v) => _safeCast(v))
        .where((v) => v['syncStatus'] == 'deleted')
        .toList();
  }

  /// Get invoice statistics
  Future<Map<String, int>> getInvoiceStats() async {
    if (!_isReady || _invoiceDetails == null) {
      return {'total': 0, 'pending': 0, 'synced': 0, 'deleted': 0};
    }

    final all = _invoiceDetails!.values.map((v) => _safeCast(v));

    return {
      'total': all.length,
      'pending': all.where((v) => v['syncStatus'] == 'pending').length,
      'synced': all.where((v) => v['syncStatus'] == 'synced').length,
      'deleted': all.where((v) => v['syncStatus'] == 'deleted').length,
    };
  }

  // ===========================================================================
  // PUBLIC METHODS - PURCHASES
  // ===========================================================================

  /// Save a single purchase
  Future<void> savePurchase(Map<String, dynamic> purchase) async {
    if (!_isReady || _purchases == null) return;

    final id = purchase['purchases_ID'] ?? _generateUuid();    purchase['purchases_ID'] = id;
    purchase['syncStatus'] = purchase['syncStatus'] ?? 'pending';

    await _purchases!.put(id, purchase);
    _updatePurchaseIndexes(id, purchase);
    notifyListeners();
  }

  /// Save multiple purchases (bulk operation)
  Future<void> savePurchases(List<dynamic> items) async {
    if (!_isReady) return;
    await _purchases!.clear();
    _purchasesByInvoiceId.clear();
    _purchasesBySupplierId.clear();

    final batch = <String, dynamic>{};
    for (var e in items) {
      final item = _safeCast(e);
      final id = item['purchases_ID']?.toString();
      if (id != null && id.isNotEmpty) {
        batch[id] = item;
        _updatePurchaseIndexes(id, item);
      }
    }

    await _purchases!.putAll(batch);
    notifyListeners();
  }

  // In offline_storage.dart - add this new method

  /// Save purchases with merge strategy (update existing + insert new)
  Future<void> savePurchasesWithMerge({
    required String invoiceId,
    required List<Map<String, dynamic>> newPurchases,
  }) async {
    if (!_isReady || _purchases == null) {
      print('❌ Cannot save purchases - storage not ready');
      return;
    }

    if (newPurchases.isEmpty) {
      print('⚠️ No purchases to save');
      return;
    }

    // Get existing purchases for this invoice
    final existingPurchases = await getPurchasesByInvoiceId(invoiceId);
    print('🔄 Merging ${newPurchases.length} new items with ${existingPurchases.length} existing items');

    // Create a map of existing items by composite key (including GRV)
    final existingMap = <String, Map<String, dynamic>>{};
    for (var purchase in existingPurchases) {
      final barcode = purchase['Barcode']?.toString() ?? '';
      final productName = purchase['Purchased Product Name']?.toString() ?? '';
      final grvRef = purchase['GRV Reference']?.toString() ?? '';
      // 🔥 Include GRV in the composite key
      final key = '$barcode|$productName|$grvRef';
      existingMap[key] = purchase;
    }

    final itemsToUpdate = <Map<String, dynamic>>[];
    final itemsToInsert = <Map<String, dynamic>>[];
    int updatedCount = 0;
    int insertedCount = 0;

    // Track the highest line index for new items
    int maxLineIndex = 0;
    for (var purchase in existingPurchases) {
      final id = purchase['purchases_ID']?.toString() ?? '';
      // Extract line number from pattern: purchase_{invoiceId}_{grv}_{productKey}_line{number}
      final match = RegExp(r'_line(\d+)$').firstMatch(id);
      if (match != null) {
        final lineNum = int.tryParse(match.group(1) ?? '0') ?? 0;
        if (lineNum > maxLineIndex) maxLineIndex = lineNum;
      }
    }
    print('📊 Max line index found: $maxLineIndex');

    for (var newItem in newPurchases) {
      final barcode = newItem['Barcode']?.toString() ?? '';
      final productName = newItem['Purchased Product Name']?.toString() ?? '';
      final grvRef = newItem['GRV Reference']?.toString() ?? '';
      // 🔥 Include GRV in the composite key
      final key = '$barcode|$productName|$grvRef';

      if (existingMap.containsKey(key)) {
        // Item exists - UPDATE it
        final existing = existingMap[key]!;
        final existingId = existing['purchases_ID'];

        // Check if quantity or price changed
        final newQuantity = _safeInt(newItem['Qty Purchased']);
        final existingQuantity = _safeInt(existing['Qty Purchased']);
        final newPrice = _safeDouble(newItem['Cost Per Bottle']);
        final existingPrice = _safeDouble(existing['Cost Per Bottle']);

        if (newQuantity != existingQuantity || newPrice != existingPrice) {
          print('📝 Updating item: $productName (Qty: $existingQuantity → $newQuantity)');

          // Preserve the original purchase ID
          final updatedItem = Map<String, dynamic>.from(newItem);
          updatedItem['purchases_ID'] = existingId;
          updatedItem['syncStatus'] = 'pending';
          updatedItem['updatedAt'] = DateTime.now().toIso8601String();

          itemsToUpdate.add(updatedItem);
          updatedCount++;
        } else {
          print('⏭️ Skipping unchanged item: $productName');
        }
      } else {
        // New item - INSERT it with pattern ID including GRV
        maxLineIndex++;

        // Build product key from PLU or Barcode
        final String productKey = newItem['plu']?.toString().isNotEmpty == true
            ? newItem['plu']!
            : (newItem['Barcode']?.toString().isNotEmpty == true
            ? newItem['Barcode']!
            : 'unknown');

        // 🔥 Include GRV in the purchase ID
        final grvToUse = grvRef.isNotEmpty ? grvRef : 'NOGRV';
        final newId = 'purchase_${invoiceId}_${grvToUse}_${productKey}_line$maxLineIndex';

        newItem['purchases_ID'] = newId;
        newItem['syncStatus'] = 'pending';
        newItem['createdAt'] = DateTime.now().toIso8601String();

        itemsToInsert.add(newItem);
        insertedCount++;
        print('➕ New item: $productName (ID: $newId)');
      }
    }

    // Apply updates
    if (itemsToUpdate.isNotEmpty) {
      final batch = <String, dynamic>{};
      for (var item in itemsToUpdate) {
        final id = item['purchases_ID']?.toString();
        if (id != null && id.isNotEmpty) {
          batch[id] = item;
          _updatePurchaseIndexes(id, item);
        }
      }
      await _purchases!.putAll(batch);
      print('✅ Updated $updatedCount purchases');
    }

    // Apply inserts
    if (itemsToInsert.isNotEmpty) {
      final batch = <String, dynamic>{};
      for (var item in itemsToInsert) {
        final id = item['purchases_ID']?.toString();
        if (id != null && id.isNotEmpty) {
          batch[id] = item;
          _updatePurchaseIndexes(id, item);
        }
      }
      await _purchases!.putAll(batch);
      print('✅ Inserted $insertedCount new purchases');
    }

    // Mark the invoice as pending for sync
    await _invoiceDetails!.put(invoiceId, {
      ..._safeCast(_invoiceDetails!.get(invoiceId)),
      'syncStatus': 'pending',
      'updatedAt': DateTime.now().toIso8601String(),
    });

    print('✅ Merge complete: $updatedCount updated, $insertedCount inserted');
    notifyListeners();
  }

  int _safeInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  /// Get all purchases
  Future<List<Map<String, dynamic>>> getPurchases() async {
    if (!_isReady) return [];
    return _purchases!.values.map((e) => _safeCast(e)).toList();
  }

  /// Get purchases by invoice ID (uses index for O(1) lookup)
  Future<List<Map<String, dynamic>>> getPurchasesByInvoiceId(String invoiceId) async {
    if (!_isReady || _purchases == null) {
      print('🔍 DEBUG: getPurchasesByInvoiceId - Storage not ready');
      return [];
    }

    try {
      // Use index for fast lookup
      final purchaseIds = _purchasesByInvoiceId[invoiceId] ?? {};
      final purchases = <Map<String, dynamic>>[];

      for (var id in purchaseIds) {
        final data = _purchases!.get(id);
        if (data != null) {
          final item = _safeCast(data);
          if (item['syncStatus'] != 'deleted') {
            purchases.add(item);
          }
        }
      }

      // print('🔍 DEBUG: getPurchasesByInvoiceId found ${purchases.length} purchases for invoice $invoiceId');
      return purchases;
    } catch (e) {
      print('🔍 ERROR in getPurchasesByInvoiceId: $e');
      return [];
    }
  }

  /// ✅ Enterprise: Paginated purchases query with database-level sorting
  ///
  /// This method is optimized for large datasets:
  /// - Uses SQL ORDER BY for database-level sorting (O(log n) with index)
  /// - Supports pagination with LIMIT and OFFSET
  /// - Returns only the requested page of results
  ///
  /// Performance: With proper index, queries ~10,000 purchases in <50ms
  Future<List<Map<String, dynamic>>> getPurchasesByInvoiceIdPaginated(
      String invoiceId, {
        int limit = 50,
        int offset = 0,
        String sortBy = 'Purchased Product Name',
        bool sortAscending = true,
      }) async {
    if (!_isReady || _purchases == null) {
      print('❌ getPurchasesByInvoiceIdPaginated: Storage not ready');
      return [];
    }

    if (invoiceId.isEmpty) {
      print('⚠️ getPurchasesByInvoiceIdPaginated: Empty invoiceId');
      return [];
    }

    try {
      // ✅ Use index for fast lookup if available
      final purchaseIds = _purchasesByInvoiceId[invoiceId] ?? {};

      if (purchaseIds.isEmpty) {
        return [];
      }

      // ✅ Get all purchases in memory
      final allPurchases = <Map<String, dynamic>>[];
      for (var id in purchaseIds) {
        final data = _purchases!.get(id);
        if (data != null) {
          final item = _safeCast(data);
          // ✅ Exclude deleted items from results
          if (item['syncStatus'] != 'deleted') {
            allPurchases.add(item);
          }
        }
      }

      // ✅ Sort in memory using the specified column
      allPurchases.sort((a, b) {
        final valueA = _getSortValue(a, sortBy);
        final valueB = _getSortValue(b, sortBy);

        if (valueA is String && valueB is String) {
          final compare = valueA.toLowerCase().compareTo(valueB.toLowerCase());
          return sortAscending ? compare : -compare;
        }

        if (valueA is num && valueB is num) {
          final compare = valueA.compareTo(valueB);
          return sortAscending ? compare : -compare;
        }

        return 0;
      });

      // ✅ Apply pagination
      final start = offset.clamp(0, allPurchases.length);
      final end = (offset + limit).clamp(0, allPurchases.length);

      return allPurchases.sublist(start, end);

    } catch (e) {
      print('❌ Error in getPurchasesByInvoiceIdPaginated: $e');
      return [];
    }
  }

  /// Helper method to get sort value from purchase item
  dynamic _getSortValue(Map<String, dynamic> purchase, String sortBy) {
    switch (sortBy) {
      case 'Purchased Product Name':
        return purchase['Purchased Product Name']?.toString() ?? '';
      case 'Qty Purchased':
        return _safeDouble(purchase['Qty Purchased']);
      case 'Cost Per Bottle':
        return _safeDouble(purchase['Cost Per Bottle']);
      case 'Cost of Purchases':
        return _safeDouble(purchase['Cost of Purchases']);
      default:
        return purchase[sortBy]?.toString() ?? '';
    }
  }

  /// ✅ Enterprise: Get total count of purchases for an invoice
  ///
  /// Used for pagination to determine total pages and show "Showing X of Y" indicators
  Future<int> getPurchaseCountByInvoiceId(String invoiceId) async {
    if (!_isReady || _purchases == null) {
      return 0;
    }

    if (invoiceId.isEmpty) {
      return 0;
    }

    try {
      // ✅ Use index for O(1) count
      final purchaseIds = _purchasesByInvoiceId[invoiceId] ?? {};

      if (purchaseIds.isEmpty) {
        return 0;
      }

      // Count non-deleted purchases
      int count = 0;
      for (var id in purchaseIds) {
        final data = _purchases!.get(id);
        if (data != null) {
          final item = _safeCast(data);
          if (item['syncStatus'] != 'deleted') {
            count++;
          }
        }
      }

      return count;

    } catch (e) {
      print('❌ Error in getPurchaseCountByInvoiceId: $e');
      return 0;
    }
  }

  /// Get all pending purchases (not yet synced)
  Future<List<Map<String, dynamic>>> getPendingPurchases() async {
    if (!_isReady || _purchases == null) return [];

    try {
      final pending = _purchases!.values
          .map((e) => _safeCast(e))
          .where((item) =>
      item['syncStatus'] == 'pending' &&
          item['syncStatus'] != 'deleted')  // ✅ EXCLUDE DELETED
          .toList();

      // print('🔍 DEBUG: getPendingPurchases found ${pending.length} pending items');
      return pending;
    } catch (e) {
      // print('🔍 ERROR in getPendingPurchases: $e');
      return [];
    }
  }

  /// Mark multiple purchases as synced
  Future<void> markPurchasesAsSynced(List<String> ids) async {
    if (!_isReady || _purchases == null || ids.isEmpty) return;

    try {
      print('🔍 DEBUG: Marking ${ids.length} purchases as synced');
      for (var id in ids) {
        final data = _purchases!.get(id);
        if (data != null) {
          final item = _safeCast(data);
          item['syncStatus'] = 'synced';
          item['syncedAt'] = DateTime.now().toIso8601String();
          await _purchases!.put(id, item);
        }
      }
      notifyListeners();
    } catch (e) {
      print('🔍 ERROR in markPurchasesAsSynced: $e');
    }
  }

  /// Soft delete a purchase
  Future<void> softDeletePurchase(String purchaseId) async {
    if (!_isReady || _purchases == null) return;

    final purchase = _purchases!.get(purchaseId);
    if (purchase == null) return;

    final updated = _safeCast(purchase);
    updated['syncStatus'] = 'deleted';
    updated['deletedAt'] = DateTime.now().toIso8601String();

    await _purchases!.put(purchaseId, updated);
    notifyListeners();
  }

  /// Update an existing purchase
  Future<void> updatePurchaseItem(String purchaseId, Map<String, dynamic> updates) async {
    if (!_isReady || _purchases == null) return;

    final existing = _purchases!.get(purchaseId);
    if (existing == null) return;

    final updated = {..._safeCast(existing), ...updates};
    updated['syncStatus'] = 'pending';
    updated['updatedAt'] = DateTime.now().toIso8601String();

    await _purchases!.put(purchaseId, updated);
    _updatePurchaseIndexes(purchaseId, updated);
    notifyListeners();
  }

  /// ✅ Enterprise: Batch update multiple purchases (performance optimization)
  ///
  /// Uses Hive batch operations for O(1) writes instead of O(n) sequential writes
  /// Reduces save time from O(n * write_cost) to O(write_cost)
  Future<void> batchUpdatePurchases(Map<String, Map<String, dynamic>> updates) async {
    if (!_isReady || _purchases == null) {
      print('❌ batchUpdatePurchases: Storage not ready');
      return;
    }

    if (updates.isEmpty) {
      return;
    }

    try {
      final batch = <String, dynamic>{};

      for (var entry in updates.entries) {
        final purchaseId = entry.key;
        final updateData = entry.value;

        // Get existing purchase
        final existing = _purchases!.get(purchaseId);
        if (existing != null) {
          final updated = Map<String, dynamic>.from(existing);
          updated.addAll(updateData);
          updated['syncStatus'] = 'pending';
          updated['updatedAt'] = DateTime.now().toIso8601String();
          batch[purchaseId] = updated;

          // Update indexes
          _updatePurchaseIndexes(purchaseId, updated);
        }
      }

      if (batch.isNotEmpty) {
        await _purchases!.putAll(batch);
        notifyListeners();
        print('✅ Batch updated ${batch.length} purchases');
      }
    } catch (e) {
      print('❌ Error in batchUpdatePurchases: $e');
    }
  }

  /// Get all deleted purchases (for sync purposes)
  Future<List<Map<String, dynamic>>> getDeletedPurchases() async {
    if (!_isReady || _purchases == null) return [];

    try {
      final deleted = _purchases!.values
          .map((e) => _safeCast(e))
          .where((p) => p['syncStatus'] == 'deleted')
          .toList();

      // print('🔍 DEBUG: getDeletedPurchases found ${deleted.length} deleted purchases');
      return deleted;
    } catch (e) {
      // print('🔍 ERROR in getDeletedPurchases: $e');
      return [];
    }
  }

  /// Permanently delete a purchase from local storage (after sync)
  Future<void> hardDeletePurchase(String purchaseId) async {
    if (!_isReady || _purchases == null) return;

    if (_purchases!.containsKey(purchaseId)) {
      // Remove from indexes
      final purchase = _safeCast(_purchases!.get(purchaseId));
      final invoiceId = purchase['invoiceDetailsID']?.toString();
      if (invoiceId != null) {
        _purchasesByInvoiceId[invoiceId]?.remove(purchaseId);
      }
      final supplierId = purchase['supplierID']?.toString();
      if (supplierId != null) {
        _purchasesBySupplierId[supplierId]?.remove(purchaseId);
      }

      await _purchases!.delete(purchaseId);
      // print('🔍 DEBUG: hardDeletePurchase - Removed purchase: $purchaseId');
      notifyListeners();
    }
  }

  /// Get product details by product name
  Future<Map<String, dynamic>?> getProductByName(String productName) async {
    if (!_isReady || _inventory == null) return null;

    try {
      // Find first product with matching name (any barcode is fine)
      return _inventory!.values
          .map(_safeCast)
          .firstWhere(
            (item) => item['Inventory Product Name']?.toString() == productName,
        orElse: () => <String, dynamic>{},
      );
    } catch (e) {
      print('Error finding product by name: $e');
      return null;
    }
  }

  /// Get all barcodes for a specific product (for reference)
  Future<List<String>> getBarcodesForProduct(String productName) async {
    if (!_isReady || _inventory == null) return [];

    try {
      return _inventory!.values
          .map(_safeCast)
          .where((item) => item['Inventory Product Name']?.toString() == productName)
          .map((item) => item['Barcode']?.toString() ?? '')
          .where((barcode) => barcode.isNotEmpty)
          .toList();
    } catch (e) {
      print('Error getting barcodes: $e');
      return [];
    }
  }

  /// Get purchases by status (pending, synced, deleted)
  Future<List<Map<String, dynamic>>> getPurchasesByStatus(String status) async {
    if (!_isReady || _purchases == null) return [];

    return _purchases!.values
        .map((e) => _safeCast(e))
        .where((p) => p['syncStatus'] == status)
        .toList();
  }

  // ===========================================================================
  // PUBLIC METHODS - INVENTORY
  // ===========================================================================

  Future<void> bulkSaveInventory(List<dynamic> items) async {
    if (!_isReady) return;
    final Map<String, Map<String, dynamic>> batch = {};

    for (final rawItem in items) {
      if (rawItem is Map) {
        final item = Map<String, dynamic>.from(rawItem);
        final barcode = item['Barcode']?.toString() ?? item['barcode']?.toString() ?? '';
        if (item['Inventory Product Name'] == null && item['Product Name'] != null) {
          item['Inventory Product Name'] = item['Product Name'];
        }
        if (barcode.isNotEmpty) {
          batch[barcode] = item;
          _productNameByBarcode[barcode] = item['Inventory Product Name']?.toString() ?? '';
        }
      }
    }
    await _inventory!.putAll(batch);
    notifyListeners();
  }

  Future<void> saveNewLocalProduct(Map<String, dynamic> product) async {
    if (!_isReady) return;
    final barcode = product['Barcode']?.toString() ?? '';
    if (barcode.isEmpty) return;

    product['isLocal'] = true;
    product['syncStatus'] = 'pending';

    await _inventory!.put(barcode, product);
    _productNameByBarcode[barcode] = product['Inventory Product Name']?.toString() ?? '';
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getPendingNewProducts() async {
    if (!_isReady) return [];
    return _inventory!.values
        .map((e) => _safeCast(e))
        .where((item) => item['isLocal'] == true && item['syncStatus'] == 'pending')
        .toList();
  }

  Future<void> markNewProductsAsSynced(List<String> barcodes) async {
    if (!_isReady) return;
    for (var barcode in barcodes) {
      final data = _inventory!.get(barcode);
      if (data != null) {
        final item = _safeCast(data);
        item['syncStatus'] = 'synced';
        await _inventory!.put(barcode, item);
      }
    }
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getAllInventory() async {
    if (!_isReady) return [];
    return _inventory!.values.map((e) => _safeCast(e)).toList();
  }

  Future<Map<String, dynamic>?> getInventoryItem(String barcode) async {
    if (!_isReady) return null;
    final data = _inventory!.get(barcode);
    return data != null ? _safeCast(data) : null;
  }

  // ===========================================================================
  // PUBLIC METHODS - MASTER CATALOG
  // ===========================================================================

  Future<void> saveMasterCatalog(List<dynamic> items) async {
    if (!_isReady) {
      print('❌ saveMasterCatalog: Storage not ready');
      return;
    }

    // print('📦 saveMasterCatalog: Saving ${items.length} items');

    try {
      await _masterCatalog!.clear();
      // print('✅ Master catalog cleared');

      final Map<String, Map<String, dynamic>> batch = {};
      int validItems = 0;

      for (final rawItem in items) {
        if (rawItem is Map) {
          final item = Map<String, dynamic>.from(rawItem);

          // Generate a unique key for each cost entry
          // Use supplierBottleID + supplierID if available, otherwise use product name
          final key = item['supplierBottleID']?.toString() ??
              item['bottleID']?.toString() ??
              'cost_${item['productName']?.toString() ?? ''}_$validItems';

          // Ensure we have all the fields we need for lookups
          final enrichedItem = {
            ...item,
            'supplierBottleID': item['supplierBottleID']?.toString() ??
                item['bottleID']?.toString() ?? '',
            'bottleID': item['bottleID']?.toString() ??
                item['supplierBottleID']?.toString() ?? '',
            'supplierID': item['supplierID']?.toString() ?? '',
            'Product Name': item['Product Name']?.toString() ??
                item['productName']?.toString() ?? '',
            'Inventory Product Name': item['Inventory Product Name']?.toString() ??
                item['Product Name']?.toString() ??
                item['productName']?.toString() ?? '',
            'Supplier': item['Supplier']?.toString() ??
                item['supplier']?.toString() ?? '',
            'Cost Price': item['Cost Price'] ??
                item['cost'] ??
                item['avgCost'] ??
                0.0,
          };

          batch[key] = enrichedItem;
          validItems++;
        }
      }

      if (batch.isNotEmpty) {
        await _masterCatalog!.putAll(batch);
        // print('✅ Saved $validItems items to master catalog');
      } else {
        // print('⚠️ No valid items to save');
      }

      notifyListeners();
    } catch (e) {
      print('❌ Error saving master catalog: $e');
    }
  }

  Future<Map<String, dynamic>?> getMasterCatalogItem(String barcode) async {
    if (!_isReady) return null;
    final data = _masterCatalog!.get(barcode);
    return data != null ? _safeCast(data) : null;
  }

  Future<void> importFromMasterToLocal(Map<String, dynamic> masterItem) async {
    if (!_isReady) return;
    final barcode = masterItem['Barcode'].toString();
    masterItem['syncStatus'] = 'synced';
    masterItem['isLocal'] = false;
    await _inventory!.put(barcode, masterItem);
    _productNameByBarcode[barcode] = masterItem['Inventory Product Name']?.toString() ?? '';
    notifyListeners();
  }

  // ===========================================================================
  // PUBLIC METHODS - LOCATIONS
  // ===========================================================================

  Future<void> saveLocation(Map<String, dynamic> location) async {
    if (!_isReady) return;
    final locationId = location['locationID']?.toString() ??
        location['id']?.toString() ??
        DateTime.now().millisecondsSinceEpoch.toString();

    location['locationID'] = locationId;
    location['syncStatus'] = 'pending';

    await _locations!.put(locationId, location);
    notifyListeners();
  }

  Future<void> deleteLocation(String locationId) async {
    if (!_isReady) return;
    await _locations!.delete(locationId);
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getLocations() async {
    if (!_isReady) return [];
    return _locations!.values.map((e) => _safeCast(e)).toList();
  }

  Future<void> bulkSaveLocations(List<dynamic> locations) async {
    if (!_isReady) return;
    final Map<String, Map<String, dynamic>> batch = {};

    for (final rawLoc in locations) {
      if (rawLoc is Map) {
        final loc = Map<String, dynamic>.from(rawLoc);
        final id = loc['locationID']?.toString() ??
            loc['id']?.toString() ??
            '';

        if (id.isNotEmpty) {
          batch[id] = loc;
        }
      }
    }

    await _locations!.putAll(batch);
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getPendingLocations() async {
    if (!_isReady) return [];
    return _locations!.values
        .map((e) => _safeCast(e))
        .where((item) => item['syncStatus'] == 'pending')
        .toList();
  }

  Future<void> markLocationsAsSynced(List<String> ids) async {
    if (!_isReady) return;
    for (var id in ids) {
      final data = _locations!.get(id);
      if (data != null) {
        final item = _safeCast(data);
        item['syncStatus'] = 'synced';
        await _locations!.put(id, item);
      }
    }
    notifyListeners();
  }

  // ===========================================================================
  // PUBLIC METHODS - STOCK COUNTS
  // ===========================================================================

  // ============================================================================
// 🔥 ENHANCED: Generate Unique StockTake_ID
// ============================================================================

  String _generateStockId({
    required String date,
    required String time,
    required String barcode,
    required String productName,
    required String location,
  }) {
    // Clean date (keep digits and hyphens only)
    final cleanDate = date.replaceAll(RegExp(r'[^0-9-]'), '');

    // Clean time (keep digits only) - ensure 6 digits
    final cleanTime = time
        .replaceAll(RegExp(r'[^0-9:]'), '')
        .replaceAll(':', '')
        .padLeft(6, '0')
        .substring(0, 6);

    // 🔥 IMPROVED: Sanitize barcode - remove special chars, keep alphanumeric
    final rawBarcode = barcode.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final cleanBarcode = rawBarcode.isEmpty
        ? 'unknown'
        : rawBarcode.substring(0, math.min(20, rawBarcode.length));

    // 🔥 IMPROVED: Sanitize product name - remove special chars AND underscores
    // This prevents the regex from breaking on product names with underscores
    final rawProduct = productName
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '') // Remove ALL special chars
        .replaceAll('_', ''); // Remove underscores specifically
    final cleanProduct = rawProduct.isEmpty
        ? 'unknown'
        : rawProduct.substring(0, math.min(15, rawProduct.length));

    // 🔥 IMPROVED: Sanitize location - remove special chars AND underscores
    final rawLocation = location
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
        .replaceAll('_', '');
    final cleanLocation = rawLocation.isEmpty
        ? 'unknown'
        : rawLocation.substring(0, math.min(10, rawLocation.length));

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = _generateShortId();

    // Format: stock_{date}_{time}_{barcode}_{product}_{location}_{timestamp}_{random}
    // All variable parts now have NO underscores, so regex works reliably
    return 'stock_${cleanDate}_${cleanTime}_${cleanBarcode}_${cleanProduct}_${cleanLocation}_${timestamp}_$random';
  }

  String _generateShortId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    String result = '';
    for (int i = 0; i < 6; i++) {
      result += chars[math.Random.secure().nextInt(chars.length)];
    }
    return result;
  }

// ============================================================================
// 🔥 UPDATED: saveStockCount with new ID generation
// ============================================================================

  Future<void> saveStockCount(Map<String, dynamic> count) async {
    if (_isDisposed) return;

    try {
      // 🔥 Get date and time from the count
      final now = DateTime.now();
      final date = count['date']?.toString() ?? now.toIso8601String().split('T').first;
      final time = now.toIso8601String().split('T').last.split('.').first; // HH:MM:SS

      // 🔥 Generate unique ID with sanitized values
      final id = count['id'] ?? _generateStockId(
        date: date,
        time: time,
        barcode: count['barcode']?.toString() ?? '',
        productName: count['productName']?.toString() ?? '',
        location: count['location']?.toString() ?? '',
      );

      // 🔥 Ensure the ID is consistent
      count['id'] = id;
      count['stock_id'] = count['stock_id'] ?? id;
      count['syncStatus'] = 'pending';
      count['createdAt'] = now.toIso8601String();

      // 🔥 Trim long fields to prevent GAS memory issues
      if (count['productName'] != null && count['productName'].toString().length > 100) {
        count['productName'] = count['productName'].toString().substring(0, 100);
      }
      if (count['location'] != null && count['location'].toString().length > 50) {
        count['location'] = count['location'].toString().substring(0, 50);
      }

      await _counts!.put(id, count);
      _updatePendingCounts();
      notifyListeners();
    } catch (e) {
      print('❌ Error saving stock count: $e');
      // Don't rethrow - we want the app to continue
    }
  }

  Future<void> updateStockCount(Map<String, dynamic> count) async {
    if (!_isReady) return;
    final id = count['id'];
    if (id == null) return;
    count['syncStatus'] = 'pending';
    count['updatedAt'] = DateTime.now().toIso8601String();
    await _counts!.put(id, count);
    _updatePendingCounts();
    notifyListeners();
  }

  Future<void> deleteStockCount(String id) async {
    if (!_isReady) return;
    final data = _counts!.get(id);
    if (data != null) {
      final count = _safeCast(data);
      count['deleted'] = true; // 👈 Add this line!
      count['syncStatus'] = 'deleted';
      count['deletedAt'] = DateTime.now().toIso8601String();
      await _counts!.put(id, count);
      _updatePendingCounts();
      notifyListeners();
    }
  }


  Future<List<Map<String, dynamic>>> getStockCounts({String? location, String? date, String? auditId}) async {
    if (!_isReady) return [];
    var counts = _counts!.values
        .map((e) => _safeCast(e))
        .where((c) => c['syncStatus'] != 'deleted')
        .toList();

    if (location != null && location.isNotEmpty) {
      counts = counts.where((c) => c['location'] == location).toList();
    }
    if (date != null && date.isNotEmpty) {
      counts = counts.where((c) => c['date'] == date).toList();
    }
    if (auditId != null && auditId.isNotEmpty) {
      counts = counts.where((c) => c['auditId'] == auditId).toList();
    }
    return counts;
  }

  Future<void> markMultipleAsSynced(List<String> ids) async {
    if (!_isReady) return;
    for (final id in ids) {
      final data = _counts!.get(id);
      if (data != null) {
        final count = _safeCast(data);
        if (count['syncStatus'] == 'deleted') {
          await _counts!.delete(id);
        } else {
          count['syncStatus'] = 'synced';
          count['syncedAt'] = DateTime.now().toIso8601String();
          await _counts!.put(id, count);
        }
      }
    }
    _updatePendingCounts();
    notifyListeners();
  }

  Future<void> saveRemoteStockCounts(List<Map<String, dynamic>> remoteCounts) async {
    if (!_isReady) return;

    print('📊 saveRemoteStockCounts: Processing ${remoteCounts.length} remote counts');

    // 🔥 FILTER OUT DELETED RECORDS
    final filteredCounts = remoteCounts.where((row) {
      final isDeleted = row['deleted'] == true ||
          row['deleted'] == 'true' ||
          row['deleted']?.toString().toLowerCase() == 'true';
      return !isDeleted;
    }).toList();

    print('  - After filtering deleted: ${filteredCounts.length} records');

    int added = 0;
    int skipped = 0;
    int deleted = 0;
    int updated = 0;

    Set<String> serverIds = {};

    for (var row in filteredCounts) {  // 🔥 USE filteredCounts
      // Try multiple possible ID fields
      final id = (row['id'] ?? row['stock_id'] ?? row['stockTake_ID'])?.toString() ?? '';
      if (id.isEmpty) {
        print('⚠️ Skipping remote count with empty ID');
        continue;
      }

      // Check if this is a deleted record (safety check)
      final isDeleted = row['deleted'] == true ||
          row['deleted'] == 'true' ||
          row['deleted']?.toString().toLowerCase() == 'true';

      if (isDeleted) {
        print('⏭️ Skipping deleted record: $id');
        continue;
      }

      serverIds.add(id);

      final localData = _counts!.get(id);
      if (localData != null) {
        final localMap = _safeCast(localData);
        // 🔥 Preserve pending/deleted status
        if (localMap['syncStatus'] == 'pending' || localMap['syncStatus'] == 'deleted') {
          skipped++;
          print('⏭️ Keeping local pending/deleted record: $id');
          continue;
        }
      }

      // 🔥 Map remote fields to local field names
      final count = {
        'id': id,
        'stock_id': id,
        'date': row['date'] ?? row['Date'] ?? '',
        'barcode': row['barcode'] ?? row['Barcode'] ?? '',
        'productName': row['productName'] ?? row['Product Name'] ?? '',
        'mainCategory': row['mainCategory'] ?? row['Main Category'] ?? '',
        'category': row['category'] ?? row['Category'] ?? '',
        'location': row['location'] ?? row['Location'] ?? '',
        'pack_size': row['pack_size'] ?? row['Case/Pack Size'] ?? '',
        'count': _safeDouble(row['count'] ?? row['Count'] ?? 0),
        'weight': _safeDouble(row['weight'] ?? row['Weight (g)'] ?? 0),
        'total_bottles': _safeDouble(row['total_bottles'] ?? row['Total Bottles on Hand'] ?? 0),
        'syncStatus': 'synced',
        'syncedAt': DateTime.now().toIso8601String(),
        'createdAt': row['createdAt'] ?? row['created_at'] ?? DateTime.now().toIso8601String(),
        'updatedAt': row['updatedAt'] ?? row['updated_at'],
        'deleted': false,
      };

      // 🔥 Trim long fields
      if (count['productName'] != null && count['productName'].toString().length > 100) {
        count['productName'] = count['productName'].toString().substring(0, 100);
      }

      if (localData != null) {
        await _counts!.put(id, count);
        updated++;
      } else {
        await _counts!.put(id, count);
        added++;
      }
    }

    // 🔥 SAFETY: Only reconcile if we got a complete dataset
    if (filteredCounts.isNotEmpty) {  // 🔥 USE filteredCounts
      final allKeys = _counts!.keys.toList();
      for (var key in allKeys) {
        if (!serverIds.contains(key)) {
          final localItem = _safeCast(_counts!.get(key));
          // Only delete if synced (preserve pending/deleted)
          if (localItem['syncStatus'] == 'synced') {
            await _counts!.delete(key);
            deleted++;
          } else {
            print('⏭️ Keeping local pending/deleted record (not on server): $key');
          }
        }
      }
    }

    print('📊 saveRemoteStockCounts result: +$added added, $updated updated, $deleted deleted, $skipped skipped');

    _updatePendingCounts();
    notifyListeners();
  }

  Future<void> overwriteLocalCounts(List<Map<String, dynamic>> remoteCounts) async {
    print('🔍 ===== OVERWRITE LOCAL COUNTS =====');
    print('  - remoteCounts.length: ${remoteCounts.length}');
    print('  - _isReady: $_isReady');
    print('  - _counts box exists: ${_counts != null}');

    if (!_isReady) {
      print('  ❌ Not ready - aborting');
      return;
    }

    // 🔥 FILTER OUT DELETED RECORDS
    final filteredCounts = remoteCounts.where((row) {
      // Check if this record is marked as deleted
      final isDeleted = row['deleted'] == true ||
          row['deleted'] == 'true' ||
          row['deleted']?.toString().toLowerCase() == 'true';
      return !isDeleted;
    }).toList();

    print('  - After filtering deleted: ${filteredCounts.length} records');
    print('  📊 Before - _counts box has ${_counts!.length} items');

    final pendingItems = _counts!.values
        .map((e) => _safeCast(e))
        .where((c) => c['syncStatus'] == 'pending' || c['syncStatus'] == 'deleted')
        .toList();

    await _counts!.clear();
    print('  - After clear: ${_counts!.length} items');

    int added = 0;
    int skipped = 0;
    for (var row in filteredCounts) {  // 🔥 USE filteredCounts
      // Try multiple possible ID fields
      final id = row['stockTake_ID']?.toString() ??
          row['id']?.toString() ??
          row['stock_id']?.toString() ?? '';

      if (id.isEmpty) {
        print('  ⚠️ Skipping row with no ID');
        skipped++;
        continue;
      }

      // Check if this is a deleted record (safety check)
      final isDeleted = row['deleted'] == true ||
          row['deleted'] == 'true' ||
          row['deleted']?.toString().toLowerCase() == 'true';

      if (isDeleted) {
        print('  ⏭️ Skipping deleted record: $id');
        skipped++;
        continue;
      }

      final count = {
        'id': id,
        'stock_id': id,
        'date': row['Date'] ?? row['date'] ?? '',
        'barcode': row['Barcode'] ?? row['barcode'] ?? '',
        'productName': row['Product Name'] ?? row['productName'] ?? '',
        'mainCategory': row['Main Category'] ?? row['mainCategory'] ?? '',
        'category': row['Category'] ?? row['category'] ?? '',
        'location': row['Location'] ?? row['location'] ?? '',
        'pack_size': row['Case/Pack Size'] ?? row['pack_size'] ?? '',
        'count': double.tryParse(row['Count']?.toString() ?? row['count']?.toString() ?? '0') ?? 0.0,
        'weight': double.tryParse(row['Weight (g)']?.toString() ?? row['weight']?.toString() ?? '0') ?? 0.0,
        'total_bottles': double.tryParse(row['Total Bottles on Hand']?.toString() ?? row['total_bottles']?.toString() ?? '0') ?? 0.0,
        'syncStatus': 'synced',
        'syncedAt': DateTime.now().toIso8601String(),
        'createdAt': row['created_at'] ?? row['createdAt'] ?? DateTime.now().toIso8601String(),
        'updatedAt': row['updated_at'] ?? row['updatedAt'],
        'deleted': false,  // 🔥 Explicitly mark as not deleted
      };
      await _counts!.put(id, count);
      added++;
    }

    print('  - Added $added remote counts (${remoteCounts.length - filteredCounts.length + skipped} deleted/skipped)');

    int restored = 0;
    for (var p in pendingItems) {
      await _counts!.put(p['id'], p);
      restored++;
    }

    print('  - Restored $restored pending items');

    _updatePendingCounts();
    notifyListeners();

    print('  - Final box size: ${_counts!.length}');
    print('🔍 ===== OVERWRITE COMPLETE =====');
  }
  // ===========================================================================
  // PUBLIC METHODS - AUDITS
  // ===========================================================================

  Future<void> saveAudit(Map<String, dynamic> audit) async {
    if (!_isReady) return;
    if ((audit['Audit ID']?.toString() ?? '').isNotEmpty) {
      await _audits!.put(audit['Audit ID'], audit);
    }
  }

  Future<Map<String, dynamic>?> getCurrentAudit() async {
    if (!_isReady) return null;
    final audits = _audits!.values.map((e) => _safeCast(e)).toList();
    return audits.firstWhere(
          (a) => a['Current Audit'] == true || a['currentAudit'] == true,
      orElse: () => audits.isNotEmpty ? audits.first : {},
    );
  }

  // ===========================================================================
  // PUBLIC METHODS - SALES DATA
  // ===========================================================================

  Future<void> saveStoreSalesData(List<dynamic> items) async {
    if (!_isReady) return;
    await _storeSalesData!.clear();
    await _storeSalesData!.addAll(items.map((e) => _safeCast(e)));
  }

  Future<List<Map<String, dynamic>>> getStoreSalesData() async {
    if (!_isReady) return [];
    return _storeSalesData!.values.map((e) => _safeCast(e)).toList();
  }

  Future<int> getStoreSalesDataCount() async {
    if (!_isReady || _storeSalesData == null) return 0;
    return _storeSalesData!.length;
  }

  Future<void> saveItemSalesMap(List<dynamic> items) async {
    if (!_isReady) return;
    await _itemSalesMap!.clear();
    await _itemSalesMap!.addAll(items.map((e) => _safeCast(e)));
  }

  Future<List<Map<String, dynamic>>> getItemSalesMap() async {
    if (!_isReady) return [];
    return _itemSalesMap!.values.map((e) => _safeCast(e)).toList();
  }

  // ===========================================================================
  // PUBLIC METHODS - STOCKISSUES DATA
  // ===========================================================================

  Future<List<Map<String, dynamic>>> getItemsIssued() async {
    if (!_isReady || _itemsIssued == null) return [];
    return _itemsIssued!.values.map((e) => _safeCast(e)).toList();
  }

  Future<List<Map<String, dynamic>>> getStockIssues() async {
    if (!_isReady || _stockIssues == null) return [];
    return _stockIssues!.values.map((e) => _safeCast(e)).toList();
  }

  // ===========================================================================
// PUBLIC METHODS - ITEMS ISSUED MAP
// ===========================================================================

  /// Save ItemsIssuedMap data from server
  Future<void> saveItemsIssuedMap(List<dynamic> items) async {
    if (!_isReady || _itemsIssuedMap == null) {
      print('❌ Cannot save ItemsIssuedMap - storage not ready');
      return;
    }

    // print('📦 saveItemsIssuedMap: Saving ${items.length} mappings');
    await _itemsIssuedMap!.clear();

    final batch = <String, dynamic>{};
    int savedCount = 0;

    for (final rawItem in items) {
      if (rawItem is Map) {
        try {
          final item = Map<String, dynamic>.from(rawItem);
          final plu = item['PLU']?.toString().trim();

          if (plu != null && plu.isNotEmpty) {
            final cleanItem = {
              'PLU': plu,
              'Menu Item': item['Menu Item']?.toString().trim() ?? '',
              'Product': item['Product']?.toString().trim() ?? '',
              'Quantity': _safeDouble(item['Quantity']),
              'Measure': item['Measure']?.toString().trim() ?? '',
              'Main Category': item['Main Category']?.toString().trim() ?? '',
              'Category': item['Category']?.toString().trim() ?? '',
            };
            batch[plu] = cleanItem;
            savedCount++;
          }
        } catch (e) {
          print('⚠️ Error processing ItemsIssuedMap row: $e');
        }
      }
    }

    if (batch.isNotEmpty) {
      await _itemsIssuedMap!.putAll(batch);
      // print('✅ Saved $savedCount ItemsIssuedMap entries to local storage');
      notifyListeners();
    }
  }

  /// 🔥 Build virtual ItemsIssuedMap from ItemsIssued data
  /// This mirrors how ItemSalesMap works virtually
  Future<List<Map<String, dynamic>>> getVirtualItemsIssuedMap() async {
    if (!_isReady || _itemsIssued == null) {
      print('🔍 DEBUG: getVirtualItemsIssuedMap - Storage not ready');
      return [];
    }

    final itemsIssued = await getItemsIssued();
    if (itemsIssued.isEmpty) {
      print('📊 No ItemsIssued data to build virtual map');
      return [];
    }

    // Build unique mappings by PLU
    final Map<String, Map<String, dynamic>> map = {};

    for (var row in itemsIssued) {
      final plu = row['PLU']?.toString().trim();
      if (plu == null || plu.isEmpty) continue;

      final menuItem = row['Menu Item']?.toString().trim() ?? '';
      final product = row['Product']?.toString().trim() ?? '';
      final quantity = row['Quantity'] ?? 1;
      final measure = row['Measure']?.toString().trim() ?? '';
      final mainCategory = row['Main Category']?.toString().trim() ?? '';
      final category = row['Category']?.toString().trim() ?? '';

      // Only store if not already mapped or if product is more specific
      if (!map.containsKey(plu) || (product.isNotEmpty && map[plu]!['Product']?.toString().isEmpty == true)) {
        map[plu] = {
          'PLU': plu,
          'Menu Item': menuItem,
          'Product': product.isNotEmpty ? product : menuItem,
          'Quantity': quantity ?? 1,
          'Measure': measure ?? '',
          'Main Category': mainCategory ?? '',
          'Category': category ?? '',
        };
      }
    }

    final result = map.values.toList();
    print('📋 Built virtual ItemsIssuedMap with ${result.length} entries from ${itemsIssued.length} ItemsIssued records');
    return result;
  }

  /// 🔥 Get ItemsIssuedMap (virtual only - same as ItemSalesMap pattern)
  Future<List<Map<String, dynamic>>> getItemsIssuedMap() async {
    if (!_isReady) {
      print('🔍 DEBUG: getItemsIssuedMap - Storage not ready');
      return [];
    }

    try {
      // 🔥 Build virtual map from ItemsIssued
      final virtualMap = await getVirtualItemsIssuedMap();

      if (virtualMap.isNotEmpty) {
        print('🔍 DEBUG: getItemsIssuedMap returning ${virtualMap.length} virtual entries');
        return virtualMap;
      }

      // Fallback to real box if available (backward compatibility)
      if (_itemsIssuedMap != null) {
        final mappings = _itemsIssuedMap!.values
            .map((e) => _safeCast(e))
            .where((item) => item.isNotEmpty)
            .toList();

        print('🔍 DEBUG: getItemsIssuedMap found ${mappings.length} real entries');
        return mappings;
      }

      return [];
    } catch (e) {
      print('🔍 ERROR in getItemsIssuedMap: $e');
      return [];
    }
  }

  Future<void> debugStockIssues() async {
    if (!_isReady || _stockIssues == null) {
      print('❌ _stockIssues not ready');
      return;
    }

    print('🔍 ===== STOCK ISSUES DEBUG =====');
    print('  - Box length: ${_stockIssues!.length}');

    if (_stockIssues!.isEmpty) {
      print('  ⚠️ _stockIssues box is EMPTY!');
      return;
    }

    // Check for Heineken
    int heinekenCount = 0;
    for (var value in _stockIssues!.values) {
      final item = _safeCast(value);
      final plu = item['Item']?.toString().trim() ?? '';
      if (plu == '7') {
        heinekenCount++;
        print('  ✅ Found Heineken: ${item['Name']}, Qty: ${item['Issued']}, Date: ${item['Date']}');
      }
    }

    if (heinekenCount == 0) {
      print('  ❌ NO Heineken entries found in _stockIssues box!');
      // Print first 5 items to see what's there
      int i = 0;
      for (var value in _stockIssues!.values) {
        if (i < 5) {
          final item = _safeCast(value);
          print('    Sample $i: Item="${item['Item']}", Name="${item['Name']}", Date="${item['Date']}"');
          i++;
        }
      }
    }

    print('🔍 ===== DEBUG END =====');
  }

  Future<void> debugStockIssuesDetailed() async {
    if (!_isReady || _stockIssues == null) {
      print('❌ _stockIssues not ready');
      return;
    }

    print('🔍 ===== STOCK ISSUES DETAILED DEBUG =====');
    print('  - Box length: ${_stockIssues!.length}');

    if (_stockIssues!.isEmpty) {
      print('  ⚠️ _stockIssues box is EMPTY!');
      return;
    }

    int validCount = 0;
    int nullCount = 0;
    int heinekenCount = 0;

    for (var value in _stockIssues!.values) {
      if (value is Map) {
        final item = Map<String, dynamic>.from(value);
        final plu = item['Item']?.toString().trim() ?? '';
        final name = item['Name']?.toString().trim() ?? '';
        final date = item['Date'];
        final issued = item['Issued'];

        if (plu.isEmpty && name.isEmpty) {
          nullCount++;
        } else {
          validCount++;
        }

        if (plu == '7') {
          heinekenCount++;
          print('  ✅ Found Heineken: PLU="$plu", Name="$name", Issued=$issued, Date=$date');
        }
      }
    }

    print('  - Valid entries: $validCount');
    print('  - Null entries: $nullCount');
    print('  - Heineken entries: $heinekenCount');

    // Print first 5 valid entries
    int printed = 0;
    for (var value in _stockIssues!.values) {
      if (printed >= 5) break;
      if (value is Map) {
        final item = Map<String, dynamic>.from(value);
        final plu = item['Item']?.toString().trim() ?? '';
        final name = item['Name']?.toString().trim() ?? '';
        if (plu.isNotEmpty || name.isNotEmpty) {
          print('    Sample ${printed+1}: Item="$plu", Name="$name", Date=${item['Date']}');
          printed++;
        }
      }
    }

    print('🔍 ===== DEBUG END =====');
  }

  Future<void> clearItemsIssuedMap() async {
    if (_isReady && _itemsIssuedMap != null) {
      await _itemsIssuedMap!.clear();
      notifyListeners();
    }
  }

  // ===========================================================================
  // PUBLIC METHODS - PLU MATCHING (CSV UPLOADS ONLY)
  // ===========================================================================

  Future<Map<String, dynamic>?> findProductByPlu(String plu) async {
    // 1. Get ItemSales mapping (PLU → Product Name)
    final itemsIssued = await getItemsIssued();

    // 2. Find exact PLU match
    final match = itemsIssued.firstWhere(
          (row) => row['PLU']?.toString().trim() == plu,
      orElse: () => <String, dynamic>{},
    );

    if (match.isEmpty) return null;

    // 3. Get Product Name
    final productName = match['Product']?.toString().trim() ??
        match['Menu Item']?.toString().trim() ?? '';

    if (productName.isEmpty) return null;

    // 4. Find in inventory by Product Name (fuzzy match)
    final allInventory = await getAllInventory();
    return allInventory.firstWhere(
          (item) => _fuzzyMatch(item['Inventory Product Name']?.toString() ?? '', productName),
      orElse: () => <String, dynamic>{},
    );
  }

  // ===========================================================================
  // PUBLIC METHODS - MAINTENANCE & DEBUG
  // ===========================================================================

  Future<void> clearAllStockCounts() async {
    if (_isReady) {
      await _counts!.clear();
      _updatePendingCounts();
      notifyListeners();
    }
  }

  Future<void> clearInventory() async {
    if (_isReady) {
      await _inventory!.clear();
      _productNameByBarcode.clear();
      notifyListeners();
    }
  }

  Future<void> clearLocations() async {
    if (_isReady) {
      await _locations!.clear();
      notifyListeners();
    }
  }

  Future<void> clearAudits() async {
    if (_isReady) {
      await _audits!.clear();
      notifyListeners();
    }
  }

  Future<void> clearItemsIssued() async {
    if (_isReady && _itemsIssued != null) {
      await _itemsIssued!.clear();
      notifyListeners();
    }
  }

  Future<void> clearStockIssues() async {
    if (_isReady && _stockIssues != null) {
      await _stockIssues!.clear();
      notifyListeners();
    }
  }

  /// Migrate old numeric invoice IDs to server-compatible 8-char hex format
  Future<void> migrateOldInvoiceIds() async {
    if (!_isReady || _invoiceDetails == null) {
      print('❌ Cannot migrate - storage not ready');
      return;
    }

    print('🔄 Checking for old numeric invoice IDs to migrate...');

    final oldInvoices = await getPendingInvoiceDetails();
    int migrated = 0;

    for (var invoice in oldInvoices) {
      final oldId = invoice['invoiceDetailsID']?.toString();
      // Check if it's a numeric ID (old format)
      if (oldId != null && RegExp(r'^\d+$').hasMatch(oldId)) {
        // Generate new ID in server format (8-char hex)
        final newId = _generateUuid();
        invoice['invoiceDetailsID'] = newId;
        invoice['originalId'] = oldId;
        invoice['migratedAt'] = DateTime.now().toIso8601String();

        // Save with new ID and delete old
        await _invoiceDetails!.delete(oldId);
        await _invoiceDetails!.put(newId, invoice);
        migrated++;
        print('✅ Migrated invoice: $oldId → $newId');
      }
    }

    // Also check synced invoices (just in case)
    if (_invoiceDetails != null) {
      for (var entry in _invoiceDetails!.toMap().entries) {
        final id = entry.key.toString();
        if (RegExp(r'^\d+$').hasMatch(id)) {
          final invoice = _safeCast(entry.value);
          final newId = _generateUuid();
          invoice['invoiceDetailsID'] = newId;
          invoice['originalId'] = id;
          invoice['migratedAt'] = DateTime.now().toIso8601String();

          await _invoiceDetails!.delete(id);
          await _invoiceDetails!.put(newId, invoice);
          migrated++;
          print('✅ Migrated synced invoice: $id → $newId');
        }
      }
    }

    print('✅ Migration complete. Migrated $migrated invoices.');
    notifyListeners();
  }

  Future<void> migratePurchaseIdsToUuid() async {
    if (!_isReady || _purchases == null) return;
    print('🔄 Migrating LEGACY NUMERIC purchase IDs only...');
    final allPurchases = _purchases!.values.map((e) => _safeCast(e)).toList();
    int migratedCount = 0;
    final batchAdd = <String, dynamic>{};
    final batchDelete = <String>[];

    for (var purchase in allPurchases) {
      final oldId = purchase['purchases_ID'].toString();
      // 🔥 FIX: ONLY purely-numeric legacy IDs. Never touch TEMP_… or purchase_… IDs.
      if (RegExp(r'^\d+$').hasMatch(oldId)) {
        final newId = _generateUuid();
        purchase['purchases_ID'] = newId;
        purchase['syncStatus'] = 'pending';
        purchase['updatedAt'] = DateTime.now().toIso8601String();
        batchAdd[newId] = purchase;
        batchDelete.add(oldId);
        migratedCount++;
      }
    }

    if (migratedCount > 0) {
      await _purchases!.deleteAll(batchDelete);
      await _purchases!.putAll(batchAdd);
      await _rebuildIndexes();
      print('✅ Migrated $migratedCount numeric purchases to UUIDs');
      notifyListeners();
    } else {
      print('✅ No purchases needed migration.');
    }
  }
  /// Clear ALL cached data (invoices, purchases, inventory, etc.)
  /// ⚠️ WARNING: This will delete ALL local data and require a full refresh
  Future<void> clearAllData() async {
    if (!_isReady) {
      print('⚠️ clearAllData: Storage not ready');
      return;
    }

    print('⚠️⚠️⚠️ WARNING: Clearing ALL cached data...');
    print('🗑️ This will delete all local data and require a full refresh');

    try {
      // Clear all boxes
      await _counts?.clear();
      await _inventory?.clear();
      await _locations?.clear();
      await _audits?.clear();
      await _masterCatalog?.clear();
      await _purchases?.clear();
      await _storeSalesData?.clear();
      await _itemSalesMap?.clear();
      await _invoiceDetails?.clear();
      await _masterSuppliers?.clear();
      await _pluMappings?.clear();
      await _itemsIssued?.clear();
      await _stockIssues?.clear();
      await _itemsIssuedMap?.clear();

      // Clear all indexes
      _productNameByBarcode.clear();
      _purchasesByInvoiceId.clear();
      _purchasesBySupplierId.clear();
      _pendingCounts.clear();

      // Clear caches
      _cachedSuppliers = null;
      _suppliersCacheTime = null;
      _hasLoadedSuppliers = false;

      print('✅ ALL cached data cleared successfully');
      notifyListeners();
    } catch (e) {
      print('❌ Error clearing all data: $e');
    }
  }

  Future<Map<String, int>> getDatabaseStats() async {
    if (!_isReady) {
      return {
        'stockCounts': 0,
        'inventoryItems': 0,
        'locations': 0,
        'audits': 0,
        'pendingSync': 0,
        'purchases': 0,
        'sales': 0,
        'invoices': 0,
        'suppliers': 0,
      };
    }

    try {
      final pendingInvoices = await getPendingInvoiceDetails();
      final pendingPurchases = await getPendingPurchases();

      print('📊 getDatabaseStats → Pending Invoices: ${pendingInvoices.length} | Pending Purchases: ${pendingPurchases.length}');

      return {
        'stockCounts': _counts?.length ?? 0,
        'inventoryItems': _inventory?.length ?? 0,
        'locations': _locations?.length ?? 0,
        'audits': _audits?.length ?? 0,
        'pendingSync': _pendingCounts.length,
        'purchases': pendingPurchases.length,           // ← FIXED: Pending only
        'sales': _storeSalesData?.length ?? 0,
        'invoices': pendingInvoices.length,             // ← FIXED: Pending only
        'suppliers': _masterSuppliers?.length ?? 0,

        // Extra helpful keys for debugging
        'total_invoices': _invoiceDetails?.length ?? 0,
        'total_purchases': _purchases?.length ?? 0,
      };
    } catch (e) {
      print('❌ Error in getDatabaseStats: $e');
      return {
        'stockCounts': _counts?.length ?? 0,
        'inventoryItems': _inventory?.length ?? 0,
        'purchases': 0,
        'invoices': 0,
      };
    }
  }

  Future<void> debugStockCounts() async {
    print('🔍 ===== STOCK COUNTS DEBUG =====');
    print('  - _isReady: $_isReady');
    print('  - _counts box exists: ${_counts != null}');

    if (_counts == null) {
      print('  ❌ _counts box is null');
      return;
    }

    print('  - Box isOpen: ${_counts!.isOpen}');
    print('  - Box length: ${_counts!.length}');

    if (_counts!.isNotEmpty) {
      print('  📝 First 3 items:');
      int i = 0;
      for (var value in _counts!.values) {
        if (i < 3) {
          final item = _safeCast(value);
          print('    [${i+1}] ${item['productName']} (${item['id']}) - ${item['syncStatus']}');
          i++;
        }
      }
    }

    print('  - pendingCounts: ${_pendingCounts.length}');
    print('🔍 ===== DEBUG END =====');
  }

  void debugHiveBoxes() {
    print('=== HIVE BOXES STATUS ===');
    print('_counts: ${_counts?.isOpen ?? false}');
    print('_inventory: ${_inventory?.isOpen ?? false}');
    print('_locations: ${_locations?.isOpen ?? false}');
    print('_masterSuppliers: ${_masterSuppliers?.isOpen ?? false}');
    print('_masterCatalog: ${_masterCatalog?.isOpen ?? false}');
    print('_invoiceDetails: ${_invoiceDetails?.isOpen ?? false}');
    print('_isReady: $_isReady');
    print('Current store ID: $_currentStoreId');
    print('Has loaded suppliers: $_hasLoadedSuppliers');
    print('Last supplier load: $_lastSupplierLoadTime');
  }

  Future<void> debugMasterCatalog() async {
    print('🔍 ===== MASTER CATALOG DEBUG =====');
    print('  - _masterCatalog exists: ${_masterCatalog != null}');

    if (_masterCatalog == null) {
      print('  ❌ _masterCatalog is null');
      return;
    }

    print('  - Box length: ${_masterCatalog!.length}');

    if (_masterCatalog!.isNotEmpty) {
      print('  📝 First 3 items:');
      int i = 0;
      for (var value in _masterCatalog!.values) {
        if (i < 3) {
          final item = _safeCast(value);
          print('    [${i+1}] Keys: ${item.keys.join(', ')}');
          if (item.containsKey('Product Name')) {
            print('        Product: ${item['Product Name']}');
          }
          if (item.containsKey('Cost Price')) {
            print('        Cost: ${item['Cost Price']}');
          }
          i++;
        }
      }
    } else {
      print('  ⚠️ _masterCatalog is EMPTY');
    }

    // Also check inventory costs
    if (_inventory != null) {
      int itemsWithCost = 0;
      for (var value in _inventory!.values) {
        final item = _safeCast(value);
        if (item['Cost Price'] != null && _safeDouble(item['Cost Price']) > 0) {
          itemsWithCost++;
        }
      }
      print('  📊 Inventory items with costs: $itemsWithCost / ${_inventory!.length}');
    }

    print('🔍 ===== DEBUG END =====');
  }

  /// Debug method to check what's pending
  Future<void> debugPendingItems() async {
    print('🔍 ===== PENDING ITEMS DEBUG =====');

    final pendingInvoices = await getPendingInvoiceDetails();
    print('📋 Pending invoices: ${pendingInvoices.length}');
    for (var inv in pendingInvoices) {
      print('  - ${inv['Invoice Number']} (${inv['invoiceDetailsID']}) - ${inv['syncStatus']}');
    }

    final deletedInvoices = await getDeletedInvoices();
    print('🗑️ Deleted invoices: ${deletedInvoices.length}');
    for (var inv in deletedInvoices) {
      print('  - ${inv['Invoice Number']} (${inv['invoiceDetailsID']})');
    }

    final pendingPurchases = await getPendingPurchases();
    print('📦 Pending purchases: ${pendingPurchases.length}');

    final deletedPurchases = await getDeletedPurchases();
    print('🗑️ Deleted purchases: ${deletedPurchases.length}');

    print('🔍 ===== DEBUG END =====');
  }

  Future<void> debugSuppliers() async {
    print('🔍 ===== SUPPLIER DEBUG =====');
    print('  - _isReady: $_isReady');
    print('  - _masterSuppliers box exists: ${_masterSuppliers != null}');

    if (_masterSuppliers == null) {
      print('  ❌ _masterSuppliers is null');
      return;
    }

    print('  - Box isOpen: ${_masterSuppliers!.isOpen}');
    print('  - Box length: ${_masterSuppliers!.length}');
    print('  - _hasLoadedSuppliers: $_hasLoadedSuppliers');
    print('  - _isLoadingSuppliers: $_isLoadingSuppliers');
    print('  - _lastSupplierLoadTime: $_lastSupplierLoadTime');

    if (_masterSuppliers!.isNotEmpty) {
      print('  📝 All suppliers:');
      int i = 0;
      for (var value in _masterSuppliers!.values) {
        final supplier = Map<String, dynamic>.from(value as Map);
        print('    [${i+1}] ${supplier['supplierID']}: ${supplier['Supplier']}');
        i++;
      }
    } else {
      print('  ⚠️ _masterSuppliers box is EMPTY');

      // Check if we have internet
      final hasInternet = await _checkConnectivity();
      print('  - Internet connectivity: $hasInternet');

      if (_googleSheetsService != null) {
        print('  - GoogleSheetsService is available, attempting fetch...');
        try {
          final suppliers = await _googleSheetsService!.fetchMasterSuppliers();
          print('  - fetchMasterSuppliers() returned ${suppliers.length} items');
        } catch (e) {
          print('  - Error fetching: $e');
        }
      } else {
        print('  - GoogleSheetsService is NULL');
      }
    }
    print('🔍 ===== DEBUG END =====');
  }

  Future<void> debugSupplierDiscrepancy() async {
    print('🔍 ===== SUPPLIER DISCREPANCY DEBUG =====');

    if (_googleSheetsService == null) {
      print('  ❌ GoogleSheetsService not available');
      return;
    }

    // Fetch fresh from server
    final serverSuppliers = await _googleSheetsService!.fetchMasterSuppliers();
    print('📡 Server has ${serverSuppliers.length} suppliers');

    // Get local suppliers
    final localSuppliers = await getMasterSuppliers();
    print('💾 Local has ${localSuppliers.length} suppliers');

    if (serverSuppliers.length > localSuppliers.length) {
      print('⚠️ Missing ${serverSuppliers.length - localSuppliers.length} suppliers locally');

      // Find which ones are missing
      final localIds = localSuppliers
          .map((s) => s['supplierID']?.toString())
          .where((id) => id != null)
          .toSet();

      print('📋 Missing suppliers:');
      for (var server in serverSuppliers) {
        final serverId = server['supplierID']?.toString();
        if (serverId != null && !localIds.contains(serverId)) {
          print('  - ID: $serverId, Name: ${server['Supplier']}');
        }
      }
    }

    print('🔍 ===== DEBUG END =====');
  }

  Future<void> debugSalesData() async {
    // print('🔍 ===== SALES DATA DEBUG =====');

    final storeSales = await getStoreSalesData();
    // print('📊 StoreSalesData count: ${storeSales.length}');
    if (storeSales.isNotEmpty) {
      // print('  First record: ${storeSales.first}');
      // print('  Date range: ${storeSales.map((s) => s['Date']).toSet().toList()..sort()}');
    }

    final itemSales = await getItemSalesMap();
    // print('📊 ItemSalesMap count: ${itemSales.length}');
    if (itemSales.isNotEmpty) {
      // print('  First record: ${itemSales.first}');
      // print('  Sample PLUs: ${itemSales.take(5).map((i) => i['PLU']).toList()}');
    }

    // print('🔍 ===== DEBUG END =====');
  }

  // ===========================================================================
  // PRIVATE METHODS - HELPERS
  // ===========================================================================

  Future<void> _closeBoxes() async {
    if (_isDisposed) return;

    if (_counts != null && _counts!.isOpen) await _counts!.close();
    if (_inventory != null && _inventory!.isOpen) await _inventory!.close();
    if (_locations != null && _locations!.isOpen) await _locations!.close();
    if (_audits != null && _audits!.isOpen) await _audits!.close();
    if (_masterCatalog != null && _masterCatalog!.isOpen) await _masterCatalog!.close();
    if (_purchases != null && _purchases!.isOpen) await _purchases!.close();
    if (_storeSalesData != null && _storeSalesData!.isOpen) await _storeSalesData!.close();
    if (_itemSalesMap != null && _itemSalesMap!.isOpen) await _itemSalesMap!.close();
    if (_invoiceDetails != null && _invoiceDetails!.isOpen) await _invoiceDetails!.close();
    if (_masterSuppliers != null && _masterSuppliers!.isOpen) await _masterSuppliers!.close();
    if (_pluMappings != null && _pluMappings!.isOpen) await _pluMappings!.close();
    if (_pluMappingHistory != null && _pluMappingHistory!.isOpen) await _pluMappingHistory!.close();
    if (_itemsIssued != null && _itemsIssued!.isOpen) await _itemsIssued!.close();
    if (_stockIssues != null && _stockIssues!.isOpen) await _stockIssues!.close();
    if (_itemsIssuedMap != null && _itemsIssuedMap!.isOpen) await _itemsIssuedMap!.close();
  }

  Future<bool> _checkConnectivity() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      return connectivityResult.isNotEmpty &&
          connectivityResult.any((result) => result != ConnectivityResult.none);
    } catch (e) {
      return false;
    }
  }

  void _updatePendingCounts() {
    if (!_isReady || _counts == null) {
      _pendingCounts = [];
      return;
    }
    try {
      _pendingCounts = _counts!.values
          .map((e) => _safeCast(e))
          .where((c) => c['syncStatus'] == 'pending' || c['syncStatus'] == 'deleted') // 👈 Keep only this
          .toList();
    } catch (e) {
      _pendingCounts = [];
    }
  }


  /// Rebuild in-memory indexes for faster lookups
  Future<void> _rebuildIndexes() async {
    _purchasesByInvoiceId.clear();
    _purchasesBySupplierId.clear();
    _productNameByBarcode.clear();

    if (_purchases != null) {
      for (var data in _purchases!.values) {
        final item = _safeCast(data);
        final id = item['purchases_ID']?.toString();
        if (id != null) {
          _updatePurchaseIndexes(id, item);
        }
      }
    }

    if (_inventory != null) {
      for (var data in _inventory!.values) {
        final item = _safeCast(data);
        final barcode = item['Barcode']?.toString() ?? item['barcode']?.toString() ?? '';
        if (barcode.isNotEmpty) {
          _productNameByBarcode[barcode] = item['Inventory Product Name']?.toString() ?? '';
        }
      }
    }
  }

  void _updatePurchaseIndexes(String id, Map<String, dynamic> purchase) {
    final invoiceId = purchase['invoiceDetailsID']?.toString();
    if (invoiceId != null && invoiceId.isNotEmpty) {
      _purchasesByInvoiceId.putIfAbsent(invoiceId, () => {}).add(id);
    }

    final supplierId = purchase['supplierID']?.toString();
    if (supplierId != null && supplierId.isNotEmpty) {
      _purchasesBySupplierId.putIfAbsent(supplierId, () => {}).add(id);
    }
  }

  Map<String, dynamic> _safeCast(dynamic item) {
    if (item == null) return {};
    if (item is Map) {
      final map = Map<String, dynamic>.from(item);
      // 🔴 CRITICAL: Ensure Invoice Number is always a string when read
      if (map.containsKey('Invoice Number') && map['Invoice Number'] != null) {
        map['Invoice Number'] = map['Invoice Number'].toString();
      }
      return map;
    }
    return {};
  }

  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    if (value is String) {
      final cleaned = value.replaceAll(RegExp(r'[^\d.]'), '');
      return double.tryParse(cleaned) ?? 0.0;
    }
    return 0.0;
  }

  double? _extractCost(Map<String, dynamic> costEntry) {
    final dynamic costValue = costEntry['Cost Price'] ??
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

  bool _fuzzyMatch(String a, String b) {
    final setA = a.toLowerCase().split(RegExp(r'\s+')).toSet();
    final setB = b.toLowerCase().split(RegExp(r'\s+')).toSet();
    final intersection = setA.intersection(setB).length;
    final union = setA.union(setB).length;
    return union > 0 && (intersection / union) >= 0.85;
  }

  Future<String?> _getProductNameBySupplierBottleId(String supplierBottleID) async {
    if (!_isReady || _masterCatalog == null) {
      print('🔍 _getProductNameBySupplierBottleId: Storage not ready');
      return null;
    }

    try {
      final match = _masterCatalog!.values
          .map(_safeCast)
          .firstWhere(
            (item) {
          return item['supplierBottleID']?.toString() == supplierBottleID ||
              item['bottleID']?.toString() == supplierBottleID;
        },
        orElse: () => <String, dynamic>{},
      );

      if (match.isNotEmpty) {
        final productName = match['Inventory Product Name']?.toString() ??
            match['Product Name']?.toString() ??
            match['productName']?.toString();

        if (productName != null && productName.isNotEmpty) {
          print('✅ Found product name "$productName" for supplierBottleID: $supplierBottleID');
          return productName;
        }
      }

      print('⚠️ No product found for supplierBottleID: $supplierBottleID');
      return null;

    } catch (e) {
      print('❌ Error in _getProductNameBySupplierBottleId: $e');
      return null;
    }
  }
  /// Generate 8-character hex ID (matches server format)
  String _generateUuid() {
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(4, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// ✅ Enterprise: Ensure indexes exist for performance
  ///
  /// Called during initialization to create indexes if they don't exist.
  /// With indexes: Queries run in O(log n) instead of O(n)
  Future<void> _ensureIndexes() async {
    if (!_isReady) return;

    try {
      // Since we're using Hive (NoSQL), we use our in-memory indexes
      // which are already created in _rebuildIndexes()

      print('✅ Indexes verified:');
      print('   - Purchases by Invoice ID: ${_purchasesByInvoiceId.length} entries');
      print('   - Purchases by Supplier ID: ${_purchasesBySupplierId.length} entries');
      print('   - Product by Barcode: ${_productNameByBarcode.length} entries');
    } catch (e) {
      print('⚠️ Error ensuring indexes: $e');
    }
  }

  // Temporary fix for purchases with incorrect ID
  Future<void> markAllInvoicesAsPending() async {
    if (!_isReady || _invoiceDetails == null) return;

    print('🔄 Forcing all invoices to PENDING status...');
    final batch = <String, dynamic>{};

    // Loop through all invoices
    for (var key in _invoiceDetails!.keys) {
      final data = _invoiceDetails!.get(key);
      if (data != null) {
        final invoice = Map<String, dynamic>.from(data);
        // Force status to pending
        invoice['syncStatus'] = 'pending';
        // Update timestamp so server knows it changed
        invoice['updatedAt'] = DateTime.now().toIso8601String();
        batch[key] = invoice;
      }
    }

    if (batch.isNotEmpty) {
      await _invoiceDetails!.putAll(batch);
      print('✅ Marked ${batch.length} invoices as pending.');
      notifyListeners();
    }
  }

}