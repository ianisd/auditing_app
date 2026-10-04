import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'logger_service.dart';

class FirestoreService {
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final LoggerService? logger;

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
        code: 'unauthenticated',
        message: 'Sign in before accessing Firestore.',
      );
    }
    return uid;
  }

  void _requireSameUser(String uid) {
    if (currentUserId != uid) {
      throw FirebaseAuthException(
        code: 'unauthenticated',
        message: 'The sign-in session changed. Retry after signing in.',
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

  // ===========================================================================
  // STOCK COUNTS (Real-time)
  // ===========================================================================

  /// Watches stock counts for a specific store in real-time
  /// Watches stock counts for a specific store in real-time
  /// 🔥 FILTERS OUT DELETED RECORDS
  Stream<List<Map<String, dynamic>>> watchStockCounts(String storeId) {
    _requireSignedIn();
    return _db
        .collection('stores')
        .doc(storeId)
        .collection('stock_counts')
        .where('deleted', isEqualTo: false) // 🔥 ONLY GET NON-DELETED
        .orderBy('updated_at', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.map((doc) {
            final data = doc.data();
            data['id'] = doc.id; // Ensure ID is included
            return data;
          }).toList(),
        );
  }

  /// Saves or updates a stock count document
  Future<void> saveStockCount(
    String storeId,
    Map<String, dynamic> count,
  ) async {
    _requireSignedIn();
    final id = count['id'] ?? count['stock_id'];
    if (id == null) {
      logger?.error('FirestoreService: Stock count ID is missing', null);
      throw Exception('Stock count ID is missing');
    }

    try {
      final data = Map<String, dynamic>.from(count);

      // Defensive boundary guard for malformed legacy StockCounts fields.
      // Only the Firestore copy is changed; local/Hive and Sheets data are untouched.
      final invalidKeys = data.keys.where((key) => key.trim().isEmpty).toList();
      for (final key in invalidKeys) {
        data.remove(key);
      }
      if (invalidKeys.isNotEmpty) {
        logger?.info(
          '🧹 FirestoreService: Removed ${invalidKeys.length} invalid field name(s) from stock count $id',
        );
      }

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

      logger?.info('FirestoreService: Saved stock count $id');
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Save stock count failed store=$storeId id=$id',
        '$e\n$st',
      );
      rethrow;
    }
  }

  /// Batch save stock counts (up to Firestore's 500-write batch limit).
  Future<void> saveStockCountsBatch(
    String storeId,
    List<Map<String, dynamic>> counts,
  ) async {
    if (counts.isEmpty) return;
    final userId = _requireSignedIn();

    logger?.info(
      'FirestoreService: Saving stock batch store=$storeId rows=${counts.length}',
    );

    try {
      final batch = _db.batch();
      final collection = _db
          .collection('stores')
          .doc(storeId)
          .collection('stock_counts');
      final now = FieldValue.serverTimestamp();
      var queued = 0;

      for (final count in counts) {
        final id = count['id'] ?? count['stock_id'];
        if (id == null) {
          logger?.info(
            '⚠️ FirestoreService: Skipped stock count with missing ID in batch store=$storeId',
          );
          continue;
        }

        final data = Map<String, dynamic>.from(count);

        // Defensive boundary guard for malformed legacy StockCounts fields.
        // This is retained permanently because an empty field name previously
        // caused a native Windows Firestore crash during batch.commit().
        final invalidKeys = data.keys
            .where((key) => key.trim().isEmpty)
            .toList();
        for (final key in invalidKeys) {
          data.remove(key);
        }
        if (invalidKeys.isNotEmpty) {
          logger?.info(
            '🧹 FirestoreService: Removed ${invalidKeys.length} invalid field name(s) from stock count $id',
          );
        }

        data['updated_at'] = now;
        final docRef = collection.doc(id.toString());
        batch.set(docRef, data, SetOptions(merge: true));
        queued++;
      }

      if (queued == 0) {
        logger?.info(
          '⚠️ FirestoreService: No valid stock counts queued for batch store=$storeId',
        );
        return;
      }

      // Keep these two boundary logs: if the native SDK terminates the process
      // during commit, the last emitted line tells us exactly where it stopped.
      logger?.info(
        'FirestoreService: Committing stock batch store=$storeId queued=$queued',
      );
      await batch.commit();
      logger?.info(
        'FirestoreService: Stock batch committed store=$storeId queued=$queued',
      );
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Batch save failed store=$storeId rows=${counts.length}',
        '$e\n$st',
      );

      // Authentication/permission failures cannot be repaired by sending the
      // same denied batch as individual requests.
      _requireSameUser(userId);
      if (e is FirebaseException &&
          (e.code == 'unauthenticated' || e.code == 'permission-denied')) {
        rethrow;
      }

      // Retain the existing per-record fallback for other errors.
      logger?.info(
        'FirestoreService: Falling back to individual stock writes store=$storeId rows=${counts.length}',
      );
      for (final count in counts) {
        _requireSameUser(userId);
        await saveStockCount(storeId, count);
      }
    }
  }

  /// Deletes a stock count document
  Future<void> deleteStockCount(String storeId, String id) async {
    _requireSignedIn();
    try {
      await _db
          .collection('stores')
          .doc(storeId)
          .collection('stock_counts')
          .doc(id)
          .delete();
      logger?.info('FirestoreService: Deleted stock count $id');
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
        .collection('stores')
        .doc(storeId)
        .collection('invoices')
        .get();
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
            .where(
              'updated_at',
              isGreaterThan: Timestamp.fromDate(upsertsSince.toUtc()),
            )
            .orderBy('updated_at');
      } else {
        upsertQuery = upsertQuery
            .orderBy('updated_at', descending: true)
            .limit(1);
      }
      Query<Map<String, dynamic>> deleteQuery = changes;
      if (deletesSince != null) {
        deleteQuery = deleteQuery
            .where(
              'changed_at',
              isGreaterThan: Timestamp.fromDate(deletesSince.toUtc()),
            )
            .orderBy('changed_at');
      } else {
        deleteQuery = deleteQuery
            .orderBy('changed_at', descending: true)
            .limit(1);
      }
      final results = await Future.wait([upsertQuery.get(), deleteQuery.get()]);
      final upserts = <Map<String, dynamic>>[];
      final deletedIds = <String>[];
      DateTime? newestUpsert = upsertsSince;
      DateTime? newestDelete = deletesSince;
      for (final doc in results[0].docs) {
        upserts.add(_invoiceFromDoc(doc));
        final ts = doc.data()['updated_at'];
        if (ts is Timestamp &&
            (newestUpsert == null || ts.toDate().isAfter(newestUpsert))) {
          newestUpsert = ts.toDate().toUtc();
        }
      }
      for (final doc in results[1].docs) {
        final data = doc.data();
        final id = data['invoiceId']?.toString().trim();
        if (id != null && id.isNotEmpty) deletedIds.add(id);
        final ts = data['changed_at'];
        if (ts is Timestamp &&
            (newestDelete == null || ts.toDate().isAfter(newestDelete))) {
          newestDelete = ts.toDate().toUtc();
        }
      }
      logger?.info(
        'FirestoreService: Invoice delta store=$storeId upserts=${upserts.length} deletes=${deletedIds.length}',
      );
      return InvoiceDelta(
        upserts: upserts,
        deletedIds: deletedIds,
        upsertCursor: newestUpsert,
        deleteCursor: newestDelete,
      );
    } catch (e, st) {
      logger?.error(
        'FirestoreService: Invoice delta failed store=$storeId',
        '$e\n$st',
      );
      rethrow;
    }
  }

  Map<String, dynamic> _invoiceFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final normalized = _normalizeFirestoreValue(doc.data());
    final data = Map<String, dynamic>.from(normalized as Map<String, dynamic>);
    data['invoiceDetailsID'] = doc.id;
    data['syncStatus'] = 'synced';
    return data;
  }

  Map<String, dynamic> _prepareInvoiceForFirestore(
    Map<String, dynamic> invoice,
  ) {
    final data = Map<String, dynamic>.from(invoice);
    data.remove('syncStatus');
    data.remove('syncedAt');
    data.remove('postRecoveryConflict');
    data.removeWhere((key, _) => key.trim().isEmpty);
    return data;
  }

  Future<void> saveInvoicesBatch(
    String storeId,
    List<Map<String, dynamic>> invoices,
  ) async {
    if (invoices.isEmpty) return;
    if (invoices.length > 250) {
      throw ArgumentError.value(
        invoices.length,
        'invoices',
        'Each Invoice uses two Firestore writes; batches support at most 250 Invoices.',
      );
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
      if (id == null || id.isEmpty)
        throw StateError('Invoice invoiceDetailsID is missing');
      final data = _prepareInvoiceForFirestore(invoice);
      data['updated_at'] = now;
      batch.set(collection.doc(id), data, SetOptions(merge: true));
      batch.delete(changeLog.doc(id));
      queued++;
    }
    logger?.info(
      'FirestoreService: Committing invoice batch store=$storeId queued=$queued',
    );
    await batch.commit();
    _requireSameUser(userId);
    logger?.info(
      'FirestoreService: Invoice batch committed store=$storeId queued=$queued',
    );
  }

  Future<void> deleteInvoicesBatch(
    String storeId,
    List<String> invoiceIds,
  ) async {
    final ids = invoiceIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return;
    if (ids.length > 250)
      throw ArgumentError.value(
        ids.length,
        'invoiceIds',
        'Each Invoice delete uses two Firestore writes; batches support at most 250 Invoices.',
      );
    final userId = _requireSignedIn();
    final batch = _db.batch();
    final storeRef = _db.collection('stores').doc(storeId);
    final collection = storeRef.collection('invoices');
    final changeLog = storeRef.collection('invoice_changes');
    final now = FieldValue.serverTimestamp();
    for (final id in ids) {
      _requireSameUser(userId);
      batch.delete(collection.doc(id));
      batch.set(changeLog.doc(id), {
        'invoiceId': id,
        'operation': 'delete',
        'changed_at': now,
      });
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
            .where(
              'updated_at',
              isGreaterThan: Timestamp.fromDate(upsertsSince.toUtc()),
            )
            .orderBy('updated_at');
      } else {
        // Existing Hive data is already the bootstrap snapshot. One read finds
        // the newest Firestore write and establishes the incremental cursor.
        upsertQuery = upsertQuery
            .orderBy('updated_at', descending: true)
            .limit(1);
      }

      Query<Map<String, dynamic>> deleteQuery = changes;
      if (deletesSince != null) {
        deleteQuery = deleteQuery
            .where(
              'changed_at',
              isGreaterThan: Timestamp.fromDate(deletesSince.toUtc()),
            )
            .orderBy('changed_at');
      } else {
        // purchase_changes starts with this feature. Reading the newest event is
        // enough to seed a cursor without scanning historical Purchases.
        deleteQuery = deleteQuery
            .orderBy('changed_at', descending: true)
            .limit(1);
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
    List<String> purchaseIds,
  ) async {
    if (purchaseIds.isEmpty) return;
    if (purchaseIds.length > 250) {
      throw ArgumentError.value(
        purchaseIds.length,
        'purchaseIds',
        'Each Purchase delete uses two Firestore writes; batches support at most 250 Purchases.',
      );
    }

    final userId = _requireSignedIn();
    final batch = _db.batch();
    final storeRef = _db.collection('stores').doc(storeId);
    final collection = storeRef.collection('purchases');
    final changeLog = storeRef.collection('purchase_changes');
    final now = FieldValue.serverTimestamp();

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
        (key, nested) =>
            MapEntry(key.toString(), _normalizeFirestoreValue(nested)),
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
      final snapshot = await _db
          .collection('master_data')
          .doc('products')
          .collection('items')
          .get();
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
