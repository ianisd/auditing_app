import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'offline_storage.dart';
import 'google_sheets_service.dart';
import 'logger_service.dart';

// ==================== SYNC RESULT MODEL ====================
class SyncResult {
  final bool hasInternet;
  final int syncedCount;
  final String message;
  final bool success;
  final List<Map<String, dynamic>> duplicates; // 🔥 ADD THIS

  SyncResult({
    required this.hasInternet,
    required this.syncedCount,
    required this.message,
    this.success = false,
    this.duplicates = const [], // 🔥 ADD THIS
  });
}

// ==================== MAIN SYNC SERVICE ====================
class SyncService with ChangeNotifier {
  // ==================== DEPENDENCIES ====================
  final OfflineStorage offlineStorage;
  final GoogleSheetsService googleSheets;
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
    this.logger,
  }) : connectivity = Connectivity() {
    _initConnectivity();
  }

  void _initConnectivity() {
    _connectivitySubscription = connectivity.onConnectivityChanged.listen((results) {
      if (!_isDisposed) {
        _safeNotify();
      }
    });
  }

  // ==================== LIFECYCLE METHODS ====================
  // 🔴 Add disposal and cleanup helpers here
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

  // ==================== HELPER METHODS - UTILITIES ====================
  // 🔴 Add utility helpers here (formatting, type conversion, etc.)
  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')} ${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }

  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  // ==================== HELPER METHODS - CONNECTIVITY ====================
  // 🔴 Add connectivity helpers here
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
  // 🔴 Add data processing helpers here (mapping, merging, etc.)
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
      Map<String, double> costMap
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
  // 🔴 Add individual sync operation helpers here
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

        // Start with a small batch size to avoid timeout
        const batchSize = 10;
        int totalProcessed = 0;
        int totalNew = 0;
        int totalUpdated = 0;
        int totalDuplicates = 0;
        List<Map<String, dynamic>> allDuplicates = [];

        for (int i = 0; i < pendingInvoices.length; i += batchSize) {
          final end = (i + batchSize < pendingInvoices.length) ? i + batchSize : pendingInvoices.length;
          final batch = pendingInvoices.sublist(i, end);

          logger?.info('📄 Processing batch ${i ~/ batchSize + 1}/${(pendingInvoices.length / batchSize).ceil()} (${batch.length} invoices)');

          // 🔴 VERIFY INVOICE NUMBERS BEFORE SENDING
          for (var invoice in batch) {
            final invoiceId = invoice['invoiceDetailsID']?.toString() ?? 'unknown';
            final invoiceNumber = invoice['Invoice Number']?.toString() ?? '';

            if (invoiceNumber.isEmpty) {
              logger?.info('⚠️ WARNING: Invoice $invoiceId has NO invoice number!');
            } else {
              logger?.info('✅ Invoice $invoiceId has number: "$invoiceNumber"');
            }
          }

          final result = await googleSheets.syncInvoiceDetailsWithResult(batch);

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

            // Mark this batch's invoices as synced
            for (var invoice in batch) {
              final invoiceId = invoice['invoiceDetailsID']?.toString();
              if (invoiceId != null) {
                await offlineStorage.updateInvoiceDetails({
                  ...invoice,
                  'syncStatus': 'synced',
                  'syncedAt': DateTime.now().toIso8601String(),
                });
              }
            }

            // Small delay between batches to avoid rate limiting
            await Future.delayed(const Duration(milliseconds: 500));

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
      if (pendingPurchases.isNotEmpty) {
        logger?.info('📦 Uploading ${pendingPurchases.length} purchase items...');

        final success = await googleSheets.syncPurchases(pendingPurchases);

        if (success) {
          final purchaseIds = pendingPurchases
              .map((p) => p['purchases_ID']?.toString())
              .where((id) => id != null)
              .cast<String>()
              .toList();

          await offlineStorage.markPurchasesAsSynced(purchaseIds);
          logger?.info('✅ Purchase items synced successfully');
        } else {
          logger?.error('❌ Failed to sync purchase items');
        }
      }
    } catch (e) {
      logger?.error('Error syncing purchases', e.toString());
    }
  }

  Future<void> _syncPluMappings() async {
    try {
      final allMappings = await offlineStorage.getAllPluMappings();
      if (allMappings.isNotEmpty) {
        logger?.info('🔗 Uploading ${allMappings.length} PLU mappings...');
        final jsonList = allMappings.map((m) => m.toJson()).toList();
        final success = await googleSheets.syncPluMappings(jsonList);
        if (success) {
          logger?.info('✅ PLU mappings backed up to cloud');
        }
      }
    } catch (e) {
      logger?.error('Error syncing PLU mappings', e.toString());
    }
  }

  Future<void> _syncDeletedInvoices() async {
    try {
      final deletedInvoices = await offlineStorage.getDeletedInvoices();
      if (deletedInvoices.isNotEmpty) {
        logger?.info('🗑️ Syncing ${deletedInvoices.length} deleted invoices...');

        await Future.wait(deletedInvoices.map((invoice) async {
          final invoiceId = invoice['invoiceDetailsID']?.toString();
          if (invoiceId != null) {
            final success = await googleSheets.deleteInvoice(invoiceId);
            if (success) {
              await offlineStorage.hardDeleteInvoice(invoiceId);
              logger?.info('  ✅ Deleted invoice $invoiceId');
            } else {
              logger?.error('  ❌ Failed to delete invoice $invoiceId');
            }
          }
        }));
      }
    } catch (e) {
      logger?.error('Error syncing deleted invoices', e.toString());
    }
  }

  Future<void> _syncDeletedPurchases() async {
    try {
      final deletedPurchases = await offlineStorage.getDeletedPurchases();
      if (deletedPurchases.isNotEmpty) {
        logger?.info('🗑️ Syncing ${deletedPurchases.length} deleted purchases...');

        await Future.wait(deletedPurchases.map((purchase) async {
          final purchaseId = purchase['purchases_ID']?.toString();
          if (purchaseId != null) {
            final success = await googleSheets.deletePurchase(purchaseId);
            if (success) {
              await offlineStorage.hardDeletePurchase(purchaseId);
              logger?.info('  ✅ Deleted purchase $purchaseId');
            } else {
              logger?.error('  ❌ Failed to delete purchase $purchaseId');
            }
          }
        }));
      }
    } catch (e) {
      logger?.error('Error syncing deleted purchases', e.toString());
    }
  }

  Future<void> _syncNewProducts() async {
    final newProducts = await offlineStorage.getPendingNewProducts();
    if (newProducts.isNotEmpty) {
      logger?.info('🆕 Uploading ${newProducts.length} new products...');
      final success = await googleSheets.syncNewProducts(newProducts);
      if (success) {
        final barcodes = newProducts.map((e) => e['Barcode'].toString()).toList();
        await offlineStorage.markNewProductsAsSynced(barcodes);
      }
    }
  }

  Future<void> _syncStockCounts() async {
    final pending = offlineStorage.pendingCounts;
    if (pending.isEmpty) {
      _lastSyncTime = _formatDateTime(DateTime.now());
      logger?.info('✨ Sync Complete: Up to date');
      return;
    }

    logger?.info('📊 Uploading ${pending.length} counts...');
    final success = await googleSheets.syncStockCounts(pending);

    if (success) {
      final ids = pending.where((c) => c['id'] != null).map((c) => c['id'].toString()).toList();
      await offlineStorage.markMultipleAsSynced(ids);
      _lastSyncTime = _formatDateTime(DateTime.now());
      _lastSyncCount = pending.length;
      logger?.info('✅ Counts synced successfully');
    }
  }

  // ==================== HELPER METHODS - DOWNLOAD OPERATIONS ====================
  // 🔴 Add download operation helpers here
  Future<List<Map<String, dynamic>>> downloadInvoices() async {
    try {
      final remoteInvoices = await googleSheets.fetchInvoices();

      // Mark all downloaded invoices as synced
      final invoiceIds = remoteInvoices
          .map((inv) => inv['invoiceDetailsID']?.toString())
          .where((id) => id != null)
          .cast<String>()
          .toList();

      await _markInvoicesAsSynced(invoiceIds);

      // Save to local storage
      await offlineStorage.saveInvoices(remoteInvoices);

      return remoteInvoices;
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
  // 🔴 Add data fetching helpers here
// In sync_service.dart, modify _fetchAllMasterData:
  Future<List<List<Map<String, dynamic>>>> _fetchAllMasterData() async {
    logger?.info('📥 Fetching all master data with batched loading for large tables...');

    // Fetch small tables in parallel
    final futures = await Future.wait([
      googleSheets.fetchInventory(),           // 0
      googleSheets.fetchLocations(),           // 1
      googleSheets.fetchAudits(),              // 2
      googleSheets.fetchPurchases(),           // 3
      googleSheets.fetchItemSales(),           // 4
      googleSheets.fetchComputedCosts(),       // 5
      googleSheets.fetchInvoices(),            // 6
      googleSheets.fetchItemsIssued(),         // 7
      googleSheets.fetchStockIssues(),         // 8
      googleSheets.fetchItemsIssuedMap(),      // 9
      googleSheets.fetchPluMappings(),         // 10 🔴 DOWNLOAD CLOUD MAPPINGS
    ]);

    // Fetch large StoreSalesData separately with batching
    logger?.info('📦 Fetching StoreSalesData in batches (estimated 32,000 records)...');
    final storeSales = await googleSheets.fetchLargeTableInBatches(
      'StoreSalesData',
      batchSize: 5000,
      timeoutSeconds: 30,
    );

    // Combine results
    return [
      futures[0], // Inventory
      futures[1], // Locations
      futures[2], // Audits
      futures[3], // Purchases
      storeSales, // Store Sales (batched) - POSITION 4
      futures[4], // Item Sales - POSITION 5
      futures[5], // Costs - POSITION 6
      futures[6], // Invoices - POSITION 7
      futures[7], // Items Issued - POSITION 8
      futures[8], // Stock Issues - POSITION 9
      futures[9], // Items Issued Map - POSITION 10
      futures[10],// Plu Mappings - 11 🔴
    ];
  }

  Future<void> _logFetchedDataCounts(List<List<Map<String, dynamic>>> results) async {
    logger?.info('📊 Data Fetched:');
    logger?.info('  - Inventory: ${results[0].length}');
    logger?.info('  - Locations: ${results[1].length}');
    logger?.info('  - Audits: ${results[2].length}');
    logger?.info('  - Purchases: ${results[3].length}');
    logger?.info('  - Store Sales: ${results[4].length}');
    logger?.info('  - Item Sales: ${results[5].length}');
    logger?.info('  - Costs: ${results[6].length}');
    logger?.info('  - Invoices: ${results[7].length}');
    logger?.info('  - Items Issued: ${results[8].length}');
    logger?.info('  - Stock Issues: ${results[9].length}');
    logger?.info('  - Items Issued Map: ${results[10].length}');
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
          // 🔴 CRITICAL: Force syncStatus to 'synced'
          invoice['syncStatus'] = 'synced';  // This is correct
          invoice['syncedAt'] = DateTime.now().toIso8601String();

          await offlineStorage.updateInvoiceDetails({
            'invoiceDetailsID': invoiceId,
            'syncStatus': 'synced',
            'syncedAt': DateTime.now().toIso8601String(),
            ...invoice, // Include all invoice data
          });
        }
      }
    }
  }

  // FIXED: Using the helper methods instead of inline code
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
    final pluMappings = results[11]; // 🔴 GET MAPPINGS



    // Save master costs first
    await _saveMasterCatalog(masterCosts);

    // FIXED: Use _buildCostMap and _mergeCostsIntoInventory helpers
    final costMap = _buildCostMap(masterCosts);
    final updatedInventory = _mergeCostsIntoInventory(inventory, costMap);

    // Clear existing data
    await offlineStorage.clearInventory();
    await offlineStorage.clearLocations();
    await offlineStorage.clearAudits();

    // Save all data
    await offlineStorage.bulkSaveInventory(updatedInventory);
    await offlineStorage.bulkSaveLocations(locations);
    await offlineStorage.savePurchases(purchases);
    await offlineStorage.saveStoreSalesData(storeSalesData);  // ✅ FIXED: Save StoreSalesData
    await offlineStorage.saveItemSalesMap(itemSalesMap);       // ✅ FIXED: Save ItemSalesMap correctly
    await offlineStorage.saveItemsIssuedMap(itemsIssuedMap);
    await offlineStorage.saveServerPluMappings(pluMappings); // 🔴 SAVE TO HIVE

    for (final audit in audits) {
      await offlineStorage.saveAudit(audit);
    }
    // Save invoices
    if (invoices.isNotEmpty) {
      await offlineStorage.saveServerInvoices(invoices);
    }

    //SaveItemsIssued
    await offlineStorage.saveItemsIssued(itemsIssued);
    await offlineStorage.saveStockIssues(stockIssues);

  }

  // ==================== CORE BUSINESS LOGIC ====================
  // --- SYNC ALL (UPLOAD) ---
  // --- SYNC ALL (UPLOAD) ---
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

    // 🔥 NEW: Track duplicates across all operations
    final allDuplicates = <Map<String, dynamic>>[];

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

      // Execute all sync operations and collect duplicates
      await _syncNewLocations();

      // 🔥 Capture invoice duplicates
      final invoiceResult = await _syncInvoiceHeaders();
      if (invoiceResult['success'] == true && invoiceResult['duplicates'] != null) {
        allDuplicates.addAll(List<Map<String, dynamic>>.from(invoiceResult['duplicates']));
      }

      await _syncPurchases();
      await _syncPluMappings(); // 🔴 BACKUP LOCAL MAPPINGS TO CLOUD
      await _syncDeletedInvoices();
      await _syncDeletedPurchases();
      await _syncNewProducts();
      await _syncStockCounts();

      // Check if any pending counts remain
      final pending = offlineStorage.pendingCounts;
      if (pending.isEmpty) {
        _lastSyncTime = _formatDateTime(DateTime.now());
        _safeNotify();
        logger?.info('✨ Sync Complete: Up to date');

        // 🔥 Return with duplicates if any
        return SyncResult(
          hasInternet: true,
          syncedCount: 0,
          message: allDuplicates.isEmpty
              ? 'Up to date'
              : 'Up to date (${allDuplicates.length} duplicates found)',
          success: true,
          duplicates: allDuplicates,
        );
      } else {
        return SyncResult(
          hasInternet: true,
          syncedCount: 0,
          message: 'Sync failed',
          success: false,
          duplicates: allDuplicates,
        );
      }
    } catch (e) {
      if (!_isDisposed) {
        _lastError = e.toString();
        logger?.error('🔥 Sync Exception', e);
      }
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
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

  // --- DOWNLOAD (STRICT SAFEGUARD) ---
  Future<int> downloadExistingCounts() async {
    if (_isDisposed) return 0;
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
      if (!hasInternet) throw Exception('No internet connection');

      logger?.info('📥 Downloading clean list from server...');
      final remoteCounts = await googleSheets.fetchStockCounts();

      // Wipe & Replace (Safe now because we checked for pending items above)
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

  // --- REFRESH MASTER DATA ---
  // --- REFRESH MASTER DATA ---
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

      // Fetch ALL data in parallel
      final results = await _fetchAllMasterData();

      // Log what we received
      await _logFetchedDataCounts(results);

      final remoteInvoices = results[7];

      // 🔴 FIX: Mark them as synced before any processing
      final syncedInvoices = remoteInvoices.map((invoice) {
        return {
          ...invoice,
          'syncStatus': 'synced',
        };
      }).toList();

      // 🔥 Detect duplicates before saving
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

      // Save downloaded invoices and mark as synced
      if (uniqueInvoices.isNotEmpty) {
        await _saveDownloadedInvoices(uniqueInvoices);
        logger?.info('📄 Saved ${uniqueInvoices.length} unique invoices (${duplicates.length} duplicates skipped)');
      }

      // Save all master data to database
      await _saveAllMasterDataToDatabase(results);

      // 🔥 ADD DEBUG HERE - Check what was saved
      logger?.info('🔍 Verifying saved data:');
      final storeSalesCount = await offlineStorage.getStoreSalesDataCount();
      logger?.info('  - StoreSalesData count: $storeSalesCount');

      // Call the debug method if you want more details
      await offlineStorage.debugSalesData();

      _inventoryLoaded = true;

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
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        message: 'Error: $e',
        success: false,
        duplicates: const [],
      );
    } finally {
      _isSyncing = false;
      _safeNotify();
    }
  }

  // ==================== PUBLIC API METHODS ====================
  // 🔴 Add public-facing methods here
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