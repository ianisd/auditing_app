import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:counting_app/firebase_options.dart';
import 'package:counting_app/services/firestore_service.dart';
import 'package:counting_app/services/google_sheets_service.dart';
import 'package:counting_app/services/grv_import_service.dart';
import 'package:counting_app/services/grv_parser.dart';
import 'package:counting_app/services/offline_storage.dart';
import 'package:counting_app/services/sync_service.dart';

const fixturePath = 'integration_test/fixtures/105.csv';
const sampleStoreId = '1c9O_bUJ9wjg-hfgBJH5oLzElV5-YABpFWg_C2NcuCjU';
const sampleStoreFirestoreKey = 'Sample_Store_1c9O_bUJ';
const masterScriptUrl = 'https://script.google.com/macros/s/AKfycbzivx7e8lSDAHiYeGAtlcueRjb0CbtTINyEnX5yVmCrUN-r_t3pwhGXvAeee8pLGHI/exec';

const testInvoiceId = 'T105CRUD';
const testInvoiceNumber = 'TEST-101#094154';
const testGrvReference = 'T105CRUD';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineStorage storage;
  late GoogleSheetsService sheets;
  late FirestoreService firestore;
  late SyncService sync;

  setUpAll(() async {
    await Hive.initFlutter();
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    storage = OfflineStorage();
    sheets = GoogleSheetsService(
      masterScriptUrl: masterScriptUrl,
      storeIdentifier: sampleStoreId,
    );
    firestore = FirestoreService();

    expect(firestore.currentUserId, isNotNull,
        reason: 'Firebase test session is not signed in.');

    storage.setGoogleSheetsService(sheets, sampleStoreId);
    await storage.switchStore(
      sampleStoreId,
      firestoreKey: sampleStoreFirestoreKey,
    );

    sync = SyncService(
      offlineStorage: storage,
      googleSheets: sheets,
      firestore: firestore,
    );

    final refresh = await sync.refreshMasterData(
      forceFullDownload: false,
      useVersionChecks: true,
    );
    print('Master refresh result: ${refresh.message}');

    expect(await storage.getAllInventory(), isNotEmpty);
    expect(await storage.getMasterSuppliersCached(), isNotEmpty);

    // Safety: this live test must not upload unrelated transactional work.
    expect(await storage.getPendingInvoiceDetails(), isEmpty,
        reason: 'Unrelated pending invoices exist.');
    expect(await storage.getPendingPurchases(), isEmpty,
        reason: 'Unrelated pending purchases exist.');
    expect(await storage.getDeletedInvoices(), isEmpty,
        reason: 'Unrelated invoice deletes are pending.');
    expect(await storage.getDeletedPurchases(), isEmpty,
        reason: 'Unrelated purchase deletes are pending.');
    expect(await storage.getInvoiceDetails(testInvoiceId), isNull,
        reason: '$testInvoiceId already exists locally.');
  });

  tearDownAll(() {
    sync.dispose();
    sheets.dispose();
    storage.dispose();
  });

  test('GRV 105 CREATE -> pending -> Firestore synced', () async {
    final f = File(fixturePath);
    expect(await f.exists(), isTrue);

    final grv = GrvParser().parse(await f.readAsString());
    expect(grv.lineItems.length, 19);

    final preflight = await GrvImportService(storage: storage).preflight(grv);
    expect(preflight.supplierId, isNotNull);
    expect(preflight.deterministicMatches, 18);
    expect(preflight.needsUserResolution, 1);

    final unresolved = preflight.lines.where((x) => !x.isMatched).toList();
    expect(unresolved.single.plu, '82');
    expect(unresolved.single.description.toUpperCase(), contains('BLUE BERRY'));

    // Model the production "Remove" choice for the unresolved line. We do not
    // guess or create a BLUE BERRY mapping in this automated test.
    final matched = preflight.lines.where((x) => x.isMatched).toList();
    expect(matched.length, 18);

    final invoice = <String, dynamic>{
      'invoiceDetailsID': testInvoiceId,
      'Invoice Number': testInvoiceNumber,
      'supplierID': preflight.supplierId,
      'Supplier Name': preflight.canonicalSupplierName,
      'GRV Reference': testGrvReference,
      'Date of Purchase': grv.deliveryDate.toIso8601String(),
      'Total Cost Ex Vat': 0.0,
      'syncStatus': 'pending',
    };
    await storage.saveInvoiceDetails(invoice);

    final purchases = <Map<String, dynamic>>[];
    var total = 0.0;

    for (var i = 0; i < matched.length; i++) {
      final line = matched[i];
      final product = await storage.getProductByName(line.productName!);
      expect(product, isNotNull,
          reason: 'Inventory product missing: ${line.productName}');

      final price = line.resolvedPricePerUnit;
      final units = line.quantityCases * line.unitsPerCase;
      final value = units * price;
      total += value;
      final key = line.plu.isNotEmpty ? line.plu : (line.barcode ?? 'unknown');

      purchases.add({
        'purchases_ID':
        'purchase_${testInvoiceId}_${testGrvReference}_${key}_line$i',
        'invoiceDetailsID': testInvoiceId,
        'GRV Reference': testGrvReference,
        'Invoice Nr.': testInvoiceNumber,
        'Inv. Date of Purchase': grv.deliveryDate.toIso8601String(),
        'supplierID': preflight.supplierId,
        'Supplier': preflight.canonicalSupplierName,
        'Barcode': line.barcode ?? product?['Barcode'] ?? '',
        'Purchased Product Name': line.productName!,
        'supplierBottleID': line.supplierBottleId ?? '',
        'purSupplierBottleID': line.supplierBottleId ?? '',
        'plu': line.plu,
        'Main Category': product?['Main Category'] ?? '',
        'Category': product?['Category'] ?? '',
        'Single Unit Volume': product?['Single Unit Volume'] ?? 0,
        'UoM': product?['UoM'] ?? '',
        'Cost Per Bottle': price,
        'Stock Delivery Date': grv.deliveryDate.toIso8601String(),
        'Case/Pack Size': 'Case ${line.unitsPerCase}',
        'Qty Purchased': line.quantityCases.toDouble(),
        'Purchases Bottles': units.toDouble(),
        'Purchase Units': 0,
        'Cost of Purchases': value,
        'syncStatus': 'pending',
      });
    }

    await storage.saveInvoiceDetails({...invoice, 'Total Cost Ex Vat': total});
    await storage.savePurchasesWithMerge(
      invoiceId: testInvoiceId,
      newPurchases: purchases,
    );

    final before = await storage.getPurchasesByInvoiceId(testInvoiceId);
    expect(before.length, 18);
    expect(before.every((p) => p['syncStatus'] == 'pending'), isTrue);

    print('\n================ CREATE LOCAL =================');
    print('Invoice ID      : $testInvoiceId');
    print('Purchases       : ${before.length}');
    print('Removed line    : PLU 82 BLUE BERRY');
    print('Invoice total   : ${total.toStringAsFixed(2)}');
    print('Status          : pending');
    print('================================================\n');

    // Production ordering: invoice header first, then Firestore Purchases.
    final result = await sync.syncAllWithChunking(
      onStatus: (m) => print('SYNC: $m'),
    );

    print('\n================ CREATE SYNC ==================');
    print('Success          : ${result.success}');
    print('Invoices synced  : ${result.invoicesSynced}');
    print('Purchases synced : ${result.purchasesSynced}');
    print('Message          : ${result.message}');
    print('================================================\n');

    expect(result.success, isTrue, reason: result.message);
    expect(result.invoicesSynced, greaterThanOrEqualTo(1));
    expect(result.purchasesSynced, 18);

    final after = await storage.getPurchasesByInvoiceId(testInvoiceId);
    expect(after.length, 18);
    expect(after.every((p) => p['syncStatus'] == 'synced'), isTrue);

    final inv = await storage.getInvoiceDetails(testInvoiceId);
    expect(inv, isNotNull);
    expect(inv!['syncStatus'], 'synced');

    // Public Firestore API currently reads the collection, then we isolate our
    // fixed test invoice.
    final remote = await firestore.getPurchases(sampleStoreFirestoreKey);
    final remoteRows = remote
        .where((p) => p['invoiceDetailsID']?.toString() == testInvoiceId)
        .toList();

    expect(remoteRows.length, 18);
    expect(remoteRows.map((p) => p['purchases_ID']).toSet().length, 18);

    print('\n=============== CREATE VERIFIED ===============');
    print('Local purchases  : ${after.length} synced');
    print('Remote purchases : ${remoteRows.length}');
    print('Fixture retained : YES - for EDIT phase');
    print('================================================\n');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
