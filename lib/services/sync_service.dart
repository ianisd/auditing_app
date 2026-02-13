import 'dart:async';
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

  bool _isDisposed = false; // ✅ ONLY ONE DEFINITION

  bool get isDisposed => _isDisposed;

  bool _isSyncing = false;
  String _lastSyncTime = '';
  int _lastSyncCount = 0;
  bool _inventoryLoaded = false;
  String? _lastError;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  bool get isSyncing => _isSyncing && !_isDisposed; // ✅ Add safety check
  String get lastSyncTime => _lastSyncTime;
  int get lastSyncCount => _lastSyncCount;
  bool get inventoryLoaded => _inventoryLoaded;
  String? get lastError => _lastError;

  void _safeNotify() {
    if (!_isDisposed) {
      notifyListeners();
    } else {
      logger?.error('SyncService: Attempted to notify after disposal');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _connectivitySubscription?.cancel();
    googleSheets.dispose();
    super.dispose();
  }

  SyncService({
    required this.offlineStorage,
    required this.googleSheets,
    this.logger,
  }) : connectivity = Connectivity() {
    _initConnectivity();
  }

  void _initConnectivity() {
    _connectivitySubscription = connectivity.onConnectivityChanged.listen((results) {
      _safeNotify();
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
    if (_isDisposed) {
      logger?.error('SyncService: syncAll() called after disposal');
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Service disposed', success: false);
    }

    if (_isSyncing) {
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Busy', success: false);
    }

    _isSyncing = true;
    _lastError = null;
    _safeNotify(); // ✅ USE SAFE NOTIFY
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

      final pendingInvoices = await offlineStorage.getPendingInvoiceDetails();
      if (pendingInvoices.isNotEmpty) {
        logger?.info('Uploading ${pendingInvoices.length} invoice headers...');
        final success = await googleSheets.syncInvoiceDetails(pendingInvoices);
        if (success) {
          // Mark invoices as synced (simplified - in production, track individual IDs)
          logger?.info('Invoices synced successfully');
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
        _safeNotify();
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
      if (!_isDisposed) {
        _lastError = e.toString();
        logger?.error('Sync Exception', e);
      }
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Error: $e', success: false);
    } finally {
      if (!_isDisposed) {
        _isSyncing = false;
        _safeNotify();
      }
    }
  }

  // --- DOWNLOAD (STRICT SAFEGUARD) ---
  Future<int> downloadExistingCounts() async {
    if (_isDisposed) {
      logger?.error('SyncService: downloadExistingCounts() called after disposal');
      return 0;
    }

    if (_isSyncing) return 0;

    // SAFEGUARD: Block download if there are ANY pending changes
    if (offlineStorage.pendingCounts.isNotEmpty) {
      const msg = 'Cannot download: You have unsynced changes. Please press "Sync Data" (Upload) first.';
      logger?.error(msg);
      throw Exception(msg);
    }

    _isSyncing = true;
    _safeNotify();
    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) throw Exception('No internet');

      logger?.info('Downloading clean list from server...');
      final remoteCounts = await googleSheets.fetchStockCounts();

      // Wipe & Replace (Safe now because we checked for pending items above)
      await offlineStorage.overwriteLocalCounts(remoteCounts);

      return remoteCounts.length;
    } catch (e) {
      if (!_isDisposed) {
        logger?.error('Download Failed', e);
      }
      rethrow;
    } finally {
      if (!_isDisposed) {
        _isSyncing = false;
        _safeNotify();
      }
    }
  }

  // --- REFRESH MASTER DATA ---
  Future<SyncResult> refreshMasterData() async {
    if (_isDisposed) {
      logger?.error('SyncService: refreshMasterData() called after disposal');
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Service disposed', success: false);
    }

    if (_isSyncing) return SyncResult(hasInternet: true, syncedCount: 0, message: 'Busy', success: false);

    _isSyncing = true;
    _lastError = null;
    _safeNotify();
    logger?.info('Master Refresh: Starting...');

    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) return SyncResult(hasInternet: false, syncedCount: 0, message: 'No internet', success: false);

      logger?.info('Fetching Store Data & Costs...');

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

      // Build Cost Map
      final costMap = <String, double>{};
      for (var c in masterCosts) {
        final name = (c['productName'] ?? c['Product Name'])?.toString().toLowerCase().trim();
        final cost = _safeDouble(c['avgCost'] ?? c['avgcost'] ?? c['Cost'] ?? c['Unit Cost']);

        if (name != null && name.isNotEmpty && cost > 0) {
          costMap[name] = cost;
        }
      }

      // Inject Costs
      int costsUpdated = 0;
      final updatedInventory = inventory.map((item) {
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
      if (!_isDisposed) {
        _lastError = 'Refresh error: $e';
        logger?.error('Master Refresh Failed', e);
      }
      return SyncResult(hasInternet: true, syncedCount: 0, message: 'Error: $e', success: false);
    } finally {
      if (!_isDisposed) {
        _isSyncing = false;
        _safeNotify();
      }
    }
  }

  Future<void> loadInventory() async {
    if (!_isDisposed) {
      await refreshMasterData();
    }
  }

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
    if (_isDisposed) {
      return {
        'hasInternet': false,
        'isSyncing': false,
        'lastSyncTime': '',
        'lastSyncCount': 0,
        'pendingCount': 0,
        'totalCounts': 0,
        'inventoryLoaded': false,
        'lastError': 'Service disposed',
        'inventoryCount': 0,
      };
    }

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