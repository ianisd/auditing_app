import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'google_sheets_service.dart';

class OfflineStorage with ChangeNotifier {
  Box? _counts;
  Box? _inventory;
  Box? _locations;
  Box? _audits;
  Box? _masterCatalog;

  // --- NEW BOXES FOR VARIANCE REPORT ---
  Box? _purchases;
  Box? _storeSalesData; // Raw POS Logs
  Box? _itemSalesMap;   // PLU Definitions

  // Boxes for Invoicing
  Box? _invoiceDetails;
  Box? _masterSuppliers; // ✅ NEW: Dedicated suppliers box

  bool _isReady = false;
  String? _currentStoreId;
  List<Map<String, dynamic>> _pendingCounts = [];

  List<Map<String, dynamic>> get pendingCounts => _pendingCounts;
  bool get isReady => _isReady;
  String? get currentStoreId => _currentStoreId;

  // ADD SCRIPT URL FIELD
  String _scriptUrl = ''; // ✅ NEW: Store-specific URL

  // ✅ NEW: GoogleSheetsService instance (passed during initialization)
  GoogleSheetsService? _googleSheetsService;

  // ✅ NEW: Set GoogleSheetsService and script URL
  void setGoogleSheetsService(GoogleSheetsService service, String scriptUrl) {
    _googleSheetsService = service;
    _scriptUrl = scriptUrl;
  }

  // UPDATE switchStore() TO SET SCRIPT URL
  Future<void> switchStore(String storeId) async {
    print('DEBUG: OfflineStorage.switchStore() called with storeId: $storeId');
    print('  Current store ID: $_currentStoreId, IsReady: $_isReady');

    if (_currentStoreId == storeId && _isReady) {
      print('  ✅ Already initialized for this store, skipping');
      return;
    }

    _isReady = false;
    notifyListeners();

    await _closeBoxes();

    // Open Core Boxes
    _counts = await Hive.openBox('store_${storeId}_stock_counts');
    _inventory = await Hive.openBox('store_${storeId}_inventory_items');
    _locations = await Hive.openBox('store_${storeId}_locations');
    _audits = await Hive.openBox('store_${storeId}_audits');
    _masterCatalog = await Hive.openBox('store_${storeId}_master_catalog');

    // Open Variance Report Boxes
    _purchases = await Hive.openBox('store_${storeId}_purchases');
    _storeSalesData = await Hive.openBox('store_${storeId}_store_sales_data');
    _itemSalesMap = await Hive.openBox('store_${storeId}_item_sales_map');

    // Open Invoice Details + Master Suppliers boxes
    _invoiceDetails = await Hive.openBox('store_${storeId}_invoice_details');
    _masterSuppliers = await Hive.openBox('store_${storeId}_master_suppliers');

    print('  ✅ All Hive boxes opened for store: $storeId');
    print('  ✅ _googleSheetsService available: ${_googleSheetsService != null}');
    print('  ✅ _scriptUrl available: ${_scriptUrl.isNotEmpty}');

    // LOAD MASTER SUPPLIERS FROM GOOGLE SHEETS USING STORE-SPECIFIC URL
    print('  🔄 Calling loadMasterSuppliersFromSheet()');
    await loadMasterSuppliersFromSheet();
    print('  ✅ loadMasterSuppliersFromSheet() completed');

    _currentStoreId = storeId;
    _isReady = true;
    _updatePendingCounts();
    notifyListeners();

    print('  ✅ OfflineStorage.switchStore() completed for store: $storeId');
  }

