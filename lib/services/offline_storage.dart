import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

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

  bool _isReady = false;
  String? _currentStoreId;
  List<Map<String, dynamic>> _pendingCounts = [];

  List<Map<String, dynamic>> get pendingCounts => _pendingCounts;
  bool get isReady => _isReady;
  String? get currentStoreId => _currentStoreId;

  Future<void> init() async {
    _isReady = true;
  }

  Future<void> switchStore(String storeId) async {
    if (_currentStoreId == storeId && _isReady) return;
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

    _currentStoreId = storeId;
    _isReady = true;
    _updatePendingCounts();
    notifyListeners();
  }

  Future<void> _closeBoxes() async {
    if (_counts != null && _counts!.isOpen) await _counts!.close();
    if (_inventory != null && _inventory!.isOpen) await _inventory!.close();
    if (_locations != null && _locations!.isOpen) await _locations!.close();
    if (_audits != null && _audits!.isOpen) await _audits!.close();
    if (_masterCatalog != null && _masterCatalog!.isOpen) await _masterCatalog!.close();

    if (_purchases != null && _purchases!.isOpen) await _purchases!.close();
    if (_storeSalesData != null && _storeSalesData!.isOpen) await _storeSalesData!.close();
    if (_itemSalesMap != null && _itemSalesMap!.isOpen) await _itemSalesMap!.close();
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
    if (!_isReady) return;
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

  // --- MAINTENANCE ---
  Future<void> clearAllStockCounts() async { if (_isReady) { await _counts!.clear(); _updatePendingCounts(); notifyListeners(); } }
  Future<void> clearInventory() async { if (_isReady) { await _inventory!.clear(); notifyListeners(); } }
  Future<void> clearLocations() async { if (_isReady) { await _locations!.clear(); notifyListeners(); } }
  Future<void> clearAudits() async { if (_isReady) { await _audits!.clear(); notifyListeners(); } }

  Future<void> clearAllData() async {
    if (!_isReady) return;
    await _counts!.clear();
    await _inventory!.clear();
    await _locations!.clear();
    await _audits!.clear();
    await _purchases!.clear();
    await _storeSalesData!.clear();
    await _itemSalesMap!.clear();
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
    };
  }
}