import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:counting_app/services/grv_import_service.dart';
import 'package:counting_app/services/grv_parser.dart';
import 'package:counting_app/services/offline_storage.dart';
import 'package:counting_app/services/sync_service.dart';
import 'package:counting_app/services/google_sheets_service.dart';

const fixturePath = 'integration_test/fixtures/105.csv';
const sampleStoreId = '1c9O_bUJ9wjg-hfgBJH5oLzElV5-YABpFWg_C2NcuCjU';
const sampleStoreFirestoreKey = 'Sample_Store_1c9O_bUJ';
const masterScriptUrl =
    'https://script.google.com/macros/s/'
    'AKfycbzivx7e8lSDAHiYeGAtlcueRjb0CbtTINyEnX5yVmCrUN-r_t3pwhGXvAeee8pLGHI/exec';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OfflineStorage storage;
  late GoogleSheetsService googleSheets;
  late SyncService syncService;

  setUpAll(() async {
    await Hive.initFlutter();

    storage = OfflineStorage();
    googleSheets = GoogleSheetsService(
      masterScriptUrl: masterScriptUrl,
      storeIdentifier: sampleStoreId,
    );

    // Match StoreManager.setActiveStore() ordering: inject the Sheets service
    // before opening the Sample Store Hive boxes.
    storage.setGoogleSheetsService(googleSheets, sampleStoreId);
    await storage.switchStore(
      sampleStoreId,
      firestoreKey: sampleStoreFirestoreKey,
    );

    expect(storage.isReady, isTrue);

    // Use the same awaited master-refresh path as the production app. This
    // populates the reference tables GrvImportService needs before preflight.
    syncService = SyncService(
      offlineStorage: storage,
      googleSheets: googleSheets,
    );

    final refresh = await syncService.refreshMasterData(
      forceFullDownload: false,
      useVersionChecks: false,
    );

    print('');
    print('Master refresh result: ${refresh.message}');
    print('');

    final inventory = await storage.getAllInventory();
    final suppliers = await storage.getMasterSuppliersCached();
    final costs = await storage.getMasterCosts();
    final itemsIssued = await storage.getItemsIssued();
    final stockIssues = await storage.getStockIssues();
    final itemsIssuedMap = await storage.getItemsIssuedMap();

    print('');
    print('=============== PREFLIGHT DATA READY ===============');
    print('Inventory      : ${inventory.length}');
    print('Suppliers      : ${suppliers.length}');
    print('Master costs   : ${costs.length}');
    print('ItemsIssued    : ${itemsIssued.length}');
    print('StockIssues    : ${stockIssues.length}');
    print('ItemsIssuedMap : ${itemsIssuedMap.length}');
    print('====================================================');
    print('');

    expect(inventory, isNotEmpty, reason: 'Inventory did not load.');
    expect(suppliers, isNotEmpty, reason: 'MasterSuppliers did not load.');
  });

  tearDownAll(() {
    syncService.dispose();
    googleSheets.dispose();
    storage.dispose();
  });

  test('GRV 105 read-only production preflight', () async {
    final file = File(fixturePath);
    expect(
      await file.exists(),
      isTrue,
      reason: 'Fixture not found at $fixturePath',
    );

    final beforePending = await storage.getDetailedPendingCounts();

    final csv = await file.readAsString();
    final grv = GrvParser().parse(csv);

    expect(grv.grvReference.trim(), '105');
    expect(grv.invoiceNumber.trim(), '101#094154');
    expect(grv.deliveryDate.year, 2026);
    expect(grv.deliveryDate.month, 9);
    expect(grv.deliveryDate.day, 27);
    expect(
      grv.lineItems.length,
      19,
      reason: '105.csv should currently parse to 19 purchase lines.',
    );

    final service = GrvImportService(storage: storage);
    final result = await service.preflight(grv);

    print('');
    print('================ GRV 105 PREFLIGHT ================');
    print('Supplier in CSV : ${result.sourceSupplierName}');
    print('Supplier ID     : ${result.supplierId ?? 'UNRESOLVED'}');
    print('Canonical name  : ${result.canonicalSupplierName}');
    print('Invoice         : ${result.invoiceNumber}');
    print('GRV             : ${result.grvReference}');
    print(
      'Delivery date   : '
          '${result.deliveryDate.toIso8601String().split('T').first}',
    );
    print('Duplicate       : ${result.isDuplicate ? 'YES' : 'NO'}');
    if (result.isDuplicate) {
      print(
        'Existing ID     : '
            '${result.duplicateInvoice?['invoiceDetailsID'] ?? '(not supplied)'}',
      );
    }
    print('Lines           : ${result.lines.length}');
    print('Matched         : ${result.deterministicMatches}');
    print('Needs resolution: ${result.needsUserResolution}');
    print('---------------------------------------------------');

    for (final line in result.lines) {
      final status = line.isMatched ? 'MATCHED' : 'UNRESOLVED';
      final candidates = line.fuzzyCandidates
          .take(3)
          .map(
            (p) =>
        p['Inventory Product Name']?.toString() ?? '(unnamed product)',
      )
          .join(' | ');

      print(
        '${(line.index + 1).toString().padLeft(2, '0')} '
            '[$status] '
            'PLU=${line.plu.isEmpty ? '(none)' : line.plu} '
            '"${line.description}"'
            '${line.productName == null ? '' : ' -> "${line.productName}"'}'
            '${line.matchedBy == null ? '' : ' via ${line.matchedBy}'}'
            '${line.supplierBottleId == null ? '' : ' supplierBottleID=${line.supplierBottleId}'}',
      );

      if (!line.isMatched && candidates.isNotEmpty) {
        print('   suggestions: $candidates');
      }
    }

    print('===================================================');
    print('');

    // Diagnostic assertions: parsing and the preflight itself must work.
    // A duplicate is a valid result, and unresolved PLUs are valid diagnostic
    // findings, so neither condition fails this read-only test.
    expect(result.lines.length, 19);

    // Guard the non-destructive promise. GrvImportService.preflight() must not
    // create pending invoices, purchases, mappings or counts.
    final afterPending = await storage.getDetailedPendingCounts();
    expect(
      afterPending,
      beforePending,
      reason: 'Read-only GRV preflight changed pending local records.',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
