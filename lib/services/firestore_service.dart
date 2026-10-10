import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'logger_service.dart';

class FirestoreService {
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final LoggerService? logger;

  DateTime? _stockCircuitOpenUntil;
  static const Duration _stockCircuitCooldown = Duration(minutes: 2);

  bool get isStockWriteCircuitOpen =>
      _stockCircuitOpenUntil != null &&
          DateTime.now().isBefore(_stockCircuitOpenUntil!);

  DateTime? get stockWriteCircuitOpenUntil =>
      isStockWriteCircuitOpen ? _stockCircuitOpenUntil : null;

  void _closeStockCircuit() {
    _stockCircuitOpenUntil = null;
  }

  void _openStockCircuit() {
    _stockCircuitOpenUntil = DateTime.now().add(_stockCircuitCooldown);
    logger?.error(
      'FirestoreService: Stock Firestore client is not acknowledging '
          'operations; pausing stock recovery writes for 2 minutes.',
      null,
    );
  }

  FirestoreService({this.logger, FirebaseFirestore? db, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  // ===========================================================================
  // AUTHENTICATION
  // ===========================================================================

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Stream<User?> get idTokenChanges => _auth.idTokenChanges();
  String? get currentUserId => _auth.currentUser?.uid;

  String _requireSignedIn() {
    final uid = currentUserId;
    if (uid == null) {
      throw FirebaseAuthException(
        code: 'unauthenticated', message: 'Sign in before accessing Firestore.',
      );
    }
    return uid;
  }

  void _requireSameUser(String uid) {
    if (currentUserId != uid) {
      throw FirebaseAuthException(
        code: 'unauthenticated', message: 'The sign-in session changed. Retry after signing in.',
      );
    }
  }

  Future<UserCredential?> signInWithEmail(String email, String password) async {
    try {
      return await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } catch (e) {
      logger?.error('FirestoreService: Email sign in failed', e);
      rethrow;
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  String? get currentUserEmail => _auth.currentUser?.email;

  Future<void> registerStoreMetadata(String storeId, String storeName) async {
    _requireSignedIn();
    try {
      await _db.collection('stores').doc(storeId).set({
        'storeName': storeName,
        'storeId': storeId,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      logger?.error('FirestoreService: registerStoreMetadata failed', e);
      rethrow;
    }
  }

  Map<String, dynamic> _prepareStockCountForFirestore(
      Map<String, dynamic> count,
      String id,
      ) {
    final data = Map<String, dynamic>.from(count);

    // Match the Purchase/Invoice Firestore boundary: local bookkeeping belongs
    // in Hive, not in the authoritative cloud document.
    data.remove('syncStatus');
    data.remove('syncedAt');
    data.remove('postRecoveryConflict');

    // The document ID is authoritative. Keep stock_id for compatibility with
    // existing reporting code, but do not persist the duplicate local `id`.
    data.remove('id');
    data['stock_id'] = id;

    // Historical StockCounts can contain an empty Sheet header. Sanitize the
    // Firestore copy only; the original Sheet/Hive row remains untouched.
    final invalidKeys =
    data.keys.where((key) => key.trim().isEmpty).toList(growable: false);
    for (final key in invalidKeys) {
      data.remove(key);
    }
    if (invalidKeys.isNotEmpty) {
      logger?.info(
        '🧹 FirestoreService: Removed ${invalidKeys.length} invalid field name(s) '
            'from stock count $id',
      );
    }

    // The live StockCounts query explicitly requires deleted == false.
    // Historical Sheet rows normally have no deletion flag, so default it here.
    final deleted = data['deleted'];
    if (deleted is! bool) {
      data['deleted'] = false;
    }

    return data;
  }

  String _stockActivityOperation(Map<String, dynamic> count) {
    if (count['deleted'] == true || count['syncStatus'] == 'deleted') {
      return 'delete';
    }
    final updatedAt = count['updatedAt'] ?? count['updated_at'];
    return updatedAt == null ? 'create' : 'update';
  }

  String _stockActivityVersion(Map<String, dynamic> count) {
    final raw = count['deletedAt'] ??
        count['updatedAt'] ??
        count['updated_at'] ??
        count['createdAt'] ??
        count['created_at'] ??
        'current';
    final cleaned = raw.toString().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return cleaned.isEmpty ? 'current' : cleaned;
  }

  Map<String, dynamic> _stockActivityData({
    required Map<String, dynamic> count,
    required String id,
    required String operation,
    required String userId,
    required dynamic timestamp,
  }) {
    return <String, dynamic>{
      'area': 'stock_count',
      'operation': operation,
      'stock_id': id,
      'product_name': count['productName'] ??
          count['Product Name'] ??
          count['Inventory Product Name'] ??
          '',
      'barcode': count['barcode'] ?? count['Barcode'] ?? '',
      'location': count['location'] ?? count['Location'] ?? '',
      'audit_id': count['auditId'] ?? count['auditID'] ?? '',
      'count_date': count['date'] ?? count['Date'] ?? '',
      'count': count['count'] ?? count['Count'] ?? '',
      'timestamp': timestamp,
      'user_id': userId,
    };
  }

  String _stockActivityId(
      Map<String, dynamic> count,
      String id,
      String operation,
      ) {
    return 'stock_${operation}_${id}_${_stockActivityVersion(count)}';
  }

  Future<void> _writeStockActivity(
      String storeId,
      Map<String, dynamic> count,
      String id,
      String userId,
      ) async {
    final operation = _stockActivityOperation(count);
    final activityId = _stockActivityId(count, id, operation);
    await _db
        .collection('stores')
        .doc(storeId)
        .collection('activity_log')
        .doc(activityId)
        .set(
      _stockActivityData(
        count: count,
        id: id,
        operation: operation,
        userId: userId,
        timestamp: FieldValue.serverTimestamp(),
      ),
      SetOptions(merge: true),
    );
    logger?.info(
      'FirestoreService: Stock activity_log committed '
          'store=$storeId id=$activityId operation=$operation',
    );
  }

  // ===========================================================================
  // INVENTORY
  // ===========================================================================

  Future<bool> isInventoryMigrationComplete(String storeId) async {
    _requireSignedIn();
    final doc = await _db.collection('stores').doc(storeId).get();
    return doc.data()?['inventoryMigratedToFirestore'] == true;
  }

  Future<void> markInventoryMigrationComplete(String storeId) async {
    _requireSignedIn();
    await _db.collection('stores').doc(storeId).set({
      'inventoryMigratedToFirestore': true,
      'inventoryMigratedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Map<String, dynamic> _prepareInventoryForFirestore(
      Map<String, dynamic> product,
      String barcode,
      ) {
    final data = Map<String, dynamic>.from(product);
    data['Barcode'] = barcode;
    data.remove('syncStatus');
    data.remove('isLocal');

    final invalidKeys =
    data.keys.where((key) => key.trim().isEmpty).toList(growable: false);
    for (final key in invalidKeys) {
      data.remove(key);
    }
    return data;
  }

  Future<List<Map<String, dynamic>>> getInventory(String storeId) async {
    _requireSignedIn();
    final snapshot = await _db
        .collection('stores')
        .doc(storeId)
        .collection('inventory')
        .get();
    return snapshot.docs.map((doc) {
      final normalized = _normalizeFirestoreValue(doc.data());
      final data = Map<String, dynamic>.from(
        normalized as Map<String, dynamic>,
      );
      data['Barcode'] = doc.id;
      return data;
    }).toList();
  }

  /// Migration-only seed. Historical Inventory rows do not create activity
  /// events because activity_log is for operational user actions.
  Future<List<String>> seedInventoryBatch(
      String storeId,
      List<Map<String, dynamic>> products,
      ) async {
    if (products.isEmpty) return <String>[];
    if (products.length > 450) {
      throw ArgumentError.value(
        products.length,
        'products',
        'Inventory migration batches support at most 450 rows.',
      );
    }
    final userId = _requireSignedIn();
    final collection = _db
        .collection('stores')
        .doc(storeId)
        .collection('inventory');
    final batch = _db.batch();
    final ids = <String>[];

    for (final product in products) {
      final barcode = product['Barcode']?.toString().trim() ?? '';
      if (barcode.isEmpty || ids.contains(barcode)) continue;
      final data = _prepareInventoryForFirestore(product, barcode);
      data['updated_at'] = FieldValue.serverTimestamp();
      batch.set(collection.doc(barcode), data, SetOptions(merge: true));
      ids.add(barcode);
    }

    if (ids.isEmpty) return <String>[];
    await batch.commit();
    _requireSameUser(userId);
    return ids;
  }

  String _inventoryActivityVersion(Map<String, dynamic> product) {
    final raw = product['updatedAt'] ??
        product['updated_at'] ??
        product['createdAt'] ??
        product['created_at'] ??
        'current';
    final cleaned =
    raw.toString().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return cleaned.isEmpty ? 'current' : cleaned;
  }

  Map<String, dynamic> _inventoryActivityData({
    required Map<String, dynamic> product,
    required String barcode,
    required String operation,
    required String userId,
    required dynamic timestamp,
  }) {
    return <String, dynamic>{
      'area': 'inventory',
      'operation': operation,
      'barcode': barcode,
      'product_name': product['Inventory Product Name'] ??
          product['Product Name'] ??
          '',
      'main_category': product['Main Category'] ?? '',
      'category': product['Category'] ?? '',
      'uom': product['UoM'] ?? '',
      'single_unit_volume': product['Single Unit Volume'] ?? '',
      'timestamp': timestamp,
      'user_id': userId,
    };
  }

  Future<void> saveInventoryItem(
      String storeId,
      Map<String, dynamic> product,
      ) async {
    final userId = _requireSignedIn();
    final barcode = product['Barcode']?.toString().trim() ?? '';
    if (barcode.isEmpty) throw StateError('Inventory product barcode is required');

    final data = _prepareInventoryForFirestore(product, barcode);
    data['updated_at'] = FieldValue.serverTimestamp();
    if (data['created_at'] == null && data['createdAt'] == null) {
      data['created_at'] = FieldValue.serverTimestamp();
    }

    final storeRef = _db.collection('stores').doc(storeId);
    await storeRef
        .collection('inventory')
        .doc(barcode)
        .set(data, SetOptions(merge: true));

    _requireSameUser(userId);
    final operation = product['updatedAt'] == null ? 'create' : 'update';
    final activityId =
        'inventory_${operation}_${barcode}_${_inventoryActivityVersion(product)}';
    await storeRef.collection('activity_log').doc(activityId).set(
      _inventoryActivityData(
        product: product,
        barcode: barcode,
        operation: operation,
        userId: userId,
        timestamp: FieldValue.serverTimestamp(),
      ),
      SetOptions(merge: true),
    );
    _requireSameUser(userId);
    logger?.info(
      'FirestoreService: Inventory $operation committed store=$storeId barcode=$barcode',
    );
  }

  // ===========================================================================
  // STOCK COUNTS (Real-time)
  // ===========================================================================

  /// Watches stock counts for a specific store in real-time
  /// Watches stock counts for a specific store in real-time
  /// 🔥 FILTERS OUT DELETED RECORDS
  Stream<List<Map<String, dynamic>>> watchStockCounts(String storeId) {
    _requireSignedIn();
    var initialSnapshot = true;

    return _db
        .collection('stores')
        .doc(storeId)
        .collection('stock_counts')
        .where('deleted', isEqualTo: false)
        .orderBy('updated_at', descending: true)
        .snapshots()
        .map((snapshot) {
      // Hive/bootstrap already owns the full local working set. The first
      // Firestore snapshot is only the listener baseline; replaying the whole
      // collection into Hive here can freeze the Windows UI.
      if (initialSnapshot) {
        initialSnapshot = false;
        logger?.info(
          'FirestoreService: Stock listener baseline established '
              'store=$storeId docs=${snapshot.docs.length}',
        );
        return <Map<String, dynamic>>[];
      }

      final changes = <Map<String, dynamic>>[];
      for (final change in snapshot.docChanges) {
        final doc = change.doc;
        final normalized = _normalizeFirestoreValue(doc.data());
        final data = Map<String, dynamic>.from(
          normalized as Map<String, dynamic>,
        );
        data['id'] = doc.id;
        data['stock_id'] = doc.id;
        data['syncStatus'] = 'synced';

        if (change.type == DocumentChangeType.removed) {
          data['deleted'] = true;
          data['syncStatus'] = 'deleted';
        }

        changes.add(data);
      }

      if (changes.isNotEmpty) {
        logger?.info(
          'FirestoreService: Stock listener delta store=$storeId '
              'changes=${changes.length}',
        );
      }
      return changes;
    }).where((changes) => changes.isNotEmpty);
  }

  /// Returns whether the one-time historical StockCounts seed has been
  /// verified and marked complete for this store.
  Future<bool> isStockCountsMigrationComplete(String storeId) async {
    _requireSignedIn();
    final snapshot = await _db.collection('stores').doc(storeId).get();
    return snapshot.data()?['stockCountsMigratedToFirestore'] == true;
  }

  /// Marks the historical StockCounts seed complete only after verification.
  Future<void> markStockCountsMigrationComplete(String storeId) async {
    _requireSignedIn();
    await _db.collection('stores').doc(storeId).set({
      'stockCountsMigratedToFirestore': true,
      'stockCountsMigratedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Full one-shot StockCounts read used by migration verification/recovery.
  ///
  /// Deleted documents are intentionally included here: migration verification
  /// must inspect the complete Firestore collection rather than the live UI
  /// view, which filters deleted records.
  Future<List<Map<String, dynamic>>> getStockCounts(String storeId) async {
    _requireSignedIn();
    final snapshot = await _db
        .collection('stores')
        .doc(storeId)
        .collection('stock_counts')
        .get();

    return snapshot.docs.map((doc) {
      final normalized = _normalizeFirestoreValue(doc.data());
      final data = Map<String, dynamic>.from(
        normalized as Map<String, dynamic>,
      );
      data['id'] = doc.id;
      data['stock_id'] = doc.id;
      return data;
    }).toList();
  }

  /// Saves or updates a stock count document
  Future<void> saveStockCount(String storeId, Map<String, dynamic> count) async {
    final userId = _requireSignedIn();
    final id = count['id'] ?? count['stock_id'];
    if (id == null) {
      logger?.error('FirestoreService: Stock count ID is missing', null);
      throw Exception('Stock count ID is missing');
    }

    try {
      final data = _prepareStockCountForFirestore(count, id.toString());
      data['updated_at'] = FieldValue.serverTimestamp();
      if (data['created_at'] == null && data['createdAt'] == null) {
        data['created_at'] = FieldValue.serverTimestamp();
      }

      await _db
          .collection('stores')
          .doc(storeId)
          .collection('stock_counts')
          .doc(id.toString())
          .set(data, SetOptions(merge: true));

      _requireSameUser(userId);
      await _writeStockActivity(
        storeId,
        count,
        id.toString(),
        userId,
      );

      logger?.info('FirestoreService: Saved stock count $id');
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Save stock count failed store=$storeId id=$id',
        '$e\n$st',
      );
      rethrow;
    }
  }

  /// Batch save stock counts. Each row writes the canonical StockCount plus
  /// one deterministic activity_log event, so one Firestore batch supports
  /// at most 250 StockCounts.
  Future<List<String>> saveStockCountsBatch(
      String storeId,
      List<Map<String, dynamic>> counts,
      ) async {
    if (counts.isEmpty) return <String>[];
    if (counts.length > 250) {
      throw ArgumentError.value(
        counts.length,
        'counts',
        'Each StockCount uses two Firestore writes; batches support at most 250 rows.',
      );
    }
    final userId = _requireSignedIn();

    if (isStockWriteCircuitOpen) {
      logger?.info(
        'FirestoreService: Stock recovery write skipped — circuit open until '
            '${_stockCircuitOpenUntil!.toIso8601String()}.',
      );
      return <String>[];
    }

    // The common recovery case is one pending count. Avoid WriteBatch.commit()
    // for that case and use a direct document set instead.
    if (counts.length == 1) {
      final count = counts.first;
      final rawId = count['id'] ?? count['stock_id'];
      final id = rawId?.toString().trim();
      if (id == null || id.isEmpty) return <String>[];

      logger?.info(
        'FirestoreService: Saving single pending stock count directly '
            'store=$storeId id=$id',
      );
      try {
        await saveStockCount(storeId, count)
            .timeout(const Duration(seconds: 20));
        _requireSameUser(userId);
        _closeStockCircuit();
        return <String>[id];
      } on TimeoutException catch (e, st) {
        _requireSameUser(userId);
        _openStockCircuit();
        logger?.error(
          'FirestoreService: Direct stock write acknowledgement timed out; '
              'record remains pending.',
          '$e\n$st',
        );
        return <String>[];
      }
    }

    logger?.info(
      'FirestoreService: Saving stock batch store=$storeId rows=${counts.length}',
    );

    final storeRef = _db.collection('stores').doc(storeId);
    final collection = storeRef.collection('stock_counts');
    final activityLog = storeRef.collection('activity_log');
    final batch = _db.batch();
    final now = FieldValue.serverTimestamp();
    final writeToken =
        'stock_${DateTime.now().microsecondsSinceEpoch}_${counts.length}';
    final queuedIds = <String>[];

    for (final count in counts) {
      final rawId = count['id'] ?? count['stock_id'];
      final id = rawId?.toString().trim();
      if (id == null || id.isEmpty) {
        logger?.info(
          '⚠️ FirestoreService: Skipped stock count with missing ID in batch store=$storeId',
        );
        continue;
      }

      final data = _prepareStockCountForFirestore(count, id);
      data['updated_at'] = now;

      // This token is operational metadata used only to prove that this exact
      // client submission reached Firestore when the Windows native commit
      // Future fails to acknowledge in time.
      data['client_write_token'] = writeToken;

      batch.set(collection.doc(id), data, SetOptions(merge: true));

      final operation = _stockActivityOperation(count);
      final activityId = _stockActivityId(count, id, operation);
      batch.set(
        activityLog.doc(activityId),
        _stockActivityData(
          count: count,
          id: id,
          operation: operation,
          userId: userId,
          timestamp: now,
        ),
        SetOptions(merge: true),
      );
      queuedIds.add(id);
    }

    if (queuedIds.isEmpty) {
      logger?.info(
        '⚠️ FirestoreService: No valid stock counts queued for batch store=$storeId',
      );
      return <String>[];
    }

    logger?.info(
      'FirestoreService: Committing stock batch store=$storeId queued=${queuedIds.length}',
    );

    try {
      await batch.commit().timeout(const Duration(seconds: 20));
      _requireSameUser(userId);
      _closeStockCircuit();
      logger?.info(
        'FirestoreService: Stock batch committed store=$storeId queued=${queuedIds.length}',
      );
      return queuedIds;
    } on TimeoutException catch (e, st) {
      _requireSameUser(userId);
      logger?.info(
        '⚠️ FirestoreService: Stock batch acknowledgement timed out; '
            'checking Firestore server for exact write token.',
      );

      final confirmedIds = await _confirmStockWriteToken(
        collection: collection,
        ids: queuedIds,
        writeToken: writeToken,
      );

      if (confirmedIds.length == queuedIds.length) {
        _closeStockCircuit();
        logger?.info(
          '✅ FirestoreService: Server read-back confirmed '
              '${confirmedIds.length}/${queuedIds.length} stock writes after timeout.',
        );
        return confirmedIds;
      }

      _openStockCircuit();
      logger?.error(
        'FirestoreService: Stock batch timed out and server read-back confirmed '
            '${confirmedIds.length}/${queuedIds.length}; unconfirmed records remain pending.',
        '$e\n$st',
      );

      // Do NOT retry individual writes here. The timed-out native batch may
      // still complete later. Returning only server-confirmed IDs prevents
      // false Hive acknowledgement and avoids duplicate native write pressure.
      return confirmedIds;
    } on FirebaseException catch (e, st) {
      logger?.error(
        'FirestoreService: Batch save failed store=$storeId rows=${counts.length}',
        '$e\n$st',
      );
      _requireSameUser(userId);

      if (e.code == 'unauthenticated' || e.code == 'permission-denied') {
        rethrow;
      }

      // For a real SDK error (not an acknowledgement timeout), retain the
      // existing per-record fallback.
      final confirmedIds = <String>[];
      for (final count in counts) {
        _requireSameUser(userId);
        final rawId = count['id'] ?? count['stock_id'];
        final id = rawId?.toString().trim();
        if (id == null || id.isEmpty) continue;

        try {
          await saveStockCount(storeId, count)
              .timeout(const Duration(seconds: 20));
          confirmedIds.add(id);
        } on TimeoutException {
          logger?.info(
            '⚠️ FirestoreService: Individual stock write acknowledgement '
                'timed out for $id; leaving it pending.',
          );
        }
      }
      return confirmedIds;
    }
  }

  Future<List<String>> _confirmStockWriteToken({
    required CollectionReference<Map<String, dynamic>> collection,
    required List<String> ids,
    required String writeToken,
  }) async {
    try {
      final checks = ids.map((id) async {
        try {
          final snapshot = await collection
              .doc(id)
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 15));
          if (!snapshot.exists) return null;
          return snapshot.data()?['client_write_token'] == writeToken ? id : null;
        } catch (e) {
          logger?.info(
            '⚠️ FirestoreService: Server read-back could not confirm stock count $id: $e',
          );
          return null;
        }
      });

      final results = await Future.wait(checks)
          .timeout(const Duration(seconds: 20));
      return results.whereType<String>().toList(growable: false);
    } on TimeoutException {
      logger?.info(
        '⚠️ FirestoreService: Stock server read-back timed out; '
            'unconfirmed records will remain pending.',
      );
      return <String>[];
    }
  }

  /// Soft-deletes a stock count so downstream reporting can observe the delete.
  ///
  /// Do not hard-delete StockCount documents here. Google Sheets is a reporting
  /// mirror of Firestore and needs a durable tombstone with a server-side
  /// `updated_at` to remove the corresponding reporting row incrementally.
  Future<void> deleteStockCount(String storeId, String id) async {
    _requireSignedIn();
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Stock count ID is required');
    }

    try {
      await _db
          .collection('stores')
          .doc(storeId)
          .collection('stock_counts')
          .doc(normalizedId)
          .set({
        'stock_id': normalizedId,
        'deleted': true,
        'deleted_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      logger?.info('FirestoreService: Tombstoned stock count $normalizedId');
    } catch (e) {
      logger?.error('FirestoreService: Delete stock count failed', e);
      rethrow;
    }
  }

  // ===========================================================================
  // INVOICE DETAILS
  // ===========================================================================

  Future<bool> isInvoicesMigrationComplete(String storeId) async {
    _requireSignedIn();
    final doc = await _db.collection('stores').doc(storeId).get();
    return doc.data()?['invoicesMigratedToFirestore'] == true;
  }

  Future<void> markInvoicesMigrationComplete(String storeId) async {
    _requireSignedIn();
    await _db.collection('stores').doc(storeId).set({
      'invoicesMigratedToFirestore': true,
      'invoicesMigratedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<List<Map<String, dynamic>>> getInvoices(String storeId) async {
    _requireSignedIn();
    final snapshot = await _db
        .collection('stores').doc(storeId).collection('invoices').get();
    return snapshot.docs.map(_invoiceFromDoc).toList();
  }

  Future<InvoiceDelta> getInvoiceChanges(
      String storeId, {
        DateTime? upsertsSince,
        DateTime? deletesSince,
      }) async {
    _requireSignedIn();
    final storeRef = _db.collection('stores').doc(storeId);
    final invoices = storeRef.collection('invoices');
    final changes = storeRef.collection('invoice_changes');
    try {
      Query<Map<String, dynamic>> upsertQuery = invoices;
      if (upsertsSince != null) {
        upsertQuery = upsertQuery
            .where('updated_at', isGreaterThan: Timestamp.fromDate(upsertsSince.toUtc()))
            .orderBy('updated_at');
      } else {
        upsertQuery = upsertQuery.orderBy('updated_at', descending: true).limit(1);
      }
      Query<Map<String, dynamic>> deleteQuery = changes;
      if (deletesSince != null) {
        deleteQuery = deleteQuery
            .where('changed_at', isGreaterThan: Timestamp.fromDate(deletesSince.toUtc()))
            .orderBy('changed_at');
      } else {
        deleteQuery = deleteQuery.orderBy('changed_at', descending: true).limit(1);
      }
      final results = await Future.wait([upsertQuery.get(), deleteQuery.get()]);
      final upserts = <Map<String, dynamic>>[];
      final deletedIds = <String>[];
      DateTime? newestUpsert = upsertsSince;
      DateTime? newestDelete = deletesSince;
      for (final doc in results[0].docs) {
        upserts.add(_invoiceFromDoc(doc));
        final ts = doc.data()['updated_at'];
        if (ts is Timestamp && (newestUpsert == null || ts.toDate().isAfter(newestUpsert))) {
          newestUpsert = ts.toDate().toUtc();
        }
      }
      for (final doc in results[1].docs) {
        final data = doc.data();
        final id = data['invoiceId']?.toString().trim();
        if (id != null && id.isNotEmpty) deletedIds.add(id);
        final ts = data['changed_at'];
        if (ts is Timestamp && (newestDelete == null || ts.toDate().isAfter(newestDelete))) {
          newestDelete = ts.toDate().toUtc();
        }
      }
      logger?.info('FirestoreService: Invoice delta store=$storeId upserts=${upserts.length} deletes=${deletedIds.length}');
      return InvoiceDelta(upserts: upserts, deletedIds: deletedIds, upsertCursor: newestUpsert, deleteCursor: newestDelete);
    } catch (e, st) {
      logger?.error('FirestoreService: Invoice delta failed store=$storeId', '$e\n$st');
      rethrow;
    }
  }

  Map<String, dynamic> _invoiceFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final normalized = _normalizeFirestoreValue(doc.data());
    final data = Map<String, dynamic>.from(normalized as Map<String, dynamic>);
    data['invoiceDetailsID'] = doc.id;
    data['syncStatus'] = 'synced';
    return data;
  }

  Map<String, dynamic> _prepareInvoiceForFirestore(Map<String, dynamic> invoice) {
    final data = Map<String, dynamic>.from(invoice);
    data.remove('syncStatus');
    data.remove('syncedAt');
    data.remove('postRecoveryConflict');
    data.removeWhere((key, _) => key.trim().isEmpty);
    return data;
  }

  Future<void> saveInvoicesBatch(String storeId, List<Map<String, dynamic>> invoices) async {
    if (invoices.isEmpty) return;
    if (invoices.length > 250) {
      throw ArgumentError.value(invoices.length, 'invoices', 'Each Invoice uses two Firestore writes; batches support at most 250 Invoices.');
    }
    final userId = _requireSignedIn();
    final batch = _db.batch();
    final storeRef = _db.collection('stores').doc(storeId);
    final collection = storeRef.collection('invoices');
    final changeLog = storeRef.collection('invoice_changes');
    final now = FieldValue.serverTimestamp();
    var queued = 0;
    for (final invoice in invoices) {
      _requireSameUser(userId);
      final id = invoice['invoiceDetailsID']?.toString().trim();
      if (id == null || id.isEmpty) throw StateError('Invoice invoiceDetailsID is missing');
      final data = _prepareInvoiceForFirestore(invoice);
      data['updated_at'] = now;
      batch.set(collection.doc(id), data, SetOptions(merge: true));
      batch.delete(changeLog.doc(id));
      queued++;
    }
    logger?.info('FirestoreService: Committing invoice batch store=$storeId queued=$queued');
    await batch.commit();
    _requireSameUser(userId);
    logger?.info('FirestoreService: Invoice batch committed store=$storeId queued=$queued');
  }

  Future<void> deleteInvoicesBatch(
      String storeId,
      List<String> invoiceIds, {
        List<Map<String, dynamic>>? activityRows,
      }) async {
    final ids = invoiceIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return;

    // Canonical delete + invoice_changes tombstone + activity_log = 3 writes.
    if (ids.length > 166) {
      throw ArgumentError.value(
        ids.length,
        'invoiceIds',
        'Each Invoice delete uses three Firestore writes when activity logging '
            'is enabled; batches support at most 166 Invoices.',
      );
    }

    final rowsById = <String, Map<String, dynamic>>{
      for (final row in activityRows ?? const <Map<String, dynamic>>[])
        if ((row['invoiceDetailsID']?.toString().trim() ?? '').isNotEmpty)
          row['invoiceDetailsID'].toString().trim(): row,
    };

    final userId = _requireSignedIn();
    final batch = _db.batch();
    final storeRef = _db.collection('stores').doc(storeId);
    final collection = storeRef.collection('invoices');
    final changeLog = storeRef.collection('invoice_changes');
    final activityLog = storeRef.collection('activity_log');
    final now = FieldValue.serverTimestamp();

    for (final id in ids) {
      _requireSameUser(userId);
      batch.delete(collection.doc(id));
      batch.set(
        changeLog.doc(id),
        {'invoiceId': id, 'operation': 'delete', 'changed_at': now},
        SetOptions(merge: true),
      );

      final row = rowsById[id] ?? const <String, dynamic>{};
      final deletedAt = row['deletedAt']?.toString() ?? '';
      final versionToken = deletedAt
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final activityId =
          'grv_delete_${id}_${versionToken.isEmpty ? 'current' : versionToken}';

      batch.set(
        activityLog.doc(activityId),
        <String, dynamic>{
          'timestamp': now,
          'area': 'grv',
          'operation': 'grv_delete',
          'invoice_id': id,
          'invoice_number': row['Invoice Number'] ??
              row['invoiceNumber'] ??
              row['invoice_number'] ??
              '',
          'grv_reference': row['GRV Reference'] ??
              row['grvReference'] ??
              row['grv_reference'] ??
              '',
          'reason': row['deletionReason'] ?? 'user_deleted_invoice',
          'user_id': userId,
        },
        SetOptions(merge: true),
      );

      logger?.info(
        'FirestoreService: Queued activity_log event store=$storeId '
            'id=$activityId operation=grv_delete',
      );
    }

    logger?.info(
      'FirestoreService: Deleting invoice batch store=$storeId rows=${ids.length}',
    );
    await batch.commit();
    _requireSameUser(userId);
    logger?.info(
      'FirestoreService: Invoice delete batch committed store=$storeId rows=${ids.length}',
    );
  }

  /// Atomically saves one invoice header and its purchase lines.
  ///
  /// Each row uses two writes (canonical document + change-log cleanup), so
  /// one invoice plus at most 249 purchases fits Firestore's 500-write batch.
  Future<void> saveInvoiceWithPurchasesBatch(
      String storeId,
      Map<String, dynamic> invoice,
      List<Map<String, dynamic>> purchases, {
        List<Map<String, dynamic>> deletedPurchases =
        const <Map<String, dynamic>>[],
        int? remainingPurchaseCount,
      }) async {
    // 2 writes for the invoice, 2 per purchase upsert/delete, plus 1 activity log.
    final purchaseWriteCount = purchases.length + deletedPurchases.length;
    if (purchaseWriteCount > 248) {
      throw ArgumentError.value(
        purchaseWriteCount,
        'purchases',
        'One invoice plus purchase upserts/deletes uses two Firestore writes '
            'per row, plus one activity-log write; an atomic GRV batch supports '
            'at most 248 purchase mutations.',
      );
    }

    final userId = _requireSignedIn();
    final invoiceId = invoice['invoiceDetailsID']?.toString().trim();
    if (invoiceId == null || invoiceId.isEmpty) {
      throw StateError('Invoice invoiceDetailsID is missing');
    }

    final storeRef = _db.collection('stores').doc(storeId);
    final batch = _db.batch();
    final now = FieldValue.serverTimestamp();

    final invoiceData = _prepareInvoiceForFirestore(invoice);
    invoiceData['updated_at'] = now;
    batch.set(
      storeRef.collection('invoices').doc(invoiceId),
      invoiceData,
      SetOptions(merge: true),
    );
    batch.delete(storeRef.collection('invoice_changes').doc(invoiceId));

    for (final purchase in purchases) {
      _requireSameUser(userId);
      final purchaseId = purchase['purchases_ID']?.toString().trim();
      if (purchaseId == null || purchaseId.isEmpty) {
        throw StateError('Purchase purchases_ID is missing');
      }
      final linkedInvoiceId = purchase['invoiceDetailsID']?.toString().trim();
      if (linkedInvoiceId != invoiceId) {
        throw StateError(
          'Purchase $purchaseId belongs to invoice $linkedInvoiceId, '
              'not $invoiceId.',
        );
      }
      final purchaseData = _preparePurchaseForFirestore(purchase);
      purchaseData['updated_at'] = now;
      batch.set(
        storeRef.collection('purchases').doc(purchaseId),
        purchaseData,
        SetOptions(merge: true),
      );
      batch.delete(storeRef.collection('purchase_changes').doc(purchaseId));
    }

    for (final purchase in deletedPurchases) {
      _requireSameUser(userId);
      final purchaseId = purchase['purchases_ID']?.toString().trim();
      if (purchaseId == null || purchaseId.isEmpty) {
        throw StateError('Deleted Purchase purchases_ID is missing');
      }
      final linkedInvoiceId = purchase['invoiceDetailsID']?.toString().trim();
      if (linkedInvoiceId != invoiceId) {
        throw StateError(
          'Deleted Purchase $purchaseId belongs to invoice $linkedInvoiceId, '
              'not $invoiceId.',
        );
      }
      batch.delete(storeRef.collection('purchases').doc(purchaseId));
      batch.set(
        storeRef.collection('purchase_changes').doc(purchaseId),
        <String, dynamic>{
          'purchaseId': purchaseId,
          'operation': 'delete',
          'changed_at': now,
        },
        SetOptions(merge: true),
      );
    }

    // Human-readable operational audit entry. Keep this in the SAME batch as
    // the invoice/purchases so the activity entry cannot exist without the
    // corresponding GRV write (or vice versa).
    final versionValue =
        invoice['updatedAt'] ?? invoice['updated_at'] ?? invoice['createdAt'] ?? '';
    final versionToken = versionValue
        .toString()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final activityOperation =
    deletedPurchases.isNotEmpty ? 'line_delete' : 'save';
    final activityPrefix =
    deletedPurchases.isNotEmpty ? 'grv_line_delete' : 'grv_save';
    final activityId =
        '${activityPrefix}_${invoiceId}_${versionToken.isEmpty ? 'current' : versionToken}';
    final activityRef = storeRef.collection('activity_log').doc(activityId);
    batch.set(
      activityRef,
      <String, dynamic>{
        'timestamp': now,
        'area': 'grv',
        'operation': activityOperation,
        'invoice_id': invoiceId,
        'invoice_number': invoice['Invoice Number'] ??
            invoice['invoiceNumber'] ??
            invoice['invoice_number'] ??
            invoice['invoiceNo'] ??
            '',
        'grv_reference': invoice['GRV Reference'] ??
            invoice['grvReference'] ??
            invoice['grv_reference'] ??
            invoice['grvNumber'] ??
            '',
        'submitted_purchase_count': purchases.length,
        if (deletedPurchases.isNotEmpty)
          'deleted_purchase_count': deletedPurchases.length,
        if (remainingPurchaseCount != null)
          'remaining_purchase_count': remainingPurchaseCount,
        'user_id': userId,
      },
      SetOptions(merge: true),
    );
    logger?.info(
      'FirestoreService: Queued activity_log event store=$storeId '
          'id=$activityId operation=$activityOperation',
    );

    logger?.info(
      'FirestoreService: Committing atomic GRV store=$storeId '
          'invoice=$invoiceId upserts=${purchases.length} '
          'deletes=${deletedPurchases.length}',
    );
    await batch.commit();
    _requireSameUser(userId);
    logger?.info(
      'FirestoreService: Atomic GRV committed store=$storeId '
          'invoice=$invoiceId upserts=${purchases.length} '
          'deletes=${deletedPurchases.length}',
    );
  }

  // ===========================================================================
  // PURCHASES
  // ===========================================================================

  /// Whether the one-time Google Sheets -> Firestore purchase migration has
  /// been completed for this store.
  Future<bool> isPurchasesMigrationComplete(String storeId) async {
    _requireSignedIn();
    final doc = await _db.collection('stores').doc(storeId).get();
    return doc.data()?['purchasesMigratedToFirestore'] == true;
  }

  /// Marks Firestore as authoritative for Purchases after the historical seed
  /// has committed successfully.
  Future<void> markPurchasesMigrationComplete(String storeId) async {
    _requireSignedIn();
    await _db.collection('stores').doc(storeId).set({
      'purchasesMigratedToFirestore': true,
      'purchasesMigratedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Fetches all purchases for a store from Firestore.
  ///
  /// Keep this as an explicit bootstrap/recovery path. Routine refreshes should
  /// use [getPurchaseChanges] so the app does not read the whole collection.
  Future<List<Map<String, dynamic>>> getPurchases(String storeId) async {
    _requireSignedIn();
    try {
      final snapshot = await _db
          .collection('stores')
          .doc(storeId)
          .collection('purchases')
          .get();

      return snapshot.docs.map(_purchaseFromDoc).toList();
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Fetch purchases failed store=$storeId',
        '$e\n$st',
      );
      rethrow;
    }
  }

  /// Returns only Purchase changes newer than the supplied cursors.
  ///
  /// Upserts and deletions intentionally have separate cursors. This prevents a
  /// fast write on one stream from advancing past an unseen change on the other.
  /// A small overlap is applied by the caller; duplicate IDs are harmless.
  Future<PurchaseDelta> getPurchaseChanges(
      String storeId, {
        DateTime? upsertsSince,
        DateTime? deletesSince,
      }) async {
    _requireSignedIn();
    final purchases = _db
        .collection('stores')
        .doc(storeId)
        .collection('purchases');
    final changes = _db
        .collection('stores')
        .doc(storeId)
        .collection('purchase_changes');

    try {
      Query<Map<String, dynamic>> upsertQuery = purchases;
      if (upsertsSince != null) {
        upsertQuery = upsertQuery
            .where('updated_at', isGreaterThan: Timestamp.fromDate(upsertsSince.toUtc()))
            .orderBy('updated_at');
      } else {
        // Existing Hive data is already the bootstrap snapshot. One read finds
        // the newest Firestore write and establishes the incremental cursor.
        upsertQuery = upsertQuery.orderBy('updated_at', descending: true).limit(1);
      }

      Query<Map<String, dynamic>> deleteQuery = changes;
      if (deletesSince != null) {
        deleteQuery = deleteQuery
            .where('changed_at', isGreaterThan: Timestamp.fromDate(deletesSince.toUtc()))
            .orderBy('changed_at');
      } else {
        // purchase_changes starts with this feature. Reading the newest event is
        // enough to seed a cursor without scanning historical Purchases.
        deleteQuery = deleteQuery.orderBy('changed_at', descending: true).limit(1);
      }

      final results = await Future.wait([upsertQuery.get(), deleteQuery.get()]);
      final upsertSnapshot = results[0];
      final deleteSnapshot = results[1];

      DateTime? newestUpsert = upsertsSince;
      final upserts = <Map<String, dynamic>>[];
      for (final doc in upsertSnapshot.docs) {
        upserts.add(_purchaseFromDoc(doc));
        final ts = doc.data()['updated_at'];
        if (ts is Timestamp &&
            (newestUpsert == null || ts.toDate().isAfter(newestUpsert))) {
          newestUpsert = ts.toDate().toUtc();
        }
      }

      DateTime? newestDelete = deletesSince;
      final deletedIds = <String>[];
      for (final doc in deleteSnapshot.docs) {
        final data = doc.data();
        final id = data['purchaseId']?.toString().trim();
        if (id != null && id.isNotEmpty) deletedIds.add(id);
        final ts = data['changed_at'];
        if (ts is Timestamp &&
            (newestDelete == null || ts.toDate().isAfter(newestDelete))) {
          newestDelete = ts.toDate().toUtc();
        }
      }

      logger?.info(
        'FirestoreService: Purchase delta store=$storeId '
            'upserts=${upserts.length} deletes=${deletedIds.length}',
      );
      return PurchaseDelta(
        upserts: upserts,
        deletedIds: deletedIds,
        upsertCursor: newestUpsert,
        deleteCursor: newestDelete,
      );
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Purchase delta failed store=$storeId',
        '$e\n$st',
      );
      rethrow;
    }
  }

  Map<String, dynamic> _purchaseFromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc,
      ) {
    final normalized = _normalizeFirestoreValue(doc.data());
    final data = Map<String, dynamic>.from(normalized as Map<String, dynamic>);
    data['purchases_ID'] = doc.id;
    data['syncStatus'] = 'synced';
    return data;
  }

  /// Saves or updates a single purchase using `purchases_ID` as the document ID.
  Future<void> savePurchase(
      String storeId,
      Map<String, dynamic> purchase,
      ) async {
    _requireSignedIn();
    final id = purchase['purchases_ID']?.toString().trim();
    if (id == null || id.isEmpty) {
      throw StateError('Purchase purchases_ID is missing');
    }

    final data = _preparePurchaseForFirestore(purchase);
    data['updated_at'] = FieldValue.serverTimestamp();

    try {
      final storeRef = _db.collection('stores').doc(storeId);
      final batch = _db.batch();
      batch.set(
        storeRef.collection('purchases').doc(id),
        data,
        SetOptions(merge: true),
      );
      // If this canonical ID is recreated after a delete, remove its tombstone.
      batch.delete(storeRef.collection('purchase_changes').doc(id));
      await batch.commit();
      logger?.info('FirestoreService: Saved purchase $id');
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Save purchase failed store=$storeId id=$id',
        '$e\n$st',
      );
      rethrow;
    }
  }

  /// Batch saves purchases. Existing IDs make retries idempotent.
  Future<void> savePurchasesBatch(
      String storeId,
      List<Map<String, dynamic>> purchases,
      ) async {
    if (purchases.isEmpty) return;
    if (purchases.length > 250) {
      throw ArgumentError.value(
        purchases.length,
        'purchases',
        'Each Purchase uses two Firestore writes; batches support at most 250 Purchases.',
      );
    }

    final userId = _requireSignedIn();
    final batch = _db.batch();
    final storeRef = _db.collection('stores').doc(storeId);
    final collection = storeRef.collection('purchases');
    final changeLog = storeRef.collection('purchase_changes');
    final now = FieldValue.serverTimestamp();
    var queued = 0;

    for (final purchase in purchases) {
      _requireSameUser(userId);
      final id = purchase['purchases_ID']?.toString().trim();
      if (id == null || id.isEmpty) {
        throw StateError('Purchase purchases_ID is missing');
      }
      final data = _preparePurchaseForFirestore(purchase);
      data['updated_at'] = now;
      batch.set(collection.doc(id), data, SetOptions(merge: true));
      batch.delete(changeLog.doc(id));
      queued++;
    }

    try {
      logger?.info(
        'FirestoreService: Committing purchase batch store=$storeId queued=$queued',
      );
      await batch.commit();
      _requireSameUser(userId);
      logger?.info(
        'FirestoreService: Purchase batch committed store=$storeId queued=$queued',
      );
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Purchase batch failed store=$storeId rows=${purchases.length}',
        '$e\n$st',
      );
      rethrow;
    }
  }

  /// Deletes purchase documents by their canonical purchase IDs.
  Future<void> deletePurchasesBatch(
      String storeId,
      List<String> purchaseIds, {
        List<Map<String, dynamic>> activityRows =
        const <Map<String, dynamic>>[],
      }) async {
    if (purchaseIds.isEmpty) return;
    final writesPerPurchase = activityRows.isEmpty ? 2 : 3;
    final maxRows = 500 ~/ writesPerPurchase;
    if (purchaseIds.length > maxRows) {
      throw ArgumentError.value(
        purchaseIds.length,
        'purchaseIds',
        'Purchase delete batch supports at most $maxRows rows when '
            '${activityRows.isEmpty ? 'activity logging is disabled' : 'activity logging is enabled'}.',
      );
    }

    final userId = _requireSignedIn();
    final batch = _db.batch();
    final storeRef = _db.collection('stores').doc(storeId);
    final collection = storeRef.collection('purchases');
    final changeLog = storeRef.collection('purchase_changes');
    final activityLog = storeRef.collection('activity_log');
    final now = FieldValue.serverTimestamp();
    final rowsById = <String, Map<String, dynamic>>{
      for (final row in activityRows)
        if ((row['purchases_ID']?.toString().trim() ?? '').isNotEmpty)
          row['purchases_ID'].toString().trim(): row,
    };

    for (final rawId in purchaseIds) {
      _requireSameUser(userId);
      final id = rawId.trim();
      if (id.isEmpty) throw StateError('Purchase ID is empty');
      batch.delete(collection.doc(id));
      // Same batch = the hard delete and its tombstone are atomic.
      batch.set(changeLog.doc(id), {
        'purchaseId': id,
        'operation': 'delete',
        'changed_at': now,
      }, SetOptions(merge: true));

      final row = rowsById[id];
      if (row != null) {
        final deletedAt = row['deletedAt']?.toString() ?? '';
        final versionToken =
        deletedAt.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final activityId =
            'grv_line_delete_${id}_${versionToken.isEmpty ? 'current' : versionToken}';
        batch.set(
          activityLog.doc(activityId),
          <String, dynamic>{
            'timestamp': now,
            'area': 'grv',
            'operation': 'line_delete',
            'invoice_id': row['invoiceDetailsID'] ?? '',
            'invoice_number': row['Invoice Nr.'] ??
                row['Invoice Number'] ??
                row['invoice_number'] ??
                '',
            'grv_reference': row['GRV Reference'] ??
                row['grv_reference'] ??
                '',
            'deleted_purchase_count': 1,
            'purchase_id': id,
            'user_id': userId,
            'source': 'purchase_delete_recovery',
          },
          SetOptions(merge: true),
        );
        logger?.info(
          'FirestoreService: Queued recovery activity_log event '
              'store=$storeId id=$activityId operation=line_delete',
        );
      }
    }

    try {
      logger?.info(
        'FirestoreService: Deleting purchase batch store=$storeId rows=${purchaseIds.length}',
      );
      await batch.commit();
      _requireSameUser(userId);
      logger?.info(
        'FirestoreService: Purchase delete batch committed store=$storeId rows=${purchaseIds.length}',
      );
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Purchase delete batch failed store=$storeId rows=${purchaseIds.length}',
        '$e\n$st',
      );
      rethrow;
    }
  }

  dynamic _normalizeFirestoreValue(dynamic value) {
    if (value is Timestamp) return value.toDate().toUtc().toIso8601String();
    if (value is Map) {
      return value.map(
            (key, nested) => MapEntry(key.toString(), _normalizeFirestoreValue(nested)),
      );
    }
    if (value is List) return value.map(_normalizeFirestoreValue).toList();
    return value;
  }

  Map<String, dynamic> _preparePurchaseForFirestore(
      Map<String, dynamic> purchase,
      ) {
    final data = Map<String, dynamic>.from(purchase);

    // Local sync/recovery metadata must never become authoritative cloud data.
    data.remove('syncStatus');
    data.remove('syncedAt');
    data.remove('postRecoveryConflict');

    // Firestore rejects empty field names. Keep the local row untouched and
    // sanitize only the copy crossing the Firestore boundary.
    data.removeWhere((key, _) => key.trim().isEmpty);
    return data;
  }

  // ===========================================================================
  // MASTER DATA
  // ===========================================================================

  /// Fetches master products once
  Future<List<Map<String, dynamic>>> getMasterProducts() async {
    _requireSignedIn();
    try {
      final snapshot = await _db.collection('master_data').doc('products').collection('items').get();
      return snapshot.docs.map((doc) => doc.data()).toList();
    } catch (e) {
      logger?.error('FirestoreService: Fetch master products failed', e);
      return [];
    }
  }
}



class InvoiceDelta {
  final List<Map<String, dynamic>> upserts;
  final List<String> deletedIds;
  final DateTime? upsertCursor;
  final DateTime? deleteCursor;

  const InvoiceDelta({
    required this.upserts,
    required this.deletedIds,
    required this.upsertCursor,
    required this.deleteCursor,
  });
}

class PurchaseDelta {
  final List<Map<String, dynamic>> upserts;
  final List<String> deletedIds;
  final DateTime? upsertCursor;
  final DateTime? deleteCursor;

  const PurchaseDelta({
    required this.upserts,
    required this.deletedIds,
    required this.upsertCursor,
    required this.deleteCursor,
  });
}
