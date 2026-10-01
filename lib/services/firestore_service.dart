import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'logger_service.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final LoggerService? logger;

  FirestoreService({this.logger});

  // ===========================================================================
  // AUTHENTICATION
  // ===========================================================================

  Stream<User?> get authStateChanges => FirebaseAuth.instance.authStateChanges();

  Future<UserCredential?> signInWithEmail(String email, String password) async {
    try {
      return await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } catch (e) {
      logger?.error('FirestoreService: Email sign in failed', e);
      rethrow;
    }
  }

  Future<void> signOut() async {
    await FirebaseAuth.instance.signOut();
  }

  String? get currentUserEmail => FirebaseAuth.instance.currentUser?.email;

  Future<void> registerStoreMetadata(String storeId, String storeName) async {
    try {
      await _db.collection('stores').doc(storeId).set({
        'storeName': storeName,
        'storeId': storeId,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      logger?.error('FirestoreService: registerStoreMetadata failed', e);
    }
  }

  // ===========================================================================
  // STOCK COUNTS (Real-time)
  // ===========================================================================

  /// Watches stock counts for a specific store in real-time
  /// Watches stock counts for a specific store in real-time
  /// 🔥 FILTERS OUT DELETED RECORDS
  Stream<List<Map<String, dynamic>>> watchStockCounts(String storeId) {
    return _db
        .collection('stores')
        .doc(storeId)
        .collection('stock_counts')
        .where('deleted', isEqualTo: false)  // 🔥 ONLY GET NON-DELETED
        .orderBy('updated_at', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id; // Ensure ID is included
      return data;
    }).toList());
  }

  /// Saves or updates a stock count document
  Future<void> saveStockCount(String storeId, Map<String, dynamic> count) async {
    final id = count['id'] ?? count['stock_id'];
    if (id == null) {
      logger?.error('FirestoreService: Stock count ID is missing', null);
      throw Exception('Stock count ID is missing');
    }

    try {
      final data = Map<String, dynamic>.from(count);

      // Defensive boundary guard for malformed legacy StockCounts fields.
      // Only the Firestore copy is changed; local/Hive and Sheets data are untouched.
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

      // Preserve the existing fallback behavior unchanged.
      logger?.info(
        'FirestoreService: Falling back to individual stock writes store=$storeId rows=${counts.length}',
      );
      for (final count in counts) {
        await saveStockCount(storeId, count);
      }
    }
  }

  /// Deletes a stock count document
  Future<void> deleteStockCount(String storeId, String id) async {
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
    try {
      final snapshot = await _db.collection('master_data').doc('products').collection('items').get();
      return snapshot.docs.map((doc) => doc.data()).toList();
    } catch (e) {
      logger?.error('FirestoreService: Fetch master products failed', e);
      return [];
    }
  }
}
