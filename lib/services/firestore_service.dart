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