  // ✅ UPDATE loadMasterSuppliersFromSheet() TO USE STORE-SPECIFIC URL
  Future<void> loadMasterSuppliersFromSheet() async {
    print('DEBUG: loadMasterSupplierFromSheet() called');
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
      print('  ℹ️  Hint: Call setGoogleSheetsService() before switchStore()');
      return;
    }
    try {
      // Clear existing suppliers
      await _masterSuppliers!.clear();
      print('  ✅ Cleared existing suppliers');

      // USE STORE-SPECIFIC SCRIPT URL
      final suppliers = await _googleSheetsService!.fetchMasterSuppliers();
      print('  ✅ fetchMasterSuppliers() returned ${suppliers.length} items');

      // Save to Hive box
      if (suppliers.isNotEmpty) {
        await _masterSuppliers!.addAll(suppliers);
        print('  ✅ Added ${suppliers.length} suppliers to Hive box');
      } else {
        print('  ⚠️  No suppliers returned from fetchMasterSuppliers()');
        print('  ℹ️  Check: Google Apps Script deployed? URL correct? MasterSuppliers sheet exists?');
      }

      print('  ✅ Final: _masterSuppliers box now has ${_masterSuppliers!.length} items');
    } catch (e) {
      print('  ❌ ERROR in ltc1qs49erv7pzeczp5qlnxd46aufzapsmzpa7y73ct(): $e');
      print('  Stack: ${StackTrace.current}');
    }
  }

  // ✅ NEW METHOD: Get Master Suppliers (from dedicated box)
  Future<List<Map<String, dynamic>>> getMasterSuppliers() async {
    if (!_isReady || _masterSuppliers == null) {
      print('DEBUG: getMasterSuppliers - box not ready');
      return [];
    }
    print('DEBUG: getMasterSuppliers - box has ${_masterSuppliers!.length} items');
    return _masterSuppliers!.values
        .map((v) => _safeCast(v))
        .where((v) => v.isNotEmpty)
        .toList();
  }

  // ✅ FIXED: SINGLE DEFINITION of saveInvoiceDetails (was duplicated)
  Future<void> saveInvoiceDetails(Map<String, dynamic> details) async {
    if (!_isReady || _invoiceDetails == null) return;
    final id = details['invoiceDetailsID'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    details['invoiceDetailsID'] = id;
    details['syncStatus'] = 'pending';
    await _invoiceDetails!.put(id, details);
    notifyListeners();
  }

  // ✅ NEW METHOD: Get Invoice Details by ID
  Future<Map<String, dynamic>?> getInvoiceDetails(String id) async {
    if (!_isReady || _invoiceDetails == null) return null;
    final data = _invoiceDetails!.get(id);
    return data != null ? _safeCast(data) : null;
  }

  // ✅ NEW METHOD: PLU → Product Matching (reuses ItemSales mapping)
  Future<Map<String, dynamic>?> findProductByPlu(String plu) async {
    // 1. Get ItemSales mapping (PLU → Product Name)
    final itemSales = await getItemSalesMap();

    // 2. Find exact PLU match (Column D = PLU in ItemSales)
    final match = itemSales.firstWhere(
            (row) => row['PLU']?.toString().trim() == plu,
        orElse: () => <String, dynamic>{} // ✅ RETURN EMPTY MAP (non-null) instead of null
    );

    // ✅ FIXED: Check for empty map instead of null
    if (match.isEmpty) return null;

    // 3. Get Product Name (Column G = Product in ItemSales)
    final productName = match['Product']?.toString().trim() ??
        match['Menu Item']?.toString().trim() ?? '';

    if (productName.isEmpty) return null;

    // 4. Find in inventory by Product Name (fuzzy match)
    final allInventory = await getAllInventory();
    return allInventory.firstWhere(
          (item) => _fuzzyMatch(item['Inventory Product Name']?.toString() ?? '', productName),
      orElse: () => <String, dynamic>{}, // ✅ RETURN EMPTY MAP (non-null)
    );
  }

  // Fuzzy match helper (85% similarity)
  bool _fuzzyMatch(String a, String b) {
    final setA = a.toLowerCase().split(RegExp(r'\s+')).toSet();
    final setB = b.toLowerCase().split(RegExp(r'\s+')).toSet();
    final intersection = setA.intersection(setB).length;
    final union = setA.union(setB).length;
    return union > 0 && (intersection / union) >= 0.85;
  }

  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    _closeBoxes();
    super.dispose();
  }

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
  }

  Map<String, dynamic> _safeCast(dynamic item) {
    if (item == null) return {};
    if (item is Map) return Map<String, dynamic>.from(item);
    return {};
  }

  // --- INVENTORY OPERATIONS ---

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

  // --- MASTER CATALOG ---
  Future<void> saveMasterCatalog(List<dynamic> items) async {
    if (!_isReady) return;
    await _masterCatalog!.clear();
    final Map<String, Map<String, dynamic>> batch = {};
    for (final rawItem in items) {
      if (rawItem is Map) {
        final item = Map<String, dynamic>.from(rawItem);
        final barcode = item['Barcode']?.toString() ?? '';
        if (barcode.isNotEmpty) batch[barcode] = item;
      }
    }
    await _masterCatalog!.putAll(batch);
    notifyListeners();
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
    notifyListeners();
  }

  // =========================================================
  // --- LOCATIONS (UPDATED FOR SYNC) ---
  // =========================================================

  Future<void> saveLocation(Map<String, dynamic> location) async {
    if (!_isReady) return;
    final locationId = location['locationID']?.toString() ??
        location['id']?.toString() ??
        DateTime.now().millisecondsSinceEpoch.toString();

    location['locationID'] = locationId;

    // MARK AS PENDING so SyncService picks it up
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

  // --- NEW: Methods for SyncService to use ---

  // Get locations that haven't been uploaded yet
  Future<void> bulkSaveLocations(List<dynamic> locations) async {
    if (!_isReady) return;
    final Map<String, Map<String, dynamic>> batch = {};

    for (final rawLoc in locations) {
      if (rawLoc is Map) {
        final loc = Map<String, dynamic>.from(rawLoc);
        // Ensure we have a valid ID
        final id = loc['locationID']?.toString() ??
            loc['id']?.toString() ??
            '';

        if (id.isNotEmpty) {
          batch[id] = loc;
        }
      }
    }

    // Save all locations at once (much faster)
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

  // Mark them as synced after upload
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
  // =========================================================

  // --- STOCK COUNTS ---
  Future<void> saveStockCount(Map<String, dynamic> count) async {
    if (_isDisposed) return; // ✅ ONLY skip if actually disposed
    final id = count['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    count['id'] = id;
    count['syncStatus'] = 'pending';
    count['createdAt'] = DateTime.now().toIso8601String();
    await _counts!.put(id, count);
    _updatePendingCounts();
    notifyListeners();
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

  void _updatePendingCounts() {
    if (!_isReady || _counts == null) {
      _pendingCounts = [];
      return;
    }
    try {
      _pendingCounts = _counts!.values
          .map((e) => _safeCast(e))
          .where((c) => c['syncStatus'] == 'pending' || c['syncStatus'] == 'deleted')
          .toList();
    } catch (e) {
      _pendingCounts = [];
    }
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

  // --- DOWNLOAD EXISTING (SMART MERGE & PURGE) ---
  Future<void> saveRemoteStockCounts(List<Map<String, dynamic>> remoteCounts) async {
    if (!_isReady) return;

    int added = 0;
    int skipped = 0;
    int deleted = 0;

    // 1. Track IDs present on the Server
    Set<String> serverIds = {};

    // 2. Process Remote Data (Update/Add)
    for (var row in remoteCounts) {
      final id = row['stockTake_ID']?.toString() ?? '';
      if (id.isEmpty) continue;

      serverIds.add(id);

      // Check Local Status
      final localData = _counts!.get(id);
      if (localData != null) {
        final localMap = _safeCast(localData);
        // Protect pending changes
        if (localMap['syncStatus'] == 'pending' || localMap['syncStatus'] == 'deleted') {
          skipped++;
          continue;
        }
      }

      // Overwrite local with server data
      final count = {
        'id': id,
        'stock_id': id,
        'date': row['Date'],
        'barcode': row['Barcode'],
        'productName': row['Product Name'],
        'mainCategory': row['Main Category'],
        'category': row['Category'],
        'location': row['Location'],
        'pack_size': row['Case/Pack Size'],
        'count': double.tryParse(row['Count']?.toString() ?? '0') ?? 0.0,
        'weight': double.tryParse(row['Weight (g)']?.toString() ?? '0') ?? 0.0,
        'total_bottles': double.tryParse(row['Total Bottles on Hand']?.toString() ?? '0') ?? 0.0,
        'syncStatus': 'synced',
        'syncedAt': DateTime.now().toIso8601String(),
        'createdAt': row['created_at'] ?? DateTime.now().toIso8601String(),
      };
      await _counts!.put(id, count);
      added++;
    }

    // 3. PURGE: Remove items that exist locally but NOT on Server
    // (Only if they were previously marked as 'synced'. Don't delete pending work!)
    final allKeys = _counts!.keys.toList();
    for (var key in allKeys) {
      if (!serverIds.contains(key)) {
        final localItem = _safeCast(_counts!.get(key));
        if (localItem['syncStatus'] == 'synced') {
          await _counts!.delete(key);
          deleted++;
        }
      }
    }

    _updatePendingCounts();
    notifyListeners();
    if (kDebugMode) {
      print("Sync Result: $added updated, $skipped kept local, $deleted removed (zombies).");
    }
  }

  // --- AUDIT ---
  Future<void> saveAudit(Map<String, dynamic> audit) async {
    if (!_isReady) return;
    if ((audit['Audit ID']?.toString() ?? '').isNotEmpty) await _audits!.put(audit['Audit ID'], audit);
  }

  Future<Map<String, dynamic>?> getCurrentAudit() async {
    if (!_isReady) return null;
    final audits = _audits!.values.map((e) => _safeCast(e)).toList();
    return audits.firstWhere((a) => a['Current Audit'] == true || a['currentAudit'] == true, orElse: () => audits.isNotEmpty ? audits.first : {});
  }

  // ✅ NEW METHOD: Get pending invoice details (for sync)
  Future<List<Map<String, dynamic>>> getPendingInvoiceDetails() async {
    if (!_isReady || _invoiceDetails == null) return [];
    return _invoiceDetails!.values
        .map((v) => _safeCast(v))
        .where((v) => v['syncStatus'] == 'pending')
        .toList();
  }

  // ✅ CORRECT: Use existing _safeDouble method from OfflineStorage
  Future<double?> getCostBySupplierAndBottleId(String supplierID, String bottleID) async {
    if (!_isReady || _masterCatalog == null) return null;

    // Search MasterCost data for matching supplier + bottle ID
    final allCosts = await getMasterCosts();
    final match = allCosts.firstWhere(
          (c) =>
      c['supplierID']?.toString() == supplierID &&
          (c['bottleID']?.toString() == bottleID || c['PLU']?.toString() == bottleID),
      orElse: () => <String, dynamic>{},
    );

    // ✅ USE EXISTING _safeCast METHOD FROM OfflineStorage
    final costValue = match['Cost'] ?? match['Cost Price'] ?? match['Unit Cost'];
    return costValue != null ? _safeDouble(costValue) : null;
  }

  // ✅ ADD _safeDouble method to OfflineStorage class:
  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    if (value is String) {
      final cleaned = value.replaceAll(',', '').replaceAll(RegExp(r'[^\d.]'), '');
      return double.tryParse(cleaned) ?? 0.0;
    }
    return 0.0;
  }

  // ✅ NEW: Get all master costs (for cost lookup)
  Future<List<Map<String, dynamic>>> getMasterCosts() async {
    if (!_isReady || _masterCatalog == null) return [];
    return _masterCatalog!.values
        .map(_safeCast)
        .where((c) => c['Cost'] != null || c['Cost Price'] != null)
        .map((c) => {
      'bottleID': c['bottleID']?.toString() ?? c['PLU']?.toString() ?? '',
      'supplierID': c['supplierID']?.toString() ?? '',
      'Cost': c['Cost'] ?? c['Cost Price'] ?? 0.0,
    })
        .toList();
  }

  // ✅ NEW: Get supplier name by ID (for cost lookup)
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

  // --- NEW: PURCHASES ---
  Future<void> savePurchases(List<dynamic> items) async {
    if (!_isReady) return;
    await _purchases!.clear();
    await _purchases!.addAll(items.map((e) => _safeCast(e)));
  }

  Future<List<Map<String, dynamic>>> getPurchases() async {
    if (!_isReady) return [];
    return _purchases!.values.map((e) => _safeCast(e)).toList();
  }

  // ✅ NEW METHOD: Save SINGLE purchase item (for GRV line items)
  Future<void> savePurchase(Map<String, dynamic> purchase) async {
    if (!_isReady || _purchases == null) return;

    // Generate unique ID if not provided
    final id = purchase['purchases_ID'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    purchase['purchases_ID'] = id;

    // Ensure syncStatus is set
    purchase['syncStatus'] = purchase['syncStatus'] ?? 'pending';

    await _purchases!.add(purchase);
    notifyListeners();
  }

  Future<void> updatePurchase(String id, Map<String, dynamic> updates) async {
    if (!_isReady || _purchases == null) return;
    final existing = _purchases!.get(id);
    if (existing == null) return;

    final updated = {..._safeCast(existing), ...updates};
    await _purchases!.put(id, updated);
    notifyListeners();
  }

  // --- NEW: STORE SALES DATA (RAW POS LOGS) ---
  Future<void> saveStoreSalesData(List<dynamic> items) async {
    if (!_isReady) return;
    await _storeSalesData!.clear();
    await _storeSalesData!.addAll(items.map((e) => _safeCast(e)));
  }

  Future<List<Map<String, dynamic>>> getStoreSalesData() async {
    if (!_isReady) return [];
    return _storeSalesData!.values.map((e) => _safeCast(e)).toList();
  }

  // --- NEW: ITEM SALES MAP (PLU -> INVENTORY LINK) ---
  Future<void> saveItemSalesMap(List<dynamic> items) async {
    if (!_isReady) return;
    await _itemSalesMap!.clear();
    await _itemSalesMap!.addAll(items.map((e) => _safeCast(e)));
  }

  Future<List<Map<String, dynamic>>> getItemSalesMap() async {
    if (!_isReady) return [];
    return _itemSalesMap!.values.map((e) => _safeCast(e)).toList();
  }

  // Forcefully overwrite local counts with server counts
  Future<void> overwriteLocalCounts(List<Map<String, dynamic>> remoteCounts) async {
    if (!_isReady) return;

    // 1. Keep any PENDING (unsynced) work so we don't lose it
    final pendingItems = _counts!.values
        .map((e) => _safeCast(e))
        .where((c) => c['syncStatus'] == 'pending' || c['syncStatus'] == 'deleted')
        .toList();

    // 2. Clear the box
    await _counts!.clear();

    // 3. Re-add Remote Counts
    for (var row in remoteCounts) {
      final id = row['stockTake_ID']?.toString() ?? '';
      if (id.isEmpty) continue;

      final count = {
        'id': id,
        'stock_id': id,
        'date': row['Date'],
        'barcode': row['Barcode'],
        'productName': row['Product Name'],
        'mainCategory': row['Main Category'],
        'category': row['Category'],
        'location': row['Location'],
        'pack_size': row['Case/Pack Size'],
        'count': double.tryParse(row['Count']?.toString() ?? '0') ?? 0.0,
        'weight': double.tryParse(row['Weight (g)']?.toString() ?? '0') ?? 0.0,
        'total_bottles': double.tryParse(row['Total Bottles on Hand']?.toString() ?? '0') ?? 0.0,
        'syncStatus': 'synced',
        'syncedAt': DateTime.now().toIso8601String(),
        'createdAt': row['created_at'] ?? DateTime.now().toIso8601String(),
      };
      await _counts!.put(id, count);
    }

    // 4. Restore Pending Work (Optimization: Don't overwrite if remote exists)
    for (var p in pendingItems) {
      await _counts!.put(p['id'], p);
    }

    _updatePendingCounts();
    notifyListeners();
  }

  // --- MAINTENANCE ---
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

  Future<void> clearAllData() async {
    if (!_isReady) return;
    await _counts!.clear();
    await _inventory!.clear();
    await _locations!.clear();
    await _audits!.clear();
    await _purchases!.clear();
    await _storeSalesData!.clear();
    await _itemSalesMap!.clear();
    await _invoiceDetails?.clear();
    await _masterSuppliers?.clear();
    _updatePendingCounts();
    notifyListeners();
  }

  Future<Map<String, int>> getDatabaseStats() async {
    if (!_isReady) return {'stockCounts': 0};
    return {
      'stockCounts': _counts!.length,
      'inventoryItems': _inventory!.length,
      'locations': _locations!.length,
      'audits': _audits!.length,
      'pendingSync': _pendingCounts.length,
      'purchases': _purchases!.length,
      'sales': _storeSalesData!.length,
      'invoices': _invoiceDetails?.length ?? 0,
      'suppliers': _masterSuppliers?.length ?? 0,
    };
  }

  // ✅ FIXED: Removed duplicate method definition
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
  }
}