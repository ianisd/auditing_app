// ============================================================================
// COMPLETE sync_service.dart - FIXED VERSION
// ============================================================================

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'offline_storage.dart';
import 'google_sheets_service.dart';
import 'firestore_service.dart';
import 'logger_service.dart';

// ==================== SYNC RESULT MODEL ====================
// ==================== ENHANCED SYNC RESULT MODEL ====================
class SyncResult {
  final bool hasInternet;
  final int syncedCount;
  final String message;
  final bool success;
  final List<Map<String, dynamic>> duplicates;

  // 🔥 NEW: Detailed sync breakdown
  final int invoicesSynced;
  final int purchasesSynced;
  final int pluMappingsSynced;
  final int stockCountsSynced;
  final int locationsSynced;
  final int productsSynced;
  final int totalDeleted;

  SyncResult({
    required this.hasInternet,
    required this.syncedCount,
    required this.message,
    this.success = false,
    this.duplicates = const [],
    this.invoicesSynced = 0,
    this.purchasesSynced = 0,
    this.pluMappingsSynced = 0,
    this.stockCountsSynced = 0,
    this.locationsSynced = 0,
    this.productsSynced = 0,
    this.totalDeleted = 0,
  });

  String get detailedMessage {
    final parts = <String>[];
    if (invoicesSynced > 0) parts.add('$invoicesSynced Invoice${invoicesSynced > 1 ? 's' : ''}');
    if (purchasesSynced > 0) parts.add('$purchasesSynced Purchase${purchasesSynced > 1 ? 's' : ''}');
    if (pluMappingsSynced > 0) parts.add('$pluMappingsSynced PLU Mapping${pluMappingsSynced > 1 ? 's' : ''}');
    if (stockCountsSynced > 0) parts.add('$stockCountsSynced Stock Count${stockCountsSynced > 1 ? 's' : ''}');
    if (locationsSynced > 0) parts.add('$locationsSynced Location${locationsSynced > 1 ? 's' : ''}');
    if (productsSynced > 0) parts.add('$productsSynced Product${productsSynced > 1 ? 's' : ''}');

    String msg = parts.isEmpty ? message : 'Synced: ${parts.join(', ')}';
    if (totalDeleted > 0) {
      msg += ' ($totalDeleted deleted)';
    }
    return msg;
  }
}

// ==================== MAIN SYNC SERVICE ====================
class SyncService with ChangeNotifier {
  // ==================== DEPENDENCIES ====================
  final OfflineStorage offlineStorage;
  final GoogleSheetsService googleSheets;
  final FirestoreService? firestore;
  final Connectivity connectivity;
  final LoggerService? logger;

  // ==================== STATE VARIABLES ====================
  bool _isDisposed = false;
  bool _isSyncing = false;
  String _lastSyncTime = '';
  int _lastSyncCount = 0;
  bool _inventoryLoaded = false;
  String? _lastError;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  List<Map<String, dynamic>>? _cachedSuppliers;
  DateTime? _suppliersCacheTime;
  static const Duration _cacheDuration = Duration(minutes: 5);

  // ==================== GETTERS ====================
  bool get isDisposed => _isDisposed;
  bool get isSyncing => _isSyncing && !_isDisposed;
  String get lastSyncTime => _lastSyncTime;
  int get lastSyncCount => _lastSyncCount;
  bool get inventoryLoaded => _inventoryLoaded;
  String? get lastError => _lastError;

  // ==================== CONSTRUCTOR & INIT ====================
  SyncService({
    required this.offlineStorage,
    required this.googleSheets,
    this.firestore,
    this.logger,
  }) : connectivity = Connectivity() {
    _initConnectivity();
    _initFirestoreListeners();
  }

  void _initFirestoreListeners() {
    if (firestore == null) return;

    final storeId = offlineStorage.currentStoreId;
    if (storeId == null) return;

    // 🔥 REAL-TIME: Listen for changes from other devices via Firestore
    firestore!.watchStockCounts(storeId).listen((remoteCounts) {
      if (!_isSyncing) {
        offlineStorage.saveRemoteStockCounts(remoteCounts);
      }
    });
  }

  void _initConnectivity() {
    _connectivitySubscription = connectivity.onConnectivityChanged.listen((results) {
      if (!_isDisposed) {
        _safeNotify();
      }
    });
  }

  // ==================== LIFECYCLE METHODS ====================
  @override
  void dispose() {
    _isDisposed = true;
    _connectivitySubscription?.cancel();
    googleSheets.dispose();
    super.dispose();
  }

  void _safeNotify() {
    if (!_isDisposed) {
      notifyListeners();
    } else {
      logger?.error('SyncService: Attempted to notify after disposal');
    }
  }

  // ==================== HELPER METHODS - CACHING ====================

  Future<List<Map<String, dynamic>>> getMasterSuppliers() async {
    if (_cachedSuppliers != null &&
        _suppliersCacheTime != null &&
        DateTime.now().difference(_suppliersCacheTime!) < _cacheDuration) {
      return _cachedSuppliers!;
    }

    _cachedSuppliers = await offlineStorage.getMasterSuppliers();
    _suppliersCacheTime = DateTime.now();
    return _cachedSuppliers!;
  }

