import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'offline_storage.dart';
import 'google_sheets_service.dart';
import 'logger_service.dart'; // Import Logger

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
  final LoggerService? logger; // Logger field

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
    this.logger, // Constructor
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

  // --- 1. SYNC ALL (UPLOAD) ---
  Future<SyncResult> syncAll() async {
    if (_isSyncing) return SyncResult(hasInternet: true, syncedCount: 0, message: 'Busy', success: false);

    _isSyncing = true;
    _lastError = null;
    notifyListeners();
    logger?.info('Sync Started: Checking for pending uploads...');

    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) {
        logger?.info('Sync Aborted: No Internet Connection');
        return SyncResult(hasInternet: false, syncedCount: 0, message: 'No internet', success: false);
      }
      // 0. Sync New Locations (ADD THIS BLOCK)
      final newLocations = await offlineStorage.getPendingLocations();
      if (newLocations.isNotEmpty) {
        logger?.info('Uploading ${newLocations.length} new locations...');
        final success = await googleSheets.syncNewLocations(newLocations);
        if (success) {
          final ids = newLocations.map((e) => e['locationID'].toString()).toList();
          await offlineStorage.markLocationsAsSynced(ids);
        }
      }
      // 1. Sync New Products
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
        logger?.info('Sync Complete: Nothing to upload');
        return SyncResult(hasInternet: true, syncedCount: 0, message: 'Up to date', success: true);
      }

      logger?.info('Uploading ${pending.length} counts...');
      final success = await googleSheets.syncStockCounts(pending);

      if (success) {
        final ids = pending
            .where((count) => count['id'] != null)
            .map((count) => count['id'].toString())
            .toList();

        await offlineStorage.markMultipleAsSynced(ids);

        _lastSyncTime = _formatDateTime(DateTime.now());
        _lastSyncCount = pending.length;
        _lastError = null;

        logger?.info('Sync Success: Uploaded ${pending.length} counts');
        return SyncResult(hasInternet: true, syncedCount: pending.length, message: 'Synced ${pending.length} counts', success: true);
      } else {
        _lastError = 'Sync failed';
        logger?.error('Sync Failed: Server returned failure status');
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

      logger?.info('Downloading existing counts from server...');
      final remoteCounts = await googleSheets.fetchStockCounts();

      if (remoteCounts.isNotEmpty) {
        await offlineStorage.saveRemoteStockCounts(remoteCounts);
      }
      return remoteCounts.length;
    } catch (e) {
      logger?.error('Download Counts Failed', e);
      rethrow;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<SyncResult> refreshMasterData() async {
    if (_isSyncing) return SyncResult(hasInternet: true, syncedCount: 0, message: 'Busy', success: false);

    _isSyncing = true;
    _lastError = null;
    notifyListeners();
    logger?.info('Master Data Refresh Started...');

    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) {
        logger?.info('Refresh Aborted: No Internet');
        return SyncResult(hasInternet: false, syncedCount: 0, message: 'No internet', success: false);
      }

      print('Refreshing Master Data...');

      // 1. Fetch RAW Store Inventory & Data
      var inventory = await googleSheets.fetchInventory();
      final locations = await googleSheets.fetchLocations();
      final audits = await googleSheets.fetchAudits();
      final purchases = await googleSheets.fetchPurchases();
      final storeSales = await googleSheets.fetchStoreSalesData();
      final itemSalesMap = await googleSheets.fetchItemSales();

      // 2. Fetch LATEST COSTS from Master DB
      print('Fetching Computed Costs...');
      final masterCosts = await googleSheets.fetchComputedCosts();

      // Create Index: "glenfiddich 18yr" -> 1800.57
      final costMap = {
        for (var c in masterCosts)
          c['productName']?.toString().toLowerCase().trim() : c['avgCost']
      };

      logger?.info('Loaded ${costMap.length} costs from Master DB');

      // 3. SMART UPDATE: Inject Master Costs into Store Inventory
      int costsUpdated = 0;
      final updatedInventory = inventory.map((item) {
        final name = item['Inventory Product Name']?.toString().toLowerCase().trim() ?? '';
        final newItem = Map<String, dynamic>.from(item);

        // CHECK 1: Try Master Cost
        dynamic finalCost = costMap[name];

        // CHECK 2: If Master missing, try Existing Inventory Cost
        if (finalCost == null || finalCost == 0) {
          finalCost = item['Cost Price'];
        }

        // CHECK 3: Ensure double
        double parsedCost = 0.0;
        if (finalCost != null) {
          parsedCost = double.tryParse(finalCost.toString()) ?? 0.0;
        }

        if (costMap.containsKey(name)) costsUpdated++;

        newItem['Cost Price'] = parsedCost;
        return newItem;
      }).toList();

      logger?.info('Matched costs for $costsUpdated out of ${updatedInventory.length} items');

      // 4. Fetch Master Catalog
      final masterCatalog = await _fetchAndMergeMasterDB(preFetchedCosts: costMap);

      // 5. Save to Local Storage
      await offlineStorage.clearInventory();
      // await offlineStorage.clearLocations(); // KEEP THIS COMMENTED OUT!
      await offlineStorage.clearAudits();

      await offlineStorage.bulkSaveInventory(updatedInventory);
      await offlineStorage.bulkSaveLocations(locations);
      await offlineStorage.saveMasterCatalog(masterCatalog);
      await offlineStorage.savePurchases(purchases);
      await offlineStorage.saveStoreSalesData(storeSales);
      await offlineStorage.saveItemSalesMap(itemSalesMap);

      for (final audit in audits) await offlineStorage.saveAudit(audit);

      _inventoryLoaded = true;
      logger?.info('Master Refresh Success: ${updatedInventory.length} store items loaded');

      return SyncResult(
          hasInternet: true,
          syncedCount: 0,
          message: 'Synced ${updatedInventory.length} items. Updated $costsUpdated costs.',
          success: true
      );

    } catch (e) {
      _lastError = 'Refresh error: $e';
      logger?.error('Master Refresh Exception', e);
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Error: $e', success: false);
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  // Helper to fetch and merge master tables
  Future<List<Map<String, dynamic>>> _fetchAndMergeMasterDB({Map<dynamic, dynamic>? preFetchedCosts}) async {
    final products = await googleSheets.fetchMasterProducts();
    final barcodes = await googleSheets.fetchMasterBarcodes();

    // Use the passed costs, or fetch if not provided
    var costMap = preFetchedCosts;
    if (costMap == null) {
      final costs = await googleSheets.fetchComputedCosts();
      costMap = {
        for (var c in costs)
          c['productName']?.toString().toLowerCase().trim() : c['avgCost']
      };
    }

    final productMap = { for (var p in products) p['bottleID']?.toString() : p };

    List<Map<String, dynamic>> flatInventory = [];

    for (var b in barcodes) {
      final bottleID = b['bottleID']?.toString();
      final barcode = b['Barcode']?.toString();
      if (barcode == null || barcode.isEmpty) continue;

      final productInfo = productMap[bottleID] ?? {};
      final name = b['Product Name'] ?? productInfo['Product Name'] ?? 'Unknown';

      // LOOKUP COST
      final cost = costMap[name.toString().toLowerCase().trim()] ?? 0.0;

      flatInventory.add({
        'Barcode': barcode,
        'Inventory Product Name': name,
        'Main Category': productInfo['Category'] ?? b['Category'] ?? '',
        'Category': productInfo['Category'] ?? b['Category'] ?? '',
        'Single Unit Volume': b['Single Unit Volume'] ?? productInfo['Single Unit Volume'],
        'UoM': b['UoM'] ?? productInfo['UoM'],
        'Gradient': b['Gradient'] ?? productInfo['Gradient'],
        'Intercept': b['Intercept'] ?? productInfo['Intercept'],
        'Pack Size': b['Pack Size'] ?? 'Single',
        'Cost Price': cost,
      });
    }
    return flatInventory;
  }

  Future<void> loadInventory() async { await refreshMasterData(); }

  // Stats & Status
  Future<Map<String, int>> getDatabaseStats() async {
    try {
      return await offlineStorage.getDatabaseStats();
    } catch (e) {
      return {'stockCounts': 0, 'inventoryItems': 0};
    }
  }

  Future<bool> hasData() async {
    final stats = await getDatabaseStats();
    return stats['inventoryItems']! > 0 || stats['locations']! > 0;
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