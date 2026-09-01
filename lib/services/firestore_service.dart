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

  Future<UserCredential?> signInAnonymously() async {
    try {
      return await FirebaseAuth.instance.signInAnonymously();
    } catch (e) {
      logger?.error('FirestoreService: Anonymous sign in failed', e);
      return null;
    }
  }

  // ===========================================================================
  // STOCK COUNTS (Real-time)
  // ===========================================================================

  /// Watches stock counts for a specific store in real-time
  Stream<List<Map<String, dynamic>>> watchStockCounts(String storeId) {
    return _db
        .collection('stores')
        .doc(storeId)
        .collection('stock_counts')
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
    try {
      final id = count['id'] ?? count['stock_id'];
      if (id == null) throw Exception('Stock count ID is missing');

      // Convert local map to Firestore-friendly format if needed
      final data = Map<String, dynamic>.from(count);
      
      // Ensure timestamps are Firestore Timestamps or ISO strings
      data['updated_at'] = FieldValue.serverTimestamp();
      if (data['created_at'] == null && data['createdAt'] == null) {
        data['created_at'] = FieldValue.serverTimestamp();
      }

      await _db
          .collection('stores')
          .doc(storeId)
          .collection('stock_counts')
          .doc(id)
          .set(data, SetOptions(merge: true));
      
      logger?.info('FirestoreService: Saved stock count $id');
    } catch (e) {
      logger?.error('FirestoreService: Save stock count failed', e);
      rethrow;
    }
  }

  /// ✅ NEW: Batch save stock counts (Up to 500 at once)
  Future<void> saveStockCountsBatch(String storeId, List<Map<String, dynamic>> counts) async {
    if (counts.isEmpty) return;
    
    try {
      final batch = _db.batch();
      final collection = _db.collection('stores').doc(storeId).collection('stock_counts');
      final now = FieldValue.serverTimestamp();

      for (var count in counts) {
        final id = count['id'] ?? count['stock_id'];
        if (id == null) continue;

        final data = Map<String, dynamic>.from(count);
        data['updated_at'] = now;
        if (data['created_at'] == null && data['createdAt'] == null) {
          data['created_at'] = now;
        }

        batch.set(collection.doc(id.toString()), data, SetOptions(merge: true));
      }

      await batch.commit();
      logger?.info('FirestoreService: Batch saved ${counts.length} stock counts');
    } catch (e) {
      logger?.error('FirestoreService: Batch save failed', e);
      // Fallback to individual saves if batch fails (unlikely)
      for (var count in counts) {
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
