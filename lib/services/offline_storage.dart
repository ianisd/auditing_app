import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

class OfflineStorage with ChangeNotifier {
  Box? _counts;
  Box? _inventory;
  Box? _locations;
  Box? _audits;
  Box? _masterCatalog; // <--- ADDED

  bool _isReady = false;
  String? _currentStoreId;
  List<Map<String, dynamic>> _pendingCounts = [];

  List<Map<String, dynamic>> get pendingCounts => _pendingCounts;
  bool get isReady => _isReady;
  String? get currentStoreId => _currentStoreId;

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    Hive.init(appDir.path);
  }

  Future<void> switchStore(String storeId) async {
    if (_currentStoreId == storeId && _isReady) return;
    _isReady = false;
    notifyListeners();

    await _closeBoxes();

    // Open store-specific boxes
    _counts = await Hive.openBox('store_${storeId}_stock_counts');
    _inventory = await Hive.openBox('store_${storeId}_inventory_items');
    _locations = await Hive.openBox('store_${storeId}_locations');
    _audits = await Hive.openBox('store_${storeId}_audits');

    // Open Master Catalog (Store specific cache)
    _masterCatalog = await Hive.openBox('store_${storeId}_master_catalog'); // <--- ADDED

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
    if (_masterCatalog != null && _masterCatalog!.isOpen) await _masterCatalog!.close(); // <--- ADDED
  }

  Map<String, dynamic> _safeCast(dynamic item) {
    if (item == null) return {};
    if (item is Map) return Map<String, dynamic>.from(item);
    return {};
  }

  // --- NEW: MASTER CATALOG OPERATIONS ---

  Future<void> saveMasterCatalog(List<dynamic> items) async {
    if (!_isReady) return;

    // Clear old cache first
    await _masterCatalog!.clear();

    final Map<String, Map<String, dynamic>> batch = {};

    for (final rawItem in items) {
      if (rawItem is Map) {
        final item = Map<String, dynamic>.from(rawItem);
        // Normalize Barcode
        final barcode = item['Barcode']?.toString() ?? item['barcode']?.toString() ?? '';

        // Normalize Product Name
        if (item['Inventory Product Name'] == null && item['Product Name'] != null) {
          item['Inventory Product Name'] = item['Product Name'];
        }

        if (barcode.isNotEmpty) {
          batch[barcode] = item;
        }
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
    final barcode = masterItem['Barcode']?.toString() ?? '';
    if (barcode.isEmpty) return;

    // Create a copy to modify
    final localItem = Map<String, dynamic>.from(masterItem);

    // Flag it as synced (because it exists in Master DB) but treat as local inventory now
    localItem['syncStatus'] = 'synced';
    localItem['isLocal'] = false; // It is not a "newly created" item, it's a "known" item

    await _inventory!.put(barcode, localItem);
    notifyListeners();
  }

  // --- INVENTORY OPERATIONS ---

  Future<void> bulkSaveInventory(List<dynamic> items) async {
    if (!_isReady) return;
    final Map<String, Map<String, dynamic>> batch = {};

    for (final rawItem in items) {
      if (rawItem is Map) {
        final item = Map<String, dynamic>.from(rawItem);

        // 1. Normalize Barcode (Handle numbers and missing keys)
        final barcode = item['Barcode']?.toString() ?? item['barcode']?.toString() ?? '';

        // 2. Normalize Product Name (Handle "Product Name" vs "Inventory Product Name")
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

  // --- LOCATION OPERATIONS ---

  Future<void> bulkSaveLocations(List<dynamic> locations) async {
    if (!_isReady) return;
    final Map<String, Map<String, dynamic>> batch = {};
    for (final rawLoc in locations) {
      if (rawLoc is Map) {
        final loc = Map<String, dynamic>.from(rawLoc);
        final id = loc['locationID']?.toString() ?? '';
        if (id.isNotEmpty) batch[id] = loc;
      }
    }
    await _locations!.putAll(batch);
  }

  Future<void> saveLocation(Map<String, dynamic> location) async {
    if (!_isReady) return;
    final locationId = location['locationID']?.toString() ??
        location['id']?.toString() ??
        DateTime.now().millisecondsSinceEpoch.toString();
    location['locationID'] = locationId;
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

  // --- STOCK COUNT OPERATIONS ---

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

  // --- SYNC OPERATIONS ---

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

  // --- DOWNLOAD EXISTING ---
  Future<void> saveRemoteStockCounts(List<Map<String, dynamic>> remoteCounts) async {
    if (!_isReady) return;
    for (var row in remoteCounts) {
      final id = row['stockTake_ID']?.toString() ?? '';
      if (id.isNotEmpty) {
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
          'count': int.tryParse(row['Count']?.toString() ?? '0') ?? 0,
          'weight': double.tryParse(row['Weight (g)']?.toString() ?? '0') ?? 0.0,
          'singleUnitVolume': double.tryParse(row['Single Unit Volume']?.toString() ?? '0'),
          'uom': row['UoM'],
          'syncStatus': 'synced',
          'syncedAt': DateTime.now().toIso8601String(),
          'createdAt': row['created_at'] ?? DateTime.now().toIso8601String(),
        };
        await _counts!.put(id, count);
      }
    }
    _updatePendingCounts();
    notifyListeners();
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
    await _masterCatalog!.clear(); // <--- ADDED
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
      'masterItems': _masterCatalog!.length, // <--- ADDED
      'pendingSync': _pendingCounts.length,
    };
  }
}