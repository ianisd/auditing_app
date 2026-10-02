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
    if (invoicesSynced > 0)
      parts.add('$invoicesSynced Invoice${invoicesSynced > 1 ? 's' : ''}');
    if (purchasesSynced > 0)
      parts.add('$purchasesSynced Purchase${purchasesSynced > 1 ? 's' : ''}');
    if (pluMappingsSynced > 0)
      parts.add(
        '$pluMappingsSynced PLU Mapping${pluMappingsSynced > 1 ? 's' : ''}',
      );
    if (stockCountsSynced > 0)
      parts.add(
        '$stockCountsSynced Stock Count${stockCountsSynced > 1 ? 's' : ''}',
      );
    if (locationsSynced > 0)
      parts.add('$locationsSynced Location${locationsSynced > 1 ? 's' : ''}');
    if (productsSynced > 0)
      parts.add('$productsSynced Product${productsSynced > 1 ? 's' : ''}');

    String msg = parts.isEmpty ? message : 'Synced: ${parts.join(', ')}';
    if (totalDeleted > 0) {
      msg += ' ($totalDeleted deleted)';
    }
    return msg;
  }
}

// ==================== MAIN SYNC SERVICE ====================
class SyncService with ChangeNotifier {
  // ==================== NEW ====================
  String? _postStoreId;
  int? _postStoreGeneration;
  String? _postUserId;
  int _postAuthEpoch = 0;
  int _authEpoch = 0;
  String? _observedUserId;
  bool _authStreamFailed = false;

  void _beginAuthenticatedOperation() {
    _postUserId = firestore?.currentUserId;
    _postAuthEpoch = _authEpoch;
    _checkPostSession();
  }

  void _checkPostSession() {
    if (_isDisposed || _postStoreId == null || _postStoreGeneration == null) {
      throw StateError('POST service session is unavailable');
    }
    if (firestore != null &&
        (_authStreamFailed ||
            _postUserId == null ||
            firestore!.currentUserId != _postUserId ||
            _postAuthEpoch != _authEpoch)) {
      throw StateError(
        'Sign-in session changed. Sign in and retry; unconfirmed records remain pending.',
      );
    }
    offlineStorage.checkRefreshStore(_postStoreId!, _postStoreGeneration!);
  }

  Future<Map<String, dynamic>> _syncVersionedRows(
    String table,
    List<Map<String, dynamic>> records, {
    bool deleting = false,
    Function(int processed, int total)? onProgress,
  }) async {
    _checkPostSession();
    final problems = offlineStorage.getPostRecoveryIssues();
    if (problems.isNotEmpty) throw StateError(problems.join('\n'));
    final size = deleting
        ? (table == 'InvoiceDetails' ? 1 : 100)
        : (table == 'InvoiceDetails' ? 25 : 50);
    final entire = offlineStorage.capturePostSnapshot(
      table,
      records,
      deleting: deleting,
    );
    final rows = entire.rows.values.toList();
    var markedCount = 0;
    var allConfirmed = true;
    final duplicates = <Map<String, dynamic>>[];
    for (var offset = 0; offset < rows.length; offset += size) {
      _checkPostSession();
      final end = offset + size < rows.length ? offset + size : rows.length;
      final batch = rows.sublist(offset, end);
      // Recapture from immutable submitted rows, not a newly edited local row.
      final snapshot = offlineStorage.capturePostSnapshot(
        table,
        batch,
        deleting: deleting,
      );
      Map<String, dynamic> result;
      if (deleting) {
        final ok = table == 'InvoiceDetails'
            ? await googleSheets.deleteInvoice(snapshot.rows.keys.single)
            : await googleSheets.deletePurchases(snapshot.rows.keys.toList());
        result = {'success': ok};
      } else {
        // Mapping functions may normalize fields. Never give them immutable maps
        // or reuse their output as the local acknowledgement snapshot.
        final outgoing = batch
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        result = table == 'InvoiceDetails'
            ? await googleSheets.syncInvoiceDetailsWithResult(outgoing)
            : await googleSheets.syncPurchasesWithResult(outgoing);
      }
      _checkPostSession();
      if (result['success'] != true) {
        return {
          'success': false,
          'processed': markedCount,
          'duplicates': duplicates,
          'message':
              result['message'] ??
              'Unconfirmed $table write; records remain pending.',
        };
      }
      final confirmed = await offlineStorage.acknowledgePostSnapshot(
        snapshot,
        snapshot.rows.keys,
      );
      markedCount += confirmed.length;
      if (confirmed.length != batch.length) allConfirmed = false;
      final values = result['duplicates'];
      if (values is List)
        duplicates.addAll(
          values.whereType<Map>().map((r) => Map<String, dynamic>.from(r)),
        );
      onProgress?.call(markedCount, rows.length);
    }
    return {
      'success': allConfirmed,
      'processed': markedCount,
      'duplicates': duplicates,
      'message': allConfirmed
          ? 'Confirmed $markedCount $table records.'
          : 'Newer local edits remain pending in $table.',
    };
  }

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
  StreamSubscription<List<Map<String, dynamic>>>? _stockSubscription;
  StreamSubscription? _authSubscription;
  int _listenerEpoch = 0;
  Future<void> _listenerWork = Future<void>.value();
  Future<void> _remoteWork = Future<void>.value();

  List<Map<String, dynamic>>? _cachedSuppliers;
  DateTime? _suppliersCacheTime;
  static const Duration _cacheDuration = Duration(minutes: 5);

  // 🔥 NEW: Track failed chunks for health monitoring
  int _failedChunks = 0;
  int _totalChunks = 0;
  List<String> _recentErrors = [];
  static const int _maxErrorsToStore = 50;

  // 🔥 NEW: Track sync attempts for success rate calculation
  int _syncAttempts = 0;
  int _syncSuccesses = 0;

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
    Connectivity? connectivity,
  }) : connectivity = connectivity ?? Connectivity() {
    _postStoreId = offlineStorage.currentStoreId;
    _postStoreGeneration = offlineStorage.refreshStoreGeneration;
    _observedUserId = firestore?.currentUserId;
    _initConnectivity();
    _initFirestoreListeners();
  }

  void _initFirestoreListeners() {
    if (firestore == null) return;
    // Token changes also allow a failed listener to recover after credentials
    // refresh. A token refresh for the same user does not invalidate an upload.
    _authSubscription = firestore!.idTokenChanges.listen(
      (user) {
        if (_isDisposed) return;
        if (_observedUserId != user?.uid) {
          _authEpoch++;
          _observedUserId = user?.uid;
        }
        _authStreamFailed = false;
        _queueStockListener(user?.uid);
      },
      onError: (Object error, StackTrace stack) {
        if (_isDisposed) return;
        _authStreamFailed = true;
        _authEpoch++;
        _queueStockListener(null);
        _reportListenerError(
          'Firebase authentication stream failed',
          error,
          stack,
        );
      },
    );
  }

  void _reportListenerError(String message, Object error, StackTrace stack) {
    if (_isDisposed) return;
    _lastError = '$message: $error';
    _recordError(_lastError!);
    logger?.error(message, '$error\n$stack');
    _safeNotify();
  }

  Future<void> _cancelSubscription(StreamSubscription? subscription) async {
    try {
      await subscription?.cancel();
    } catch (error, stack) {
      logger?.error('Stream cancellation failed', '$error\n$stack');
    }
  }

  void _queueStockListener(String? userId) {
    // Invalidate queued callbacks immediately, before asynchronous cancellation.
    final epoch = ++_listenerEpoch;
    _listenerWork = _listenerWork
        .then((_) async {
          final previous = _stockSubscription;
          // A failed cancellation must not create a second native listener. Keep
          // the reference so a later auth event/disposal can attempt cleanup again.
          await previous?.cancel();
          _stockSubscription = null;
          if (_isDisposed ||
              epoch != _listenerEpoch ||
              userId == null ||
              firestore!.currentUserId != userId ||
              !offlineStorage.isReady)
            return;
          final storeId = offlineStorage.firestoreKey;
          if (storeId == null) return;
          final generation = offlineStorage.refreshStoreGeneration;
          bool valid() =>
              !_isDisposed &&
              !_authStreamFailed &&
              epoch == _listenerEpoch &&
              firestore!.currentUserId == userId &&
              offlineStorage.isReady &&
              offlineStorage.firestoreKey == storeId &&
              offlineStorage.refreshStoreGeneration == generation;
          _stockSubscription = firestore!
              .watchStockCounts(storeId)
              .listen(
                (remoteCounts) {
                  _remoteWork = _remoteWork
                      .then((_) async {
                        if (!valid() || _isSyncing) return;
                        await offlineStorage.saveRemoteStockCounts(
                          remoteCounts,
                          isCurrent: valid,
                        );
                      })
                      .catchError((Object error, StackTrace stack) {
                        if (valid())
                          _reportListenerError(
                            'Remote stock storage failed',
                            error,
                            stack,
                          );
                      });
                },
                onError: (Object error, StackTrace stack) {
                  if (valid()) {
                    _reportListenerError(
                      'Firestore stock listener failed',
                      error,
                      stack,
                    );
                    // Do not retry permission/index errors in a loop. The next token
                    // event or store activation can establish a new listener.
                    _queueStockListener(null);
                  }
                },
              );
        })
        .catchError((Object error, StackTrace stack) {
          _reportListenerError(
            'Firestore listener lifecycle failed',
            error,
            stack,
          );
        });
  }

  void _initConnectivity() {
    _connectivitySubscription = connectivity.onConnectivityChanged.listen(
      (results) {
        if (!_isDisposed) _safeNotify();
      },
      onError: (Object error, StackTrace stack) {
        _reportListenerError('Connectivity stream failed', error, stack);
      },
    );
  }

  // ==================== LIFECYCLE METHODS ====================
  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _listenerEpoch++;
    _authEpoch++;
    unawaited(_cancelSubscription(_authSubscription));
    unawaited(_cancelSubscription(_connectivitySubscription));
    unawaited(_cancelSubscription(_stockSubscription));
    _stockSubscription = null;
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
    // Compatibility name/argument retained. GoogleSheetsService owns retries.
    // Never abandon this Future and invoke the same logical write concurrently.
    return await syncFn();
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
      final cost = _safeDouble(
        c['avgCost'] ?? c['avgcost'] ?? c['Cost'] ?? c['Unit Cost'],
      );

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
      final rawName =
          item['Inventory Product Name'] ??
          item['Product Name'] ??
          item['productName'];

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

    if (updatedInventory.isNotEmpty &&
        costsUpdated == 0 &&
        costMap.isNotEmpty) {
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
        final ids = newLocations
            .map((e) => e['locationID'].toString())
            .toList();
        await offlineStorage.markLocationsAsSynced(ids);
      }
    }
  }

  Future<Map<String, dynamic>> _syncInvoiceHeaders({
    Function(int, int)? onProgress,
  }) async {
    _checkPostSession();
    final rows = await offlineStorage.getPendingInvoiceDetails();
    _checkPostSession();
    return _syncVersionedRows('InvoiceDetails', rows, onProgress: onProgress);
  }

  Future<Map<String, dynamic>> _syncPurchases({
    Function(int, int)? onProgress,
  }) async {
    _checkPostSession();
    final rows = await offlineStorage.getPendingPurchases();
    _checkPostSession();
    return _syncVersionedRows('Purchases', rows, onProgress: onProgress);
  }

  Future<void> _syncPluMappings() async {
    try {
      final pendingMappings = await offlineStorage.getPendingPluMappings();
      if (pendingMappings.isEmpty) {
        logger?.info('🔗 No pending PLU mappings to upload.');
        return;
      }

      logger?.info(
        '🔗 Uploading ${pendingMappings.length} pending PLU mappings in batches...',
      );

      const batchSize = 50;
      int totalProcessed = 0;

      for (int i = 0; i < pendingMappings.length; i += batchSize) {
        final end = (i + batchSize < pendingMappings.length)
            ? i + batchSize
            : pendingMappings.length;
        final batch = pendingMappings.sublist(i, end);

        logger?.info(
          '🔗 Processing PLU mappings batch ${i ~/ batchSize + 1} (${batch.length} items)',
        );

        final jsonList = batch.map((m) => m.toJson()).toList();

        final result = await _syncWithRetry(() async {
          final success = await googleSheets.syncPluMappings(jsonList);
          return {'success': success};
        });

        if (result['success'] == true) {
          await offlineStorage.markPluMappingsAsSynced(batch);
          totalProcessed += batch.length;
          logger?.info(
            '✅ Batch complete: ${batch.length} mappings backed up & marked as synced',
          );
        } else {
          logger?.error('❌ Failed to sync PLU mappings batch');
        }

        await Future.delayed(const Duration(milliseconds: 150));
      }

      logger?.info(
        '✅ All $totalProcessed pending PLU mappings backed up to cloud',
      );
    } catch (e) {
      logger?.error('Error syncing PLU mappings', e.toString());
    }
  }

  Future<int> _syncDeletedInvoices() async {
    _checkPostSession();
    final rows = await offlineStorage.getDeletedInvoices();
    _checkPostSession();
    final result = await _syncVersionedRows(
      'InvoiceDetails',
      rows,
      deleting: true,
    );
    if (result['success'] != true)
      throw StateError(result['message'].toString());
    return (result['processed'] as num? ?? 0).toInt();
  }

  Future<int> _syncDeletedPurchases() async {
    _checkPostSession();
    final rows = await offlineStorage.getDeletedPurchases();
    _checkPostSession();
    final result = await _syncVersionedRows('Purchases', rows, deleting: true);
    if (result['success'] != true)
      throw StateError(result['message'].toString());
    return (result['processed'] as num? ?? 0).toInt();
  }

  Future<void> _syncNewProducts() async {
    try {
      _checkPostSession();
      final newProducts = await offlineStorage.getPendingNewProducts();
      if (newProducts.isEmpty) return;

      logger?.info(
        '🆕 Uploading ${newProducts.length} new products in batches...',
      );

      const batchSize = 10;
      int totalProcessed = 0;

      for (int i = 0; i < newProducts.length; i += batchSize) {
        final end = (i + batchSize < newProducts.length)
            ? i + batchSize
            : newProducts.length;
        final batch = newProducts.sublist(i, end);

        logger?.info(
          '🆕 Processing new products batch ${i ~/ batchSize + 1} (${batch.length} items)',
        );

        _checkPostSession();
        final success = await googleSheets.syncNewProducts(batch);
        _checkPostSession();

        if (success) {
          final barcodes = batch.map((e) => e['Barcode'].toString()).toList();
          await offlineStorage.markNewProductsAsSynced(barcodes);
          totalProcessed += batch.length;
          logger?.info(
            '✅ Batch complete: ${barcodes.length} products marked as synced',
          );
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

  /// 🔥 Builds a Firestore-safe copy of stock count records.
  /// Firestore doesn't understand `syncStatus`, so this translates
  /// syncStatus == 'deleted' into an explicit `deleted: true` flag
  /// without mutating the original local records.
  List<Map<String, dynamic>> _mapForFirestore(
    List<Map<String, dynamic>> counts,
  ) {
    return counts.map((c) {
      final item = Map<String, dynamic>.from(c);

      // Legacy StockCounts rows can contain an empty/whitespace-only field name.
      // Never pass invalid field names into the native Firestore SDK.
      final invalidKeys = item.keys.where((key) => key.trim().isEmpty).toList();

      if (invalidKeys.isNotEmpty) {
        final id =
            item['id'] ?? item['stock_id'] ?? item['stockId'] ?? 'unknown';

        for (final key in invalidKeys) {
          item.remove(key);
        }

        logger?.info(
          '🧹 Firestore stock sanitization: removed '
          '${invalidKeys.length} empty field name(s) from $id',
        );
      }

      item['deleted'] = (c['syncStatus'] == 'deleted');
      return item;
    }).toList();
  }

  Future<Map<String, dynamic>> _syncStockSnapshotV2({
    Function(int processed, int total)? onProgress,
  }) async {
    _checkPostSession();
    final storeAtStart = offlineStorage.currentStoreId;
    final firestoreAtStart = offlineStorage.firestoreKey;
    var pending = offlineStorage.pendingCounts
        .where(
          (c) => c['syncStatus'] == 'pending' || c['syncStatus'] == 'deleted',
        )
        .map((c) => Map<String, dynamic>.from(c))
        .toList();
    if (_isDisposed || storeAtStart == null) {
      return {
        'success': false,
        'syncedIds': <String>[],
        'message': 'No active stock sync session.',
      };
    }
    if (pending.isEmpty) {
      return {
        'success': true,
        'syncedIds': <String>[],
        'failedIds': <String>[],
        'count': 0,
        'updated': 0,
        'deleted': 0,
        'message': 'No pending stock counts.',
      };
    }
    final localSnapshot = offlineStorage.capturePostSnapshot(
      'StockCounts',
      pending,
    );
    pending = localSnapshot.rows.values
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    // Both destinations are required when Firestore is configured. A Firestore
    // failure must not be hidden by a later successful Sheets response.
    if (firestore != null) {
      try {
        if (firestoreAtStart == null || firestoreAtStart.isEmpty) {
          throw StateError('Firestore store key is missing.');
        }
        // Chunk here because the existing Firestore service creates one write batch.
        for (int offset = 0; offset < pending.length; offset += 200) {
          _checkPostSession();
          if (_isDisposed || offlineStorage.currentStoreId != storeAtStart) {
            throw StateError('Store changed during stock upload.');
          }
          final end = offset + 200 < pending.length
              ? offset + 200
              : pending.length;
          await firestore!.saveStockCountsBatch(
            firestoreAtStart,
            _mapForFirestore(pending.sublist(offset, end)),
          );
        }
      } catch (e) {
        logger?.error(
          'Stock Firestore upload failed; records remain pending.',
          e,
        );
        return {
          'success': false,
          'syncedIds': <String>[],
          'failedIds': pending
              .map((c) => (c['id'] ?? c['stock_id']).toString())
              .toList(),
          'message': 'Firestore upload failed: $e',
        };
      }
    }
    if (_isDisposed || offlineStorage.currentStoreId != storeAtStart) {
      return {
        'success': false,
        'syncedIds': <String>[],
        'message': 'Store changed during stock upload.',
      };
    }
    _checkPostSession();
    final result = await googleSheets.syncStockCountsWithChunking(
      pending,
      onProgress: onProgress,
    );
    final confirmed = (result['syncedIds'] as List<dynamic>? ?? const [])
        .map((id) => id.toString())
        .toList();
    if (_isDisposed || offlineStorage.currentStoreId != storeAtStart) {
      return {
        ...result,
        'success': false,
        'syncedIds': <String>[],
        'message':
            'Upload completed for previous store; local acknowledgement deferred.',
      };
    }
    _checkPostSession();
    final marked = await offlineStorage.acknowledgePostSnapshot(
      localSnapshot,
      confirmed,
    );
    final needsRetry = pending
        .map((c) => (c['id'] ?? c['stock_id'] ?? c['stockId']).toString())
        .where((id) => !marked.contains(id))
        .toList();
    return {
      ...result,
      'success': result['success'] == true && needsRetry.isEmpty,
      'syncedIds': marked,
      'serverConfirmedIds': confirmed,
      'failedIds': needsRetry,
      'message': needsRetry.isEmpty
          ? result['message']
          : '${marked.length}/${pending.length} local records confirmed. Newer edits or unconfirmed records remain pending.',
    };
  }

  // 🔥 FIXED: Added _safeNotify() when pending.isEmpty
  Future<void> _syncStockCounts() async {
    final result = await _syncStockSnapshotV2();
    if (_isDisposed) return;
    if (result['success'] == true) {
      _lastSyncTime = _formatDateTime(DateTime.now());
      _lastSyncCount = (result['syncedIds'] as List? ?? const []).length;
      logger?.info(result['message'].toString());
    } else {
      logger?.error(result['message'].toString());
    }
    _safeNotify();
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
    _syncAttempts++;
    _failedChunks = 0;
    _totalChunks = 0;
    _safeNotify();

    logger?.info('🚀 Sync with chunking started... (Attempt #$_syncAttempts)');
    onStatus?.call('Starting sync...');

    final allDuplicates = <Map<String, dynamic>>[];
    int totalSynced = 0;
    int totalDeleted = 0;
    bool allSuccessful = true;

    int invoicesSynced = 0;
    int purchasesSynced = 0;
    int pluMappingsSynced = 0;
    int stockCountsSynced = 0;
    int locationsSynced = 0;
    int productsSynced = 0;

    try {
      _beginAuthenticatedOperation();
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

      _checkPostSession();
      final recoveryIssues = offlineStorage.getPostRecoveryIssues();
      if (recoveryIssues.isNotEmpty)
        throw StateError(recoveryIssues.join("\n"));
      // 1. Sync locations
      final locations = await offlineStorage.getPendingLocations();
      _checkPostSession();
      if (locations.isNotEmpty) {
        onStatus?.call('Syncing ${locations.length} locations...');
        _totalChunks += (locations.length / 50).ceil();

        final result = await googleSheets.syncNewLocationsWithChunking(
          locations,
          onProgress: (processed, total) {
            onProgress?.call(processed, total);
          },
        );

        if (result['success'] == true) {
          _checkPostSession();
          final ids = locations.map((e) => e['locationID'].toString()).toList();
          await offlineStorage.markLocationsAsSynced(ids);
          locationsSynced = locations.length;
          totalSynced += locations.length;
          logger?.info('📍 Synced ${locations.length} locations');
        } else {
          allSuccessful = false;
          _failedChunks++;
          _recordError('Location sync failed: ${result['message']}');
          logger?.error('❌ Location sync failed: ${result['message']}');
        }
      }

      // Invoice and purchase acknowledgements are tied to submitted versions.
      _checkPostSession();
      onStatus?.call('Syncing invoices...');
      final invoiceResult = await _syncInvoiceHeaders(onProgress: onProgress);
      invoicesSynced = (invoiceResult['processed'] as num? ?? 0).toInt();
      totalSynced += invoicesSynced;
      allDuplicates.addAll(
        List<Map<String, dynamic>>.from(
          invoiceResult['duplicates'] ?? const [],
        ),
      );
      if (invoiceResult['success'] != true) {
        allSuccessful = false;
        _recordError(invoiceResult['message'].toString());
      }
      // Do not submit dependent purchases if invoice writes were unconfirmed.
      if (invoiceResult['success'] == true) {
        onStatus?.call('Syncing purchases...');
        final purchaseResult = await _syncPurchases(onProgress: onProgress);
        purchasesSynced = (purchaseResult['processed'] as num? ?? 0).toInt();
        totalSynced += purchasesSynced;
        if (purchaseResult['success'] != true) {
          allSuccessful = false;
          _recordError(purchaseResult['message'].toString());
        }
      }

      // 4. PRIORITY: Sync stock counts before non-critical auxiliary work.
      // A PLU mapping or cleanup failure must not starve the core count upload.
      _checkPostSession();
      onStatus?.call('Syncing stock counts...');
      try {
        final stockResult = await _syncStockSnapshotV2(onProgress: onProgress);
        final stockIds =
            (stockResult['syncedIds'] as List<dynamic>? ?? const []);
        stockCountsSynced = stockIds.length;
        totalSynced += stockCountsSynced;
        totalDeleted += (stockResult['deleted'] as num? ?? 0).toInt();

        if (stockResult['success'] != true) {
          allSuccessful = false;
          _recordError(
            stockResult['message']?.toString() ?? 'Stock sync incomplete.',
          );
          logger?.error(
            '❌ Stock count sync incomplete: ${stockResult['message'] ?? 'Unknown error'}',
          );
        } else {
          logger?.info('📊 Synced $stockCountsSynced stock counts');
        }
      } catch (e) {
        allSuccessful = false;
        _recordError('Stock count sync failed: $e');
        logger?.error('❌ Stock count sync failed; records remain pending.', e);
      }

      // 5. Sync PLU mappings with chunking
      _checkPostSession();
      final pendingMappings = await offlineStorage.getPendingPluMappings();
      if (pendingMappings.isNotEmpty) {
        onStatus?.call('Syncing ${pendingMappings.length} PLU mappings...');
        _totalChunks += (pendingMappings.length / 50).ceil();

        _checkPostSession();
        final jsonList = pendingMappings.map((m) => m.toJson()).toList();
        final result = await googleSheets.syncPluMappingsWithChunking(
          jsonList,
          onProgress: (processed, total) {
            onProgress?.call(processed, total);
          },
        );

        if (result['success'] == true) {
          _checkPostSession();
          await offlineStorage.markPluMappingsAsSynced(pendingMappings);
          pluMappingsSynced = pendingMappings.length;
          totalSynced += pendingMappings.length;
          logger?.info('🔗 Synced ${pendingMappings.length} PLU mappings');
        } else {
          allSuccessful = false;
          _failedChunks++;
          _recordError('PLU mapping sync failed: ${result['message']}');
          logger?.error('❌ PLU mapping sync failed: ${result['message']}');
        }
      }

      _checkPostSession();
      // 6. Sync deleted items independently. Failed deletes remain pending
      // and must not abort unrelated sync categories.
      try {
        totalDeleted += await _syncDeletedInvoices();
      } catch (e) {
        allSuccessful = false;
        _recordError('Invoice deletion sync failed: $e');
        logger?.error(
          '❌ Invoice deletion sync failed; deletion remains pending.',
          e,
        );
      }

      try {
        totalDeleted += await _syncDeletedPurchases();
      } catch (e) {
        allSuccessful = false;
        _recordError('Purchase deletion sync failed: $e');
        logger?.error(
          '❌ Purchase deletion sync failed; deletion remains pending.',
          e,
        );
      }

      // 7. Sync new products
      final newProducts = await offlineStorage.getPendingNewProducts();
      if (newProducts.isNotEmpty) {
        productsSynced = newProducts.length;
        await _syncNewProducts();
      }

      _checkPostSession();
      final remaining =
          (await offlineStorage.getPendingInvoiceDetails()).length +
          (await offlineStorage.getPendingPurchases()).length +
          (await offlineStorage.getDeletedInvoices()).length +
          (await offlineStorage.getDeletedPurchases()).length;
      _checkPostSession();
      if (remaining > 0 || offlineStorage.getPostRecoveryIssues().isNotEmpty) {
        allSuccessful = false;
        _recordError(
          'Invoice/purchase work remains pending or requires recovery.',
        );
      }
      // 🔥 Record success
      if (allSuccessful) {
        _syncSuccesses++;
      }

      _lastSyncTime = _formatDateTime(DateTime.now());
      _lastSyncCount = totalSynced;
      _safeNotify();

      // Build detailed message with health stats
      final parts = <String>[];
      if (invoicesSynced > 0)
        parts.add('$invoicesSynced Invoice${invoicesSynced > 1 ? 's' : ''}');
      if (purchasesSynced > 0)
        parts.add('$purchasesSynced Purchase${purchasesSynced > 1 ? 's' : ''}');
      if (pluMappingsSynced > 0)
        parts.add(
          '$pluMappingsSynced PLU Mapping${pluMappingsSynced > 1 ? 's' : ''}',
        );
      if (stockCountsSynced > 0)
        parts.add(
          '$stockCountsSynced Stock Count${stockCountsSynced > 1 ? 's' : ''}',
        );
      if (locationsSynced > 0)
        parts.add('$locationsSynced Location${locationsSynced > 1 ? 's' : ''}');
      if (productsSynced > 0)
        parts.add('$productsSynced Product${productsSynced > 1 ? 's' : ''}');

      final dupMsg = allDuplicates.isNotEmpty
          ? ' (${allDuplicates.length} duplicates found)'
          : '';
      final healthMsg = _totalChunks > 0
          ? ' | Success Rate: ${_calculateSuccessRate()}% (${_totalChunks - _failedChunks}/$_totalChunks chunks)'
          : '';
      final detailMsg = parts.isNotEmpty
          ? 'Synced: ${parts.join(", ")}$dupMsg$healthMsg'
          : 'No items to sync';

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
      _recordError(e.toString());
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
      _beginAuthenticatedOperation();
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

      _checkPostSession();
      final records = await offlineStorage.getPendingPurchases();
      _checkPostSession();
      // Headers must be confirmed first; preserve normal invoice->purchase order.
      final invoices = await offlineStorage.getPendingInvoiceDetails();
      if (invoices.isNotEmpty) {
        return SyncResult(
          hasInternet: true,
          syncedCount: 0,
          success: false,
          message: 'Sync pending invoice headers first using Sync All.',
        );
      }
      final result = await _syncVersionedRows(
        'Purchases',
        records,
        onProgress: onProgress,
      );
      return SyncResult(
        hasInternet: true,
        syncedCount: (result['processed'] as num? ?? 0).toInt(),
        message: result['message'].toString(),
        success: result['success'] == true,
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
        'total':
            invoices.length +
            purchases.length +
            locations.length +
            products.length +
            mappings.length +
            counts.length,
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

  Future<void> _saveMasterCatalog(
    List<Map<String, dynamic>> masterCosts,
  ) async {
    if (masterCosts.isNotEmpty) {
      await offlineStorage.saveMasterCatalog(masterCosts);
    }
  }

  Future<void> _saveDownloadedInvoices(
    List<Map<String, dynamic>> invoices,
  ) async {
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

  // ==================== CORE BUSINESS LOGIC ====================
  Future<SyncResult> syncAll() async {
    // One coordinator owns success reporting and version-checked acknowledgements.
    return syncAllWithChunking();
  }

  Future<int> downloadExistingCounts() async {
    if (_isDisposed) return 0;
    if (_isSyncing) return 0;

    if (offlineStorage.pendingCounts.isNotEmpty) {
      const msg =
          'Cannot download: You have unsynced changes. Please press "Sync Data" (Upload) first.';
      logger?.error(msg);
      throw Exception(msg);
    }

    _isSyncing = true;
    _safeNotify();
    try {
      _beginAuthenticatedOperation();
      final hasInternet = await checkConnectivity();
      if (!hasInternet) throw Exception('No internet connection');

      _checkPostSession();
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
        final msg =
            'Download incomplete: got ${remoteCounts.length} of '
            '$expectedTotal records from server. Local data left unchanged '
            '— please retry.';
        logger?.error(msg);
        throw Exception(msg);
      }

      _checkPostSession();
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

  final Map<String, String> _refreshTableStates = {};
  Map<String, String> get refreshTableStates =>
      Map.unmodifiable(_refreshTableStates);

  final Map<String, String> _refreshWarnings = {};
  Map<String, String> get refreshWarnings => Map.unmodifiable(_refreshWarnings);

  Future<SyncResult> refreshMasterData({
    bool forceFullDownload = false,
    bool useVersionChecks = true,
  }) async {
    if (_isDisposed || _isSyncing) {
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        success: false,
        message: _isDisposed ? 'Service disposed' : 'Sync in progress',
      );
    }
    final storeId = offlineStorage.currentStoreId;
    final generation = offlineStorage.refreshStoreGeneration;
    if (storeId == null) {
      return SyncResult(
        hasInternet: true,
        syncedCount: 0,
        success: false,
        message: 'No store is open',
      );
    }
    void checkActive() {
      _checkPostSession();
      offlineStorage.checkRefreshStore(storeId, generation);
    }

    final refreshWatch = Stopwatch()..start();
    logger?.info(
      'Master refresh started (forceFullDownload=$forceFullDownload, useVersionChecks=$useVersionChecks)',
    );
    final failures = <String, String>{};
    final saved = <String, int>{};
    void reportFailure(String table, Object error) {
      failures[table] = error.toString();
      _refreshTableStates[table] = 'Failed: $error';
      _lastError = failures.entries
          .map((e) => '${e.key}: ${e.value}')
          .join('\n');
      logger?.error('Refresh $table failed', error);
      if (!_isDisposed) _safeNotify();
    }

    Future<List<Map<String, dynamic>>?> fetch(
      String table,
      Future<List<Map<String, dynamic>>> Function() action,
    ) async {
      try {
        checkActive();
        _refreshTableStates[table] = 'Downloading';
        _safeNotify();
        final rows = await action();
        checkActive();
        _refreshTableStates[table] = 'Downloaded ${rows.length} rows';
        return rows;
      } catch (e) {
        reportFailure(table, e);
        return null;
      }
    }

    Future<void> save(String table, List<Map<String, dynamic>>? rows) async {
      if (rows == null) return; // Never substitute a failed download with [].
      try {
        checkActive();
        _refreshTableStates[table] = 'Saving ${rows.length} rows';
        final count = await offlineStorage.applyDownloadedTable(
          table,
          rows,
          storeId: storeId,
          generation: generation,
        );
        checkActive();
        saved[table] = count;
        final warning = offlineStorage.refreshSaveWarnings[table];
        if (warning != null) {
          _refreshWarnings[table] = warning;
          logger?.info('Refresh $table legacy-data warning: $warning');
        }
        _refreshTableStates[table] =
            'Applied $count records from ${rows.length} downloaded rows'
            '${warning == null ? '' : '; warning: $warning'}';
        if (table == 'Inventory') _inventoryLoaded = true;
        logger?.info(
          'Refresh $table saved: $count remote records applied from ${rows.length} downloaded rows',
        );
        _safeNotify();
      } catch (e) {
        reportFailure(table, e);
      }
    }

    _isSyncing = true;
    _lastError = null;
    _lastSyncCount = 0;
    _refreshTableStates.clear();
    _refreshWarnings.clear();
    _safeNotify();
    try {
      _beginAuthenticatedOperation();
      if (!await checkConnectivity()) {
        _lastError = 'No internet connection';
        return SyncResult(
          hasInternet: false,
          syncedCount: 0,
          success: false,
          message: _lastError!,
        );
      }
      checkActive();
      if (useVersionChecks) {
        final snapshot = await offlineStorage.getDownloadSnapshot(storeId);
        checkActive();
        await googleSheets.restoreDownloadSnapshot(
          snapshot,
          legacyRows: offlineStorage.getStoredTableRows(),
        );
        checkActive();
        await googleSheets.beginVersionedRefresh(const [
          'Inventory',
          'Locations',
          'MasterCostsComputed',
          'AuditCalendar',
          'StockIssues',
          'ItemsIssuedMap',
          'PluMappings',
          'InvoiceDetails',
          'ItemsIssued',
          'ItemSales',
          'Purchases',
          'StoreSalesData',
        ], forceFullDownload: forceFullDownload);
      } else {
        googleSheets.clearCache();
      }
      checkActive();
      // Complete the small core group before enqueueing the large sales tables.
      final core = await Future.wait([
        fetch('Inventory', () => googleSheets.fetchInventory()),
        fetch('Locations', () => googleSheets.fetchLocations()),
        fetch('MasterCostsComputed', () => googleSheets.fetchComputedCosts()),
      ]);
      checkActive();
      await save('MasterCostsComputed', core[2]);
      // If costs failed, retain the prices supplied by Inventory itself.
      await save(
        'Inventory',
        core[0] == null
            ? null
            : core[2] == null
            ? core[0]
            : _mergeCostsIntoInventory(core[0]!, _buildCostMap(core[2]!)),
      );
      await save('Locations', core[1]);
      checkActive();
      // 1. Bundle 4 small auxiliary tables into 1 single round-trip
      const smallTables = [
        'AuditCalendar',
        'StockIssues',
        'ItemsIssuedMap',
        'PluMappings',
      ];

      Future<void> fetchAndSaveBundle() async {
        try {
          checkActive();
          for (final t in smallTables) {
            _refreshTableStates[t] = 'Downloading (bundled)';
          }
          _safeNotify();

          final bundle = await googleSheets.fetchBundledTables(smallTables);
          checkActive();

          for (final t in smallTables) {
            final rows = bundle[t];
            if (rows == null) {
              reportFailure(
                t,
                StateError(
                  googleSheets.bundleErrors[t] ?? 'Bundle omitted this table',
                ),
              );
              continue;
            }
            _refreshTableStates[t] =
                'Received ${rows.length} rows (bundled or verified cache)';
            await save(t, rows);
          }
        } catch (e) {
          logger?.error('Bundled fetch failed, reporting errors', e);
          for (final t in smallTables) {
            reportFailure(t, e);
          }
        }
      }

      // 2. Invoices & Small Tables (InvoiceDetails, ItemSales, ItemsIssued + _bundle)
      final prePurchaseJobs =
          <String, Future<List<Map<String, dynamic>>> Function()>{
            'InvoiceDetails': () => googleSheets.fetchInvoices(),
            'ItemsIssued': () => googleSheets.fetchItemsIssued(),
            'ItemSales': () => googleSheets.fetchItemSales(),
          };

      // Download and save Invoices and small tables first
      await Future.wait([
        fetchAndSaveBundle(),
        ...prePurchaseJobs.entries.map((job) async {
          final rows = await fetch(job.key, job.value);
          await save(job.key, rows);
        }),
      ]);

      checkActive();

      // 3. Purchases runs ALONE after Invoices are fully committed
      final purchaseRows = await fetch(
        'Purchases',
        () => googleSheets.fetchPurchases(),
      );
      await save('Purchases', purchaseRows);

      checkActive();

      // 4. Heavyweight: StoreSalesData runs ALONE without Google sheet lock contention
      final salesRows = await fetch(
        'StoreSalesData',
        () => googleSheets.fetchStoreSalesData(),
      );
      await save('StoreSalesData', salesRows);

      checkActive();
      if (useVersionChecks) {
        await googleSheets.finishVersionedRefresh();
        checkActive();
        await offlineStorage.saveDownloadSnapshot(
          storeId,
          googleSheets.exportDownloadSnapshot(),
        );
      }

      checkActive();

      logger?.info(
        'Master refresh reused ${googleSheets.reusedRefreshTables.length} verified tables; elapsed_ms=${refreshWatch.elapsedMilliseconds}',
      );

      _lastSyncCount = saved.values.fold<int>(0, (sum, count) => sum + count);
      final complete = failures.isEmpty && saved.length == 12;
      if (complete) _lastSyncTime = _formatDateTime(DateTime.now());

      final warningText = _refreshWarnings.isEmpty
          ? ''
          : ' Legacy data warnings: ${_refreshWarnings.entries.map((e) => '${e.key}: ${e.value}').join(' | ')}.';

      final message =
          (complete
              ? 'Refreshed all 12 tables; $_lastSyncCount remote records applied.'
              : 'Partial refresh: saved ${saved.length}/12 tables. Failed: ${failures.keys.join(', ')}.') +
          warningText;

      logger?.info(message);

      return SyncResult(
        hasInternet: true,
        syncedCount: _lastSyncCount,
        success: complete,
        message: message,
      );
    } catch (e) {
      _lastError = e.toString();
      logger?.error('Master refresh stopped', e);
      return SyncResult(
        hasInternet: true,
        syncedCount: saved.values.fold<int>(0, (sum, count) => sum + count),
        success: false,
        message: 'Refresh stopped: $e',
      );
    } finally {
      googleSheets.abortVersionedRefresh();
      logger?.info(
        'Master refresh finished: elapsed_ms=${refreshWatch.elapsedMilliseconds}',
      );
      _isSyncing = false;
      if (!_isDisposed) _safeNotify();
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

  // ============================================================================
  // 🔥 NEW: Health Check Methods
  // ============================================================================

  /// Get sync health statistics
  Future<Map<String, dynamic>> getSyncHealth() async {
    if (_isDisposed) {
      return {
        'hasInternet': false,
        'isSyncing': false,
        'lastSyncTime': '',
        'pendingCount': 0,
        'totalAttempts': _syncAttempts,
        'successfulAttempts': _syncSuccesses,
        'successRate': _syncAttempts > 0
            ? (_syncSuccesses / _syncAttempts * 100)
            : 0,
        'chunkSuccessRate': _totalChunks > 0
            ? ((_totalChunks - _failedChunks) / _totalChunks * 100)
            : 100,
        'recentErrors': _recentErrors.take(5).toList(),
        'lastError': _lastError,
        'inventoryLoaded': _inventoryLoaded,
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
      'totalAttempts': _syncAttempts,
      'successfulAttempts': _syncSuccesses,
      'successRate': _syncAttempts > 0
          ? (_syncSuccesses / _syncAttempts * 100)
          : 0,
      'chunkSuccessRate': _totalChunks > 0
          ? ((_totalChunks - _failedChunks) / _totalChunks * 100)
          : 100,
      'totalChunks': _totalChunks,
      'failedChunks': _failedChunks,
      'recentErrors': _recentErrors.take(5).toList(),
      'lastError': _lastError,
      'inventoryLoaded': _inventoryLoaded,
      'inventoryCount': stats['inventoryItems'] ?? 0,
      'totalCounts': stats['stockCounts'] ?? 0,
    };
  }

  /// Get sync success rate over time
  double getSyncSuccessRate() {
    if (_syncAttempts == 0) return 100.0;
    return (_syncSuccesses / _syncAttempts) * 100;
  }

  /// Record an error for health tracking
  void _recordError(String error) {
    _recentErrors.add('${DateTime.now().toIso8601String()}: $error');
    if (_recentErrors.length > _maxErrorsToStore) {
      _recentErrors.removeAt(0);
    }
  }

  /// Calculate success rate for current sync
  double _calculateSuccessRate() {
    if (_totalChunks == 0) return 100.0;
    return ((_totalChunks - _failedChunks) / _totalChunks) * 100;
  }

  /// Reset health tracking (call after major fixes)
  void resetHealthTracking() {
    _syncAttempts = 0;
    _syncSuccesses = 0;
    _failedChunks = 0;
    _totalChunks = 0;
    _recentErrors.clear();
    _lastError = null;
    logger?.info('🔄 Health tracking reset');
  }
}