  // ==================== HELPER METHODS - UTILITIES ====================
  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')} ${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }

  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  Future<Map<String, dynamic>> _syncWithRetry(
      Future<Map<String, dynamic>> Function() syncFn, [
        int maxRetries = 3,
      ]) async {
    int retries = 0;
    while (retries < maxRetries) {
      try {
        final result = await syncFn().timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw TimeoutException('Sync timed out'),
        );
        return result;
      } catch (e) {
        retries++;
        if (retries >= maxRetries) rethrow;
        logger?.info('🔄 Retry $retries/$maxRetries after error: $e');
        await Future.delayed(Duration(seconds: 2 * retries));
      }
    }
    return {'success': false, 'message': 'Max retries exceeded'};
  }

  // ==================== HELPER METHODS - CONNECTIVITY ====================
  Future<bool> checkConnectivity() async {
    try {
      final connectivityResult = await connectivity.checkConnectivity();
      return connectivityResult.isNotEmpty &&
          connectivityResult.any((result) => result != ConnectivityResult.none);
    } catch (e) {
      return false;
    }
  }

  // ==================== HELPER METHODS - DATA PROCESSING ====================
  Map<String, double> _buildCostMap(List<Map<String, dynamic>> masterCosts) {
    final costMap = <String, double>{};
    for (var c in masterCosts) {
      final rawName = c['productName'] ?? c['Product Name'];
      if (rawName == null) continue;

      final name = rawName.toString().toLowerCase().trim();
      final cost = _safeDouble(c['avgCost'] ?? c['avgcost'] ?? c['Cost'] ?? c['Unit Cost']);

      if (name.isNotEmpty && cost > 0) {
        costMap[name] = cost;
      }
    }
    return costMap;
  }

  List<Map<String, dynamic>> _mergeCostsIntoInventory(
      List<Map<String, dynamic>> inventory,
      Map<String, double> costMap,
      ) {
    int costsUpdated = 0;
    final updatedInventory = inventory.map((item) {
      final newItem = Map<String, dynamic>.from(item);
      final rawName = item['Inventory Product Name'] ?? item['Product Name'] ?? item['productName'];

      if (rawName != null) {
        final name = rawName.toString().toLowerCase().trim();
        if (costMap.containsKey(name)) {
          newItem['Cost Price'] = costMap[name];
          costsUpdated++;
        } else {
          newItem['Cost Price'] = _safeDouble(newItem['Cost Price']);
        }
      }
      return newItem;
    }).toList();

    if (updatedInventory.isNotEmpty && costsUpdated == 0 && costMap.isNotEmpty) {
      logger?.error('⚠️ No costs matched! Potential naming mismatch.');
    } else {
      logger?.info('✅ Merged costs into $costsUpdated inventory items.');
    }

    return updatedInventory;
  }

  // ==================== HELPER METHODS - SYNC OPERATIONS (UPLOAD) ====================
  Future<void> _syncNewLocations() async {
    final newLocations = await offlineStorage.getPendingLocations();
    if (newLocations.isNotEmpty) {
      logger?.info('📍 Uploading ${newLocations.length} new locations...');
      final success = await googleSheets.syncNewLocations(newLocations);
      if (success) {
        final ids = newLocations.map((e) => e['locationID'].toString()).toList();
        await offlineStorage.markLocationsAsSynced(ids);
      }
    }
  }

  Future<Map<String, dynamic>> _syncInvoiceHeaders() async {
    try {
      final pendingInvoices = await offlineStorage.getPendingInvoiceDetails();
      if (pendingInvoices.isNotEmpty) {
        logger?.info('📄 Found ${pendingInvoices.length} pending invoice headers...');

        const batchSize = 25;
        int totalProcessed = 0;
        int totalNew = 0;
        int totalUpdated = 0;
        int totalDuplicates = 0;
        List<Map<String, dynamic>> allDuplicates = [];

        for (int i = 0; i < pendingInvoices.length; i += batchSize) {
          final end = (i + batchSize < pendingInvoices.length) ? i + batchSize : pendingInvoices.length;
          final batch = pendingInvoices.sublist(i, end);

          final syncedBatch = batch.map((invoice) {
            final modified = Map<String, dynamic>.from(invoice);
            modified['syncStatus'] = 'synced';
            return modified;
          }).toList();

          logger?.info('📄 Processing batch ${i ~/ batchSize + 1}/${(pendingInvoices.length / batchSize).ceil()} (${batch.length} invoices)');

          final result = await _syncWithRetry(
                () => googleSheets.syncInvoiceDetailsWithResult(syncedBatch),
          );

          if (result['success'] == true) {
            int newCount = result['newCount'] ?? 0;
            int updatedCount = result['updatedCount'] ?? 0;
            int duplicateCount = result['duplicateCount'] ?? 0;

            totalNew += newCount;
            totalUpdated += updatedCount;
            totalDuplicates += duplicateCount;
            totalProcessed += batch.length;

            if (result['duplicates'] != null) {
              allDuplicates.addAll(List<Map<String, dynamic>>.from(result['duplicates']));
            }

            logger?.info('✅ Batch ${i ~/ batchSize + 1} complete: New=$newCount, Updated=$updatedCount, Dupes=$duplicateCount');
            logger?.info('📊 Progress: $totalProcessed/${pendingInvoices.length} invoices processed');

            final invoiceIds = batch
                .map((inv) => inv['invoiceDetailsID']?.toString())
                .where((id) => id != null)
                .cast<String>()
                .toList();

            await offlineStorage.bulkMarkInvoicesAsSynced(invoiceIds);
            await Future.delayed(const Duration(milliseconds: 150));
          } else {
            logger?.error('❌ Batch failed: ${result['message']}');
            return {
              'success': false,
              'message': 'Batch failed after $totalProcessed invoices: ${result['message']}',
              'processed': totalProcessed,
            };
          }
        }

        logger?.info('✅ All invoices synced successfully. Total: New=$totalNew, Updated=$totalUpdated, Dupes=$totalDuplicates');

        return {
          'success': true,
          'newCount': totalNew,
          'updatedCount': totalUpdated,
          'duplicateCount': totalDuplicates,
          'duplicates': allDuplicates,
        };
      }
      return {'success': true, 'newCount': 0, 'updatedCount': 0, 'duplicateCount': 0, 'duplicates': []};
    } catch (e) {
      logger?.error('Error syncing invoices', e.toString());
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<void> _syncPurchases() async {
    try {
      final pendingPurchases = await offlineStorage.getPendingPurchases();
      if (pendingPurchases.isEmpty) return;

      logger?.info('📦 Uploading ${pendingPurchases.length} purchase items in batches...');

      const batchSize = 50;
      int totalProcessed = 0;

      for (int i = 0; i < pendingPurchases.length; i += batchSize) {
        final end = (i + batchSize < pendingPurchases.length) ? i + batchSize : pendingPurchases.length;
        final batch = pendingPurchases.sublist(i, end);

        logger?.info('📦 Processing purchase batch ${i ~/ batchSize + 1} (${batch.length} items)');

        final result = await _syncWithRetry(
              () => googleSheets.syncPurchasesWithResult(batch),
        );

        if (result['success'] == true) {
          final purchaseIds = batch
              .map((p) => p['purchases_ID']?.toString())
              .where((id) => id != null)
              .cast<String>()
              .toList();

          await offlineStorage.bulkMarkPurchasesAsSynced(purchaseIds);
          totalProcessed += batch.length;
          logger?.info('✅ Batch complete: ${purchaseIds.length} purchases marked as synced');
        } else {
          logger?.error('❌ Failed to sync purchase batch: ${result['message']}');
        }

        await Future.delayed(const Duration(milliseconds: 150));
      }

      logger?.info('✅ All $totalProcessed purchases synced successfully');
    } catch (e) {
      logger?.error('Error syncing purchases', e.toString());
    }
  }

  Future<void> _syncPluMappings() async {
    try {
      final pendingMappings = await offlineStorage.getPendingPluMappings();
      if (pendingMappings.isEmpty) {
        logger?.info('🔗 No pending PLU mappings to upload.');
        return;
      }

      logger?.info('🔗 Uploading ${pendingMappings.length} pending PLU mappings in batches...');

      const batchSize = 50;
      int totalProcessed = 0;

      for (int i = 0; i < pendingMappings.length; i += batchSize) {
        final end = (i + batchSize < pendingMappings.length) ? i + batchSize : pendingMappings.length;
        final batch = pendingMappings.sublist(i, end);

        logger?.info('🔗 Processing PLU mappings batch ${i ~/ batchSize + 1} (${batch.length} items)');

        final jsonList = batch.map((m) => m.toJson()).toList();

        final result = await _syncWithRetry(() async {
          final success = await googleSheets.syncPluMappings(jsonList);
          return {'success': success};
        });

        if (result['success'] == true) {
          await offlineStorage.markPluMappingsAsSynced(batch);
          totalProcessed += batch.length;
          logger?.info('✅ Batch complete: ${batch.length} mappings backed up & marked as synced');
        } else {
          logger?.error('❌ Failed to sync PLU mappings batch');
        }

        await Future.delayed(const Duration(milliseconds: 150));
      }

      logger?.info('✅ All $totalProcessed pending PLU mappings backed up to cloud');
    } catch (e) {
      logger?.error('Error syncing PLU mappings', e.toString());
    }
  }

  Future<int> _syncDeletedInvoices() async {
    int deletedCount = 0;
    try {
      final deletedInvoices = await offlineStorage.getDeletedInvoices();
      if (deletedInvoices.isNotEmpty) {
        logger?.info('🗑️ Syncing ${deletedInvoices.length} deleted invoices...');

        for (final invoice in deletedInvoices) {
          final invoiceId = invoice['invoiceDetailsID']?.toString();
          if (invoiceId == null) continue;

          final success = await googleSheets.deleteInvoice(invoiceId);
          if (success) {
            await offlineStorage.hardDeleteInvoice(invoiceId);
            deletedCount++;
            logger?.info('  ✅ Deleted invoice $invoiceId');
          } else {
            logger?.error('  ❌ Failed to delete invoice $invoiceId');
          }

          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
    } catch (e) {
      logger?.error('Error syncing deleted invoices', e.toString());
    }
    return deletedCount;
  }

  Future<int> _syncDeletedPurchases() async {
    int deletedCount = 0;
    try {
      final deletedPurchases = await offlineStorage.getDeletedPurchases();
      if (deletedPurchases.isEmpty) return 0;

      logger?.info('🗑️ Syncing ${deletedPurchases.length} deleted purchases...');

      final purchaseIds = deletedPurchases
          .map((p) => p['purchases_ID']?.toString())
          .where((id) => id != null)
          .cast<String>()
          .toList();

      final batchSuccess = await googleSheets.deletePurchases(purchaseIds);

      if (batchSuccess) {
        for (final id in purchaseIds) {
          await offlineStorage.hardDeletePurchase(id);
        }
        deletedCount = purchaseIds.length;
        logger?.info('✅ Batch deleted ${purchaseIds.length} purchases');
      } else {
        logger?.info('⚠️ Batch delete not available, falling back to sequential...');
        int failCount = 0;

        for (final purchase in deletedPurchases) {
          final purchaseId = purchase['purchases_ID']?.toString();
          if (purchaseId == null) continue;

          final success = await googleSheets.deletePurchase(purchaseId);
          if (success) {
            await offlineStorage.hardDeletePurchase(purchaseId);
            deletedCount++;
          } else {
            failCount++;
          }

          await Future.delayed(const Duration(milliseconds: 300));
        }

        logger?.info('🗑️ Sequential delete complete: $deletedCount succeeded, $failCount failed');
      }
    } catch (e) {
      logger?.error('Error syncing deleted purchases', e.toString());
    }
    return deletedCount;
  }

  Future<void> _syncNewProducts() async {
    try {
      final newProducts = await offlineStorage.getPendingNewProducts();
      if (newProducts.isEmpty) return;

      logger?.info('🆕 Uploading ${newProducts.length} new products in batches...');

      const batchSize = 10;
      int totalProcessed = 0;

      for (int i = 0; i < newProducts.length; i += batchSize) {
        final end = (i + batchSize < newProducts.length) ? i + batchSize : newProducts.length;
        final batch = newProducts.sublist(i, end);

        logger?.info('🆕 Processing new products batch ${i ~/ batchSize + 1} (${batch.length} items)');

        final success = await googleSheets.syncNewProducts(batch);

        if (success) {
          final barcodes = batch.map((e) => e['Barcode'].toString()).toList();
          await offlineStorage.markNewProductsAsSynced(barcodes);
          totalProcessed += batch.length;
          logger?.info('✅ Batch complete: ${barcodes.length} products marked as synced');
        } else {
          logger?.error('❌ Failed to sync new products batch');
        }

        await Future.delayed(const Duration(milliseconds: 500));
      }

      logger?.info('✅ All $totalProcessed new products synced successfully');
    } catch (e) {
      logger?.error('Error syncing new products', e.toString());
    }
  }

  // 🔥 FIXED: Added _safeNotify() when pending.isEmpty
  Future<void> _syncStockCounts() async {
    // 🔥 FIX: Only get items that are truly pending (not synced)
    final allCounts = offlineStorage.pendingCounts;
    final pending = allCounts.where((c) =>
    c['syncStatus'] == 'pending' || c['syncStatus'] == 'deleted'
    ).toList();

    if (pending.isEmpty) {
      _lastSyncTime = _formatDateTime(DateTime.now());
      logger?.info('✨ Sync Complete: Up to date');
      _safeNotify();
      return;
    }

    logger?.info('📊 Uploading ${pending.length} counts...');

    // 🔥 NEW: Push to Firestore first for real-time availability
    if (firestore != null) {
      final storeId = offlineStorage.currentStoreId;
      if (storeId != null) {
        try {
          // Use batch save for performance
          await firestore!.saveStockCountsBatch(storeId, pending);
          logger?.info('🔥 Real-time: Synced to Firestore (Batch)');
        } catch (e) {
          logger?.error('🔥 Real-time: Firestore batch sync failed', e);
        }
      }
    }

    final success = await googleSheets.syncStockCounts(pending);

    if (success) {
      final ids = pending.where((c) => c['id'] != null).map((c) => c['id'].toString()).toList();
      await offlineStorage.markMultipleAsSynced(ids);
      _lastSyncTime = _formatDateTime(DateTime.now());
      _lastSyncCount = pending.length;
      logger?.info('✅ Counts synced successfully');
      _safeNotify();
    }
  }

  // ============================================================================
  // 🔥 ENHANCED SYNC WITH CHUNKING AND PROGRESS
  // ============================================================================

  Future<SyncResult> syncAllWithChunking({
    Function(int processed, int total)? onProgress,
    Function(String message)? onStatus,
  }) async {
    if (_isDisposed) {
      logger?.error('SyncService: syncAllWithChunking() called after disposal');
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: 'Service disposed',
        success: false,
        duplicates: const [],
      );
    }

    if (_isSyncing) {
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: 'Busy',
        success: false,
        duplicates: const [],
      );
    }

    _isSyncing = true;
    _lastError = null;
    _safeNotify();

    logger?.info('🚀 Sync with chunking started...');
    onStatus?.call('Starting sync...');

    final allDuplicates = <Map<String, dynamic>>[];
    int totalSynced = 0;
    int totalDeleted = 0;
    bool allSuccessful = true;

    // Track detailed counts
    int invoicesSynced = 0;
    int purchasesSynced = 0;
    int pluMappingsSynced = 0;
    int stockCountsSynced = 0;
    int locationsSynced = 0;
    int productsSynced = 0;

    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) {
        logger?.info('Sync Aborted: No Internet');
        return SyncResult(
          hasInternet: false,
          syncedCount: 0,
          message: 'No internet',
          success: false,
          duplicates: const [],
        );
      }

      // 1. Sync locations
      final locations = await offlineStorage.getPendingLocations();
      if (locations.isNotEmpty) {
        onStatus?.call('Syncing ${locations.length} locations...');
        final result = await googleSheets.syncNewLocationsWithChunking(
          locations,
          onProgress: (processed, total) {
            onProgress?.call(processed, total);
          },
        );
        if (result['success'] == true) {
          final ids = locations.map((e) => e['locationID'].toString()).toList();
          await offlineStorage.markLocationsAsSynced(ids);
          locationsSynced = locations.length;
          totalSynced += locations.length;
          final deleted = (result['deleted'] ?? 0) as int;
          totalDeleted += deleted;
          logger?.info('📍 Synced ${locations.length} locations${deleted > 0 ? " ($deleted deleted)" : ""}');
        } else {
          allSuccessful = false;
          logger?.error('❌ Location sync failed: ${result['message']}');
        }
      }

      // 2. Sync invoices with chunking
      final pendingInvoices = await offlineStorage.getPendingInvoiceDetails();
      if (pendingInvoices.isNotEmpty) {
        onStatus?.call('Syncing ${pendingInvoices.length} invoices...');

        final syncedInvoices = pendingInvoices.map((invoice) {
          final modified = Map<String, dynamic>.from(invoice);
          modified['syncStatus'] = 'synced';
          return modified;
        }).toList();

        final result = await googleSheets.syncInvoiceDetailsWithChunking(
          syncedInvoices,
          onProgress: (processed, total) {
            onProgress?.call(processed, total);
          },
        );

        if (result['success'] == true) {
          final invoiceIds = pendingInvoices
              .map((inv) => inv['invoiceDetailsID']?.toString())
              .where((id) => id != null)
              .cast<String>()
              .toList();
          await offlineStorage.bulkMarkInvoicesAsSynced(invoiceIds);
          invoicesSynced = pendingInvoices.length;
          totalSynced += pendingInvoices.length;
          final deleted = (result['deleted'] ?? 0) as int;
          totalDeleted += deleted;
          if (result['duplicates'] != null) {
            allDuplicates.addAll(List<Map<String, dynamic>>.from(result['duplicates']));
          }
          logger?.info('📄 Synced ${pendingInvoices.length} invoices${deleted > 0 ? " ($deleted deleted)" : ""}');
        } else {
          allSuccessful = false;
          logger?.error('❌ Invoice sync failed: ${result['message']}');
        }
      }

      // 3. Sync purchases with chunking
      final pendingPurchases = await offlineStorage.getPendingPurchases();
      if (pendingPurchases.isNotEmpty) {
        onStatus?.call('Syncing ${pendingPurchases.length} purchases...');
        final result = await googleSheets.syncPurchasesWithChunking(
          pendingPurchases,
          onProgress: (processed, total) {
            onProgress?.call(processed, total);
          },
        );

        if (result['success'] == true) {
          final purchaseIds = pendingPurchases
              .map((p) => p['purchases_ID']?.toString())
              .where((id) => id != null)
              .cast<String>()
              .toList();
          await offlineStorage.bulkMarkPurchasesAsSynced(purchaseIds);
          purchasesSynced = pendingPurchases.length;
          totalSynced += pendingPurchases.length;
          final deleted = (result['deleted'] ?? 0) as int;
          totalDeleted += deleted;
          logger?.info('📦 Synced ${pendingPurchases.length} purchases${deleted > 0 ? " ($deleted deleted)" : ""}');
        } else {
          allSuccessful = false;
          logger?.error('❌ Purchase sync failed: ${result['message']}');
        }
      }

      // 4. Sync PLU mappings with chunking
      final pendingMappings = await offlineStorage.getPendingPluMappings();
      if (pendingMappings.isNotEmpty) {
        onStatus?.call('Syncing ${pendingMappings.length} PLU mappings...');
        final jsonList = pendingMappings.map((m) => m.toJson()).toList();
        final result = await googleSheets.syncPluMappingsWithChunking(
          jsonList,
          onProgress: (processed, total) {
            onProgress?.call(processed, total);
          },
        );

        if (result['success'] == true) {
          await offlineStorage.markPluMappingsAsSynced(pendingMappings);
          pluMappingsSynced = pendingMappings.length;
          totalSynced += pendingMappings.length;
          final deleted = (result['deleted'] ?? 0) as int;
          totalDeleted += deleted;
          logger?.info('🔗 Synced ${pendingMappings.length} PLU mappings${deleted > 0 ? " ($deleted deleted)" : ""}');
        } else {
          allSuccessful = false;
          logger?.error('❌ PLU mapping sync failed: ${result['message']}');
        }
      }

      // 5. Sync deleted items
      totalDeleted += await _syncDeletedInvoices();
      totalDeleted += await _syncDeletedPurchases();

      // 6. Sync new products
      final newProducts = await offlineStorage.getPendingNewProducts();
      if (newProducts.isNotEmpty) {
        productsSynced = newProducts.length;
        await _syncNewProducts();
      }

      // 7. Sync stock counts - 🔥 FIX: Only sync truly pending items
      final allCounts = offlineStorage.pendingCounts;
      final pendingCounts = allCounts.where((c) =>
      c['syncStatus'] == 'pending' || c['syncStatus'] == 'deleted'
      ).toList();

      if (pendingCounts.isNotEmpty) {
        onStatus?.call('Syncing ${pendingCounts.length} stock counts...');

        // 🔥 NEW: Push to Firestore first for real-time availability using batch
        if (firestore != null) {
          final storeId = offlineStorage.currentStoreId;
          if (storeId != null) {
            try {
              await firestore!.saveStockCountsBatch(storeId, pendingCounts);
              logger?.info('🔥 Real-time: Synced to Firestore (Batch)');
            } catch (e) {
              logger?.error('🔥 Real-time: Firestore sync failed', e);
            }
          }
        }

        final result = await googleSheets.syncStockCountsWithChunking(
          pendingCounts,
          onProgress: (processed, total) {
            onProgress?.call(processed, total);
          },
        );

        if (result['success'] == true) {
          final ids = pendingCounts
              .where((c) => c['id'] != null)
              .map((c) => c['id'].toString())
              .toList();
          await offlineStorage.markMultipleAsSynced(ids);
          stockCountsSynced = pendingCounts.length;
          totalSynced += pendingCounts.length;
          final deleted = (result['deleted'] ?? 0) as int;
          totalDeleted += deleted;
          logger?.info('📊 Synced ${pendingCounts.length} stock counts${deleted > 0 ? " ($deleted deleted)" : ""}');
        } else {
          allSuccessful = false;
          logger?.error('❌ Stock count sync failed: ${result['message']}');
        }
      }

      _lastSyncTime = _formatDateTime(DateTime.now());
      _lastSyncCount = totalSynced;
      _safeNotify();

      // Build detailed message
      final parts = <String>[];
      if (invoicesSynced > 0) parts.add('$invoicesSynced Invoice${invoicesSynced > 1 ? 's' : ''}');
      if (purchasesSynced > 0) parts.add('$purchasesSynced Purchase${purchasesSynced > 1 ? 's' : ''}');
      if (pluMappingsSynced > 0) parts.add('$pluMappingsSynced PLU Mapping${pluMappingsSynced > 1 ? 's' : ''}');
      if (stockCountsSynced > 0) parts.add('$stockCountsSynced Stock Count${stockCountsSynced > 1 ? 's' : ''}');
      if (locationsSynced > 0) parts.add('$locationsSynced Location${locationsSynced > 1 ? 's' : ''}');
      if (productsSynced > 0) parts.add('$productsSynced Product${productsSynced > 1 ? 's' : ''}');

      final dupMsg = allDuplicates.isNotEmpty ? ' (${allDuplicates.length} duplicates found)' : '';
      final detailMsg = parts.isNotEmpty ? 'Synced: ${parts.join(", ")}$dupMsg' : 'No items to sync';

      final result = SyncResult(
        hasInternet: true,
        syncedCount: totalSynced,
        message: detailMsg,
        success: allSuccessful,
        duplicates: allDuplicates,
        invoicesSynced: invoicesSynced,
        purchasesSynced: purchasesSynced,
        pluMappingsSynced: pluMappingsSynced,
        stockCountsSynced: stockCountsSynced,
        locationsSynced: locationsSynced,
        productsSynced: productsSynced,
        totalDeleted: totalDeleted,
      );

      final finalMessage = allSuccessful
          ? result.detailedMessage
          : 'Sync completed with errors: ${result.detailedMessage}';

      logger?.info('✨ $finalMessage');
      onStatus?.call(finalMessage);

      return result;

    } catch (e) {
      _lastError = e.toString();
      logger?.error('🔥 Sync Exception', e);
      onStatus?.call('Error: $e');
      return SyncResult(
        hasInternet: true,
        syncedCount: totalSynced,
        message: 'Error: $e',
        success: false,
        duplicates: allDuplicates,
      );
    } finally {
      if (!_isDisposed) {
        _isSyncing = false;
        _safeNotify();
      }
    }
  }

  Future<SyncResult> syncPurchasesOnly({
    Function(int processed, int total)? onProgress,
  }) async {
    if (_isDisposed || _isSyncing) {
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: _isDisposed ? 'Service disposed' : 'Sync in progress',
        success: false,
        duplicates: const [],
      );
    }

    _isSyncing = true;
    _lastError = null;
    _safeNotify();

    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) {
        return SyncResult(
          hasInternet: false,
          syncedCount: 0,
          message: 'No internet',
          success: false,
          duplicates: const [],
        );
      }

      final pendingPurchases = await offlineStorage.getPendingPurchases();
      if (pendingPurchases.isEmpty) {
        return SyncResult(
          hasInternet: true,
          syncedCount: 0,
          message: 'No pending purchases',
          success: true,
          duplicates: const [],
        );
      }

      final result = await googleSheets.syncPurchasesWithChunking(
        pendingPurchases,
        onProgress: onProgress,
      );

      if (result['success'] == true) {
        final purchaseIds = pendingPurchases
            .map((p) => p['purchases_ID']?.toString())
            .where((id) => id != null)
            .cast<String>()
            .toList();
        await offlineStorage.bulkMarkPurchasesAsSynced(purchaseIds);
      }

      return SyncResult(
        hasInternet: true,
        syncedCount: pendingPurchases.length,
        message: result['success']
            ? 'Synced ${pendingPurchases.length} purchases'
            : 'Sync failed: ${result['message']}',
        success: result['success'] == true,
        duplicates: const [],
      );

    } catch (e) {
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: 'Error: $e',
        success: false,
        duplicates: const [],
      );
    } finally {
      if (!_isDisposed) {
        _isSyncing = false;
        _safeNotify();
      }
    }
  }

  Future<Map<String, int>> getPendingCounts() async {
    try {
      final invoices = await offlineStorage.getPendingInvoiceDetails();
      final purchases = await offlineStorage.getPendingPurchases();
      final locations = await offlineStorage.getPendingLocations();
      final products = await offlineStorage.getPendingNewProducts();
      final mappings = await offlineStorage.getPendingPluMappings();
      final counts = offlineStorage.pendingCounts;

      return {
        'invoices': invoices.length,
        'purchases': purchases.length,
        'locations': locations.length,
        'products': products.length,
        'pluMappings': mappings.length,
        'stockCounts': counts.length,
        'total': invoices.length + purchases.length + locations.length +
            products.length + mappings.length + counts.length,
      };
    } catch (e) {
      logger?.error('Error getting pending counts', e);
      return {
        'invoices': 0,
        'purchases': 0,
        'locations': 0,
        'products': 0,
        'pluMappings': 0,
        'stockCounts': 0,
        'total': 0,
      };
    }
  }

  // ==================== HELPER METHODS - DOWNLOAD OPERATIONS ====================
  Future<List<Map<String, dynamic>>> downloadInvoices() async {
    try {
      final remoteInvoices = await googleSheets.fetchInvoices();

      final syncedInvoices = remoteInvoices.map((inv) {
        final map = Map<String, dynamic>.from(inv);
        map['syncStatus'] = 'synced';
        map['syncedAt'] = DateTime.now().toIso8601String();
        return map;
      }).toList();

      final invoiceIds = syncedInvoices
          .map((inv) => inv['invoiceDetailsID']?.toString())
          .where((id) => id != null)
          .cast<String>()
          .toList();

      await _markInvoicesAsSynced(invoiceIds);
      await offlineStorage.saveInvoices(syncedInvoices);

      return syncedInvoices;
    } catch (e) {
      logger?.error('Failed to download invoices', e);
      return [];
    }
  }

  Future<void> _markInvoicesAsSynced(List<String> invoiceIds) async {
    for (var id in invoiceIds) {
      await offlineStorage.updateInvoiceDetails({
        'invoiceDetailsID': id,
        'syncStatus': 'synced',
        'syncedAt': DateTime.now().toIso8601String(),
      });
    }
  }

  // ==================== HELPER METHODS - DATA FETCHING ====================
  Future<List<List<Map<String, dynamic>>>> _fetchAllMasterData() async {
    logger?.info('📥 Refreshing master data tables (Parallel Batches)...');

    // Group fetches into parallel batches to speed up download while avoiding GAS rate limits

    // Batch 1: Core metadata
    final results1 = await Future.wait([
      googleSheets.fetchInventory(),
      googleSheets.fetchLocations(),
      googleSheets.fetchAudits(),
    ]);
    await Future.delayed(const Duration(milliseconds: 250));

    // Batch 2: Transactional data
    final results2 = await Future.wait([
      googleSheets.fetchPurchases(),
      googleSheets.fetchStoreSalesData(),
      googleSheets.fetchItemSales(),
    ]);
    await Future.delayed(const Duration(milliseconds: 250));

    // Batch 3: Accounting data
    final results3 = await Future.wait([
      googleSheets.fetchComputedCosts(),
      googleSheets.fetchInvoices(),
      googleSheets.fetchItemsIssued(),
    ]);
    await Future.delayed(const Duration(milliseconds: 250));

    // Batch 4: Mappings and specific issues
    final results4 = await Future.wait([
      googleSheets.fetchStockIssues(),
      googleSheets.fetchItemsIssuedMap(),
      googleSheets.fetchPluMappings(),
    ]);

    final storeSales = results2[1];
    final filteredStoreSales = storeSales.where((item) {
      final date = item['Date'];
      if (date == null) return false;
      if (date is String && date.isEmpty) return false;
      if (date is String) {
        try {
          DateTime.parse(date);
          return true;
        } catch (e) {
          return false;
        }
      }
      return true;
    }).toList();

    return [
      results1[0], // inventory
      results1[1], // locations
      results1[2], // audits
      results2[0], // purchases
      filteredStoreSales, // storeSales
      results2[2], // itemSales
      results3[0], // costs
      results3[1], // invoices
      results3[2], // itemsIssued
      results4[0], // stockIssues
      results4[1], // itemsIssuedMap
      results4[2], // pluMappings
    ];
  }

  Future<void> _logFetchedDataCounts(List<List<Map<String, dynamic>>> results) async {
    // logger?.info('📊 Data Fetched:');
    // logger?.info('  - Inventory: ${results[0].length}');
    // logger?.info('  - Locations: ${results[1].length}');
    // logger?.info('  - Audits: ${results[2].length}');
    // logger?.info('  - Purchases: ${results[3].length}');
    // logger?.info('  - Store Sales: ${results[4].length}');
    // logger?.info('  - Item Sales: ${results[5].length}');
    // logger?.info('  - Costs: ${results[6].length}');
    // logger?.info('  - Invoices: ${results[7].length}');
    // logger?.info('  - Items Issued: ${results[8].length}');
    // logger?.info('  - Stock Issues: ${results[9].length}');
    // logger?.info('  - Items Issued Map: ${results[10].length}');
  }

  Future<void> _saveMasterCatalog(List<Map<String, dynamic>> masterCosts) async {
    if (masterCosts.isNotEmpty) {
      await offlineStorage.saveMasterCatalog(masterCosts);
    }
  }

  Future<void> _saveDownloadedInvoices(List<Map<String, dynamic>> invoices) async {
    if (invoices.isNotEmpty) {
      logger?.info('📄 Saving ${invoices.length} invoices as synced');

      for (var invoice in invoices) {
        final invoiceId = invoice['invoiceDetailsID']?.toString();
        if (invoiceId != null) {
          invoice['syncStatus'] = 'synced';
          invoice['syncedAt'] = DateTime.now().toIso8601String();

          await offlineStorage.updateInvoiceDetails({
            'invoiceDetailsID': invoiceId,
            'syncStatus': 'synced',
            'syncedAt': DateTime.now().toIso8601String(),
            ...invoice,
          });
        }
      }
    }
  }

  Future<void> _saveAllMasterDataToDatabase(List<List<Map<String, dynamic>>> results) async {
    final inventory = results[0];
    final locations = results[1];
    final audits = results[2];
    final purchases = results[3];
    final storeSalesData = results[4];
    final itemSalesMap = results[5];
    final masterCosts = results[6];
    final invoices = results[7];
    final itemsIssued = results[8];
    final stockIssues = results[9];
    final itemsIssuedMap = results[10];
    final pluMappings = results[11];

    await _saveMasterCatalog(masterCosts);

    final costMap = _buildCostMap(masterCosts);
    final updatedInventory = _mergeCostsIntoInventory(inventory, costMap);

    await offlineStorage.clearInventory();
    await offlineStorage.clearLocations();
    await offlineStorage.clearAudits();

    await offlineStorage.bulkSaveInventory(updatedInventory);
    await offlineStorage.bulkSaveLocations(locations);
    await offlineStorage.savePurchases(purchases);
    await offlineStorage.saveStoreSalesData(storeSalesData);
    await offlineStorage.saveItemSalesMap(itemSalesMap);
    await offlineStorage.saveItemsIssuedMap(itemsIssuedMap);
    await offlineStorage.saveServerPluMappings(pluMappings);

    for (final audit in audits) {
      await offlineStorage.saveAudit(audit);
    }

    if (invoices.isNotEmpty) {
      await offlineStorage.saveServerInvoices(invoices);
    }

    await offlineStorage.saveItemsIssued(itemsIssued);
    await offlineStorage.saveStockIssues(stockIssues);
  }

  // ==================== CORE BUSINESS LOGIC ====================
  Future<SyncResult> syncAll() async {
    if (_isDisposed) {
      logger?.error('SyncService: syncAll() called after disposal');
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: 'Service disposed',
        success: false,
        duplicates: const [],
      );
    }

    if (_isSyncing) {
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: 'Busy',
        success: false,
        duplicates: const [],
      );
    }

    _isSyncing = true;
    _lastError = null;
    _safeNotify();
    logger?.info('🚀 Sync Started...');

    final allDuplicates = <Map<String, dynamic>>[];
    int totalSynced = 0;

    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) {
        logger?.info('Sync Aborted: No Internet');
        return SyncResult(
          hasInternet: false,
          syncedCount: 0,
          message: 'No internet',
          success: false,
          duplicates: const [],
        );
      }

      await _syncNewLocations();

      final invoiceResult = await _syncInvoiceHeaders();
      if (invoiceResult['success'] == true && invoiceResult['duplicates'] != null) {
        allDuplicates.addAll(List<Map<String, dynamic>>.from(invoiceResult['duplicates']));
      }

      await _syncPurchases();
      await _syncPluMappings();
      await _syncDeletedInvoices();
      await _syncDeletedPurchases();
      await _syncNewProducts();
      await _syncStockCounts();

      // 🔥 FIX: Only count truly pending items
      final allCounts = offlineStorage.pendingCounts;
      final pending = allCounts.where((c) =>
      c['syncStatus'] == 'pending' || c['syncStatus'] == 'deleted'
      ).toList();

      // Always update last sync time on success
      _lastSyncTime = _formatDateTime(DateTime.now());
      _lastSyncCount = totalSynced;
      _safeNotify();

      if (pending.isEmpty) {
        logger?.info('✨ Sync Complete: Up to date');

        return SyncResult(
          hasInternet: true,
          syncedCount: totalSynced,
          message: allDuplicates.isEmpty
              ? 'Up to date'
              : 'Up to date (${allDuplicates.length} duplicates found)',
          success: true,
          duplicates: allDuplicates,
        );
      } else {
        logger?.info('⚠️ Sync Complete with ${pending.length} items still pending');
        return SyncResult(
          hasInternet: true,
          syncedCount: totalSynced,
          message: 'Sync completed, ${pending.length} items still pending',
          success: true,
          duplicates: allDuplicates,
        );
      }
    } catch (e) {
      if (!_isDisposed) {
        _lastError = e.toString();
        logger?.error('🔥 Sync Exception', e);
      }
      _safeNotify();
      return SyncResult(
        hasInternet: true,
        syncedCount: totalSynced,
        message: 'Error: $e',
        success: false,
        duplicates: allDuplicates,
      );
    } finally {
      if (!_isDisposed) {
        _isSyncing = false;
        _safeNotify();
        logger?.info('✅ Sync finished, _isSyncing: $_isSyncing');
      }
    }
  }

  Future<int> downloadExistingCounts() async {
    if (_isDisposed) return 0;
    if (_isSyncing) return 0;

    if (offlineStorage.pendingCounts.isNotEmpty) {
      const msg = 'Cannot download: You have unsynced changes. Please press "Sync Data" (Upload) first.';
      logger?.error(msg);
      throw Exception(msg);
    }

    _isSyncing = true;
    _safeNotify();
    try {
      final hasInternet = await checkConnectivity();
      if (!hasInternet) throw Exception('No internet connection');

      logger?.info('📥 Downloading clean list from server...');

      int? expectedTotal;
      final remoteCounts = await googleSheets.fetchStockCounts(
        onProgress: (received, total) {
          if (total != null) expectedTotal = total;
        },
      );

      // Defense in depth: even if fetchStockCounts ever returns a short
      // list without throwing, refuse to wipe local data with an
      // incomplete download.
      if (expectedTotal != null && remoteCounts.length < expectedTotal!) {
        final msg = 'Download incomplete: got ${remoteCounts.length} of '
            '$expectedTotal records from server. Local data left unchanged '
            '— please retry.';
        logger?.error(msg);
        throw Exception(msg);
      }

      await offlineStorage.overwriteLocalCounts(remoteCounts);

      return remoteCounts.length;
    } catch (e) {
      if (!_isDisposed) logger?.error('Download Failed', e);
      rethrow;
    } finally {
      if (!_isDisposed) {
        _isSyncing = false;
        _safeNotify();
      }
    }
  }

  Future<SyncResult> refreshMasterData() async {
    if (_isDisposed || _isSyncing) {
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: _isDisposed ? 'Service disposed' : 'Sync in progress',
        success: false,
        duplicates: const [],
      );
    }

    _isSyncing = true;
    _lastError = null;
    _safeNotify(); // 🔥 Notify UI that sync started

    try {
      if (!await checkConnectivity()) {
        return SyncResult(
          hasInternet: false,
          syncedCount: 0,
          message: 'No internet',
          success: false,
          duplicates: const [],
        );
      }

      final results = await _fetchAllMasterData();
      await _logFetchedDataCounts(results);

      final remoteInvoices = results[7];

      final syncedInvoices = remoteInvoices.map((invoice) {
        return {
          ...invoice,
          'syncStatus': 'synced',
        };
      }).toList();

      final existingInvoices = await offlineStorage.getAllInvoiceDetails();
      final duplicates = <Map<String, dynamic>>[];
      final uniqueInvoices = <Map<String, dynamic>>[];

      for (var invoice in syncedInvoices) {
        final invoiceId = invoice['invoiceDetailsID']?.toString();
        final isDuplicate = invoiceId != null &&
            existingInvoices.any((inv) => inv['invoiceDetailsID']?.toString() == invoiceId);
        if (isDuplicate) {
          duplicates.add(invoice);
        } else {
          uniqueInvoices.add(invoice);
        }
      }

      if (uniqueInvoices.isNotEmpty) {
        await _saveDownloadedInvoices(uniqueInvoices);
        // logger?.info('📄 Saved ${uniqueInvoices.length} unique invoices (${duplicates.length} duplicates skipped)');
      }

      await _saveAllMasterDataToDatabase(results);

      // logger?.info('🔍 Verifying saved data:');
      // final storeSalesCount = await offlineStorage.getStoreSalesDataCount();
      // logger?.info('  - StoreSalesData count: $storeSalesCount');

      await offlineStorage.debugSalesData();

      _inventoryLoaded = true;

      // 🔥 FIX: Update last sync time and notify UI
      _lastSyncTime = _formatDateTime(DateTime.now());
      _lastSyncCount = uniqueInvoices.length;
      _safeNotify();

      return SyncResult(
        hasInternet: true,
        syncedCount: uniqueInvoices.length,
        message: duplicates.isEmpty
            ? 'Refreshed: ${results[0].length} items, ${uniqueInvoices.length} invoices'
            : 'Refreshed: ${results[0].length} items, ${uniqueInvoices.length} invoices (${duplicates.length} duplicates)',
        success: true,
        duplicates: duplicates,
      );
    } catch (e) {
      _lastError = e.toString();
      logger?.error('❌ Master Refresh Failed', e);
      _safeNotify(); // 🔥 Notify UI of error state
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: 'Error: $e',
        success: false,
        duplicates: const [],
      );
    } finally {
      _isSyncing = false;
      _safeNotify(); // 🔥 Always notify when done
      logger?.info('✅ Refresh finished, _isSyncing: $_isSyncing');
    }
  }

  // ==================== PUBLIC API METHODS ====================
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
    return (stats['inventoryItems'] ?? 0) > 0;
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