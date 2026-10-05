import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:counting_app/firebase_options.dart';
import 'package:counting_app/services/firestore_service.dart';
import 'package:counting_app/services/grv_parser.dart';
import 'package:counting_app/services/offline_storage.dart';

/// Destructive integration test, isolated to TEST_PURCHASE_105_* records.
///
/// It validates the Purchases lifecycle using the production storage primitives:
/// CSV parse -> Hive pending -> Firestore create -> local acknowledgement
/// -> Hive edit/pending -> Firestore update -> acknowledgement
/// -> Hive soft-delete -> Firestore delete -> local hard-delete acknowledgement.
///
/// Existing production purchases are never modified. Cleanup deletes only IDs
/// created by this test run.
///
/// Fixture:
///   integration_test/fixtures/105.csv
///
/// Run:
///   flutter test integration_test/purchases_crud_integration_test.dart -d windows -r expanded
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const firestoreStoreKey = 'Sample_Store_1c9O_bUJ';
  const fixturePath = 'integration_test/fixtures/105.csv';

  late FirestoreService firestore;
  late OfflineStorage storage;

  setUpAll(() async {
    // The normal app initializes Hive before OfflineStorage is used. An
    // integration test starts outside main(), so it must do that bootstrap
    // explicitly before OfflineStorage.switchStore() opens encrypted boxes.
    await Hive.initFlutter();

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    firestore = FirestoreService();

    if (firestore.currentUserId == null) {
      fail(
        'FirebaseAuth has no signed-in user. Log into the normal Windows app '
            'first, close it, then run this integration test.',
      );
    }
  });

  test(
    'CSV -> local pending -> Firestore create/update/delete -> local acknowledgement',
        () async {
      final fixture = File(fixturePath);
      expect(
        await fixture.exists(),
        isTrue,
        reason: 'Missing fixture: $fixturePath',
      );

      final csv = await fixture.readAsString();
      final grv = GrvParser().parse(csv);

      // Hard checks against the supplied 105.csv fixture.
      expect(grv.grvReference.trim(), '105');
      expect(grv.invoiceNumber.trim(), '101#094154');
      expect(grv.deliveryDate.year, 2026);
      expect(grv.deliveryDate.month, 9);
      expect(grv.deliveryDate.day, 27);
      expect(grv.lineItems.length, 19);

      final runId = DateTime.now().microsecondsSinceEpoch.toString();
      final prefix = 'TEST_PURCHASE_105_$runId';
      final localStoreId = 'PURCHASE_CRUD_TEST_$runId';
      final invoiceId = 'TEST_INVOICE_105_$runId';

      storage = OfflineStorage();

      final createdIds = <String>[];

      Future<DocumentSnapshot<Map<String, dynamic>>> remoteDoc(
          String id,
          ) {
        return FirebaseFirestore.instance
            .collection('stores')
            .doc(firestoreStoreKey)
            .collection('purchases')
            .doc(id)
            .get(const GetOptions(source: Source.server));
      }

      try {
        // Use a unique Hive store namespace so the test cannot overwrite the
        // user's normal local Sample Store cache.
        await storage.switchStore(
          localStoreId,
          firestoreKey: firestoreStoreKey,
        );

        stdout.writeln('');
        stdout.writeln('============================================================');
        stdout.writeln('PURCHASES CRUD INTEGRATION TEST');
        stdout.writeln('Firestore store : $firestoreStoreKey');
        stdout.writeln('Local test store: $localStoreId');
        stdout.writeln('CSV GRV          : ${grv.grvReference}');
        stdout.writeln('CSV invoice      : ${grv.invoiceNumber}');
        stdout.writeln('CSV line items   : ${grv.lineItems.length}');
        stdout.writeln('Test prefix      : $prefix');
        stdout.writeln('============================================================');

        // ------------------------------------------------------------------
        // 1. CREATE LOCALLY
        // ------------------------------------------------------------------
        final purchases = <Map<String, dynamic>>[];

        for (var i = 0; i < grv.lineItems.length; i++) {
          final item = grv.lineItems[i];
          final id = '${prefix}_line${i.toString().padLeft(2, '0')}';
          createdIds.add(id);

          final bottles =
          (item.quantityCases * item.unitsPerCase).toDouble();
          final cost = item.pricePerUnit * bottles;

          final purchase = <String, dynamic>{
            'Date': grv.deliveryDate.toIso8601String(),
            'purchases_ID': id,
            'Invoice Nr.': grv.invoiceNumber,
            'invoiceDetailsID': invoiceId,
            'GRV Reference': grv.grvReference,
            'supplierID': 'TEST_SUPPLIER',
            'Supplier': grv.supplierName,
            'Barcode': item.barcode ?? '',
            'Purchased Product Name': item.description,
            'purSupplierBottleID': item.plu,
            'Cost Per Bottle': item.pricePerUnit,
            'Inv. Date of Purchase': grv.deliveryDate.toIso8601String(),
            'Stock Delivery Date': grv.deliveryDate.toIso8601String(),
            'Case/Pack Size': 'Case ${item.unitsPerCase}',
            'Qty Purchased': item.quantityCases.toDouble(),
            'Purchases Bottles': bottles,
            'Purchase Units': 0.0,
            'Cost of Purchases': cost,
            'syncStatus': 'pending',
          };

          await storage.savePurchase(purchase);
          purchases.add(purchase);
        }

        final pendingAfterCreate = await storage.getPendingPurchases();
        final ourPendingAfterCreate = pendingAfterCreate
            .where((p) => createdIds.contains(p['purchases_ID']?.toString()))
            .toList();

        expect(ourPendingAfterCreate.length, 19);
        expect(
          ourPendingAfterCreate.every((p) => p['syncStatus'] == 'pending'),
          isTrue,
        );

        stdout.writeln('CREATE local pending : PASS (19/19)');

        // ------------------------------------------------------------------
        // 2. CREATE IN FIRESTORE + ACKNOWLEDGE LOCAL SNAPSHOT
        // Mirrors SyncService's Purchases write/acknowledgement primitives.
        // ------------------------------------------------------------------
        final createSnapshot = storage.capturePostSnapshot(
          'Purchases',
          ourPendingAfterCreate,
        );

        await firestore.savePurchasesBatch(
          firestoreStoreKey,
          ourPendingAfterCreate
              .map((p) => Map<String, dynamic>.from(p))
              .toList(),
        );

        final createAck = await storage.acknowledgePostSnapshot(
          createSnapshot,
          createdIds,
        );

        expect(createAck.toSet(), createdIds.toSet());

        final pendingAfterAck = await storage.getPendingPurchases();
        expect(
          pendingAfterAck.any(
                (p) => createdIds.contains(p['purchases_ID']?.toString()),
          ),
          isFalse,
        );

        // Verify every exact test document exists remotely. These are targeted
        // document reads, not an 8,853-document collection scan.
        for (final id in createdIds) {
          final doc = await remoteDoc(id);
          expect(doc.exists, isTrue, reason: 'Remote create missing: $id');
          expect(doc.id, id);
          expect(doc.data()?['purchases_ID'], id);
          expect(
            doc.data()?.containsKey('syncStatus'),
            isFalse,
            reason: 'Local syncStatus leaked into Firestore for $id',
          );
        }

        stdout.writeln('CREATE Firestore      : PASS (19/19)');
        stdout.writeln('CREATE local ack      : PASS');

        // ------------------------------------------------------------------
        // 3. UPDATE ONE EXISTING PURCHASE
        // ------------------------------------------------------------------
        final editedId = createdIds.first;
        final beforeEdit = await remoteDoc(editedId);
        final originalQty =
        (beforeEdit.data()?['Qty Purchased'] as num).toDouble();
        final editedQty = originalQty + 7.0;
        const editMarker = 'CRUD_TEST_EDITED';

        await storage.updatePurchaseItem(
          editedId,
          <String, dynamic>{
            'Qty Purchased': editedQty,
            'crudTestMarker': editMarker,
          },
        );

        final pendingAfterEdit = await storage.getPendingPurchases();
        final editedPending = pendingAfterEdit.firstWhere(
              (p) => p['purchases_ID']?.toString() == editedId,
        );

        expect(editedPending['syncStatus'], 'pending');
        expect(
          (editedPending['Qty Purchased'] as num).toDouble(),
          editedQty,
        );

        final editSnapshot = storage.capturePostSnapshot(
          'Purchases',
          [editedPending],
        );

        await firestore.savePurchasesBatch(
          firestoreStoreKey,
          [Map<String, dynamic>.from(editedPending)],
        );

        final editAck = await storage.acknowledgePostSnapshot(
          editSnapshot,
          [editedId],
        );
        expect(editAck, [editedId]);

        final remoteEdited = await remoteDoc(editedId);
        expect(remoteEdited.exists, isTrue);
        expect(
          (remoteEdited.data()?['Qty Purchased'] as num).toDouble(),
          editedQty,
        );
        expect(remoteEdited.data()?['crudTestMarker'], editMarker);

        // Same canonical ID means update-in-place, not a duplicate document.
        expect(remoteEdited.id, editedId);

        stdout.writeln('UPDATE pending        : PASS');
        stdout.writeln('UPDATE Firestore      : PASS');
        stdout.writeln('UPDATE same ID        : PASS');

        // ------------------------------------------------------------------
        // 4. DELETE ONE PURCHASE THROUGH TOMBSTONE -> REMOTE -> ACK
        // ------------------------------------------------------------------
        final deletedId = createdIds.last;

        await storage.softDeletePurchase(deletedId);

        final deletedRows = await storage.getDeletedPurchases();
        final deletedPending = deletedRows.firstWhere(
              (p) => p['purchases_ID']?.toString() == deletedId,
        );
        expect(deletedPending['syncStatus'], 'deleted');

        final deleteSnapshot = storage.capturePostSnapshot(
          'Purchases',
          [deletedPending],
          deleting: true,
        );

        await firestore.deletePurchasesBatch(
          firestoreStoreKey,
          [deletedId],
        );

        final deleteAck = await storage.acknowledgePostSnapshot(
          deleteSnapshot,
          [deletedId],
        );
        expect(deleteAck, [deletedId]);

        final remoteDeleted = await remoteDoc(deletedId);
        expect(remoteDeleted.exists, isFalse);

        final stillDeletedLocally = await storage.getDeletedPurchases();
        expect(
          stillDeletedLocally.any(
                (p) => p['purchases_ID']?.toString() == deletedId,
          ),
          isFalse,
        );

        stdout.writeln('DELETE tombstone      : PASS');
        stdout.writeln('DELETE Firestore      : PASS');
        stdout.writeln('DELETE local cleanup  : PASS');

        stdout.writeln('');
        stdout.writeln('==================== RESULT ======================');
        stdout.writeln('PASS: Purchases CRUD lifecycle validated.');
        stdout.writeln('Created : 19 CSV-derived purchases');
        stdout.writeln('Updated : 1 purchase using same purchases_ID');
        stdout.writeln('Deleted : 1 purchase through tombstone + ack');
        stdout.writeln('Cleanup : remaining test records removed in finally');
        stdout.writeln('==================================================');
      } finally {
        // Remote cleanup is intentionally restricted to IDs generated by this
        // test run. Never query/delete by invoice, supplier, or broad prefix.
        final safeIds = createdIds
            .where((id) => id.startsWith('TEST_PURCHASE_105_$runId'))
            .toList();

        if (safeIds.isNotEmpty && firestore.currentUserId != null) {
          try {
            await firestore.deletePurchasesBatch(
              firestoreStoreKey,
              safeIds,
            );
          } catch (e) {
            stderr.writeln(
              'WARNING: Remote cleanup failed for test IDs only: $e',
            );
          }
        }

        for (final id in safeIds) {
          try {
            await storage.hardDeletePurchase(id);
          } catch (_) {
            // Best-effort cleanup. The local store namespace is unique per run.
          }
        }

        stdout.writeln(
          'Cleanup attempted for ${safeIds.length} TEST_PURCHASE_105_* IDs.',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
