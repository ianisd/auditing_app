import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'offline_storage.dart';
import 'google_sheets_service.dart';
import 'logger_service.dart';

class SyncResult {
  final bool hasInternet;
  final int syncedCount;
  final String message;
  final bool success;

  SyncResult({
    required this.hasInternet,
    required this.syncedCount,
    required this.message,
    this.success = false,
  });
}

class SyncService with ChangeNotifier {
  final OfflineStorage offlineStorage;
  final GoogleSheetsService googleSheets;
  final Connectivity connectivity;
  final LoggerService? logger;

  bool _isSyncing = false;
  String _lastSyncTime = '';
  int _lastSyncCount = 0;
  bool _inventoryLoaded = false;
  String? _lastError;

  bool get isSyncing => _isSyncing;
  String get lastSyncTime => _lastSyncTime;
  int get lastSyncCount => _lastSyncCount;
  bool get inventoryLoaded => _inventoryLoaded;
  String? get lastError => _lastError;

  SyncService({
    required this.offlineStorage,
    required this.googleSheets,
    this.logger,
  }) : connectivity = Connectivity() {
    _initConnectivity();
  }

  void _initConnectivity() {
    connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
      notifyListeners();
    });
  }

  Future<bool> checkConnectivity() async {
    try {
      final connectivityResult = await connectivity.checkConnectivity();
      return connectivityResult.isNotEmpty &&
          connectivityResult.any((result) => result != ConnectivityResult.none);
    } catch (e) {
      return false;
    }
  }

  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  // --- SYNC ALL (UPLOAD) ---
  Future<SyncResult> syncAll() async {
    if (_isSyncing) return SyncResult(hasInternet: true, syncedCount: 0, message: 'Busy', success: false);

    _isSyncing = true;
    _lastError = null;
    notifyListeners();
    logger?.info('Sync Started...');

    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) {
        logger?.info('Sync Aborted: No Internet');
        return SyncResult(hasInternet: false, syncedCount: 0, message: 'No internet', success: false);
      }

      // 0. Sync Locations
      final newLocations = await offlineStorage.getPendingLocations();
      if (newLocations.isNotEmpty) {
        logger?.info('Uploading ${newLocations.length} new locations...');
        final success = await googleSheets.syncNewLocations(newLocations);
        if (success) {
          final ids = newLocations.map((e) => e['locationID'].toString()).toList();
          await offlineStorage.markLocationsAsSynced(ids);
        }
      }

      // 1. Sync Products
      final newProducts = await offlineStorage.getPendingNewProducts();
      if (newProducts.isNotEmpty) {
        logger?.info('Uploading ${newProducts.length} new products...');
        await googleSheets.syncNewProducts(newProducts);
        final barcodes = newProducts.map((e) => e['Barcode'].toString()).toList();
        await offlineStorage.markNewProductsAsSynced(barcodes);
      }

      // 2. Sync Counts
      final pending = offlineStorage.pendingCounts;
      if (pending.isEmpty) {
        _lastSyncTime = _formatDateTime(DateTime.now());
        notifyListeners();
        logger?.info('Sync Complete: Up to date');
        return SyncResult(hasInternet: true, syncedCount: 0, message: 'Up to date', success: true);
      }

      logger?.info('Uploading ${pending.length} counts...');
      final success = await googleSheets.syncStockCounts(pending);

      if (success) {
        final ids = pending.where((c) => c['id'] != null).map((c) => c['id'].toString()).toList();
        await offlineStorage.markMultipleAsSynced(ids);
        _lastSyncTime = _formatDateTime(DateTime.now());
        _lastSyncCount = pending.length;
        return SyncResult(hasInternet: true, syncedCount: pending.length, message: 'Synced', success: true);
      } else {
        return SyncResult(hasInternet: true, syncedCount: 0, message: 'Sync failed', success: false);
      }
    } catch (e) {
      _lastError = e.toString();
      logger?.error('Sync Exception', e);
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Error: $e', success: false);
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<int> downloadExistingCounts() async {
    if (_isSyncing) return 0;
    _isSyncing = true;
    notifyListeners();
    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) throw Exception('No internet');
      logger?.info('Downloading existing counts...');
      final remoteCounts = await googleSheets.fetchStockCounts();
      if (remoteCounts.isNotEmpty) await offlineStorage.saveRemoteStockCounts(remoteCounts);
      return remoteCounts.length;
    } catch (e) {
      logger?.error('Download Failed', e);
      rethrow;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  // --- REFRESH MASTER DATA (DEBUGGING ENHANCED) ---
  Future<SyncResult> refreshMasterData() async {
    if (_isSyncing) return SyncResult(hasInternet: true, syncedCount: 0, message: 'Busy', success: false);

    _isSyncing = true;
    _lastError = null;
    notifyListeners();
    logger?.info('Master Refresh: Starting...');

    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) return SyncResult(hasInternet: false, syncedCount: 0, message: 'No internet', success: false);

      logger?.info('Fetching Store Data & Costs...');

      // Fetch all in parallel
      final results = await Future.wait([
        googleSheets.fetchInventory(),
        googleSheets.fetchLocations(),
        googleSheets.fetchAudits(),
        googleSheets.fetchPurchases(),
        googleSheets.fetchStoreSalesData(),
        googleSheets.fetchItemSales(),
        googleSheets.fetchComputedCosts()
      ]);

      var inventory = results[0];
      final locations = results[1];
      final audits = results[2];
      final purchases = results[3];
      final storeSales = results[4];
      final itemSalesMap = results[5];
      final masterCosts = results[6];

      // --- DEBUGGING LOGIC ---
      if (masterCosts.isEmpty) {
        logger?.error('WARNING: MasterCosts returned 0 items.');
      } else {
        logger?.info('MasterCosts: Loaded ${masterCosts.length} items.');
        logger?.info('MasterCosts Keys (Sample): ${masterCosts.first.keys.toList()}');
      }

      if (inventory.isEmpty) {
        logger?.error('WARNING: Store Inventory returned 0 items.');
      } else {
        logger?.info('Inventory Keys (Sample): ${inventory.first.keys.toList()}');
      }

      // Build Cost Map
      final costMap = <String, double>{};
      for (var c in masterCosts) {
        // Handle variations in casing
        final name = (c['productName'] ?? c['Product Name'])?.toString().toLowerCase().trim();
        final cost = _safeDouble(c['avgCost'] ?? c['avgcost'] ?? c['Cost'] ?? c['Unit Cost']);

        if (name != null && name.isNotEmpty && cost > 0) {
          costMap[name] = cost;
        }
      }

      logger?.info('Built Cost Map with ${costMap.length} valid entries.');

      // Inject Costs
      int costsUpdated = 0;
      final updatedInventory = inventory.map((item) {
        // Try multiple keys for Name
        final rawName = item['Inventory Product Name'] ?? item['Product Name'] ?? item['productName'];
        final name = rawName?.toString().toLowerCase().trim() ?? '';

        final newItem = Map<String, dynamic>.from(item);

        if (costMap.containsKey(name)) {
          newItem['Cost Price'] = costMap[name];
          costsUpdated++;
        } else {
          newItem['Cost Price'] = _safeDouble(newItem['Cost Price']);
        }
        return newItem;
      }).toList();

      if (updatedInventory.isNotEmpty && costsUpdated == 0) {
        logger?.error('CRITICAL: No costs matched! Name mismatch suspected.');
        if (costMap.isNotEmpty) {
          logger?.info('Example Cost Key: "${costMap.keys.first}"');
          logger?.info('Example Inv Key:  "${updatedInventory.first['Inventory Product Name']?.toString().toLowerCase().trim()}"');
        }
      } else {
        logger?.info('Merged costs into $costsUpdated inventory items.');
      }

      // Save Data
      await offlineStorage.clearInventory();
      await offlineStorage.clearLocations();
      await offlineStorage.clearAudits();

      await offlineStorage.bulkSaveInventory(updatedInventory);
      await offlineStorage.bulkSaveLocations(locations);
      await offlineStorage.savePurchases(purchases);
      await offlineStorage.saveStoreSalesData(storeSales);
      await offlineStorage.saveItemSalesMap(itemSalesMap);

      for (final audit in audits) await offlineStorage.saveAudit(audit);

      _inventoryLoaded = true;
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Updated $costsUpdated costs', success: true);

    } catch (e) {
      _lastError = 'Refresh error: $e';
      logger?.error('Master Refresh Failed', e);
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Error: $e', success: false);
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> loadInventory() async { await refreshMasterData(); }

  Future<Map<String, int>> getDatabaseStats() async {
    try {
      return await offlineStorage.getDatabaseStats();
    } catch (e) {
      return {'stockCounts': 0, 'inventoryItems': 0};
    }
  }

  Future<bool> hasData() async {
    final stats = await getDatabaseStats();
    return stats['inventoryItems']! > 0;
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')} ${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }

  Future<Map<String, dynamic>> getSyncStatus() async {
    final stats = await getDatabaseStats();
    final hasInternet = await checkConnectivity();
    return {
      'hasInternet': hasInternet,
      'isSyncing': _isSyncing,
      'lastSyncTime': _lastSyncTime,
      'lastSyncCount': _lastSyncCount,
      'pendingCount': stats['pendingSync'] ?? 0,
      'totalCounts': stats['stockCounts'] ?? 0,
      'inventoryLoaded': _inventoryLoaded,
      'lastError': _lastError,
      'inventoryCount': stats['inventoryItems'] ?? 0,
    };
  }
}