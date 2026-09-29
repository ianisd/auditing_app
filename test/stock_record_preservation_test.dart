import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import '../lib/services/offline_storage.dart';
import '../lib/services/stock_record_fields.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory directory;
  late OfflineStorage storage;
  Map<String, dynamic> original() => {
    'stockTake_ID': '6d421d29',
    'Date': '2026-01-08',
    'Barcode': '6002039005579',
    'Product Name': 'Fat Bastard Chardonnay',
    'Main Category': 'Wine/Champagne/Sparkling Wine',
    'Category': 'White Wine',
    ' Single Unit Volume': 750,
    'UoM': 'ml',
    'Gradient': 0,
    'Intercept': 0,
    'Volume (ml)': 0,
    'Location': 'Office',
    'Case/Pack Size': 'Case 1',
    'Count': 1,
    'Weight (g)': 0,
    'Open Tots': 0,
    'Total Bottles on Hand': 1,
    'Total Shots/25ml': 1,
    'Total mL': 750,
    'Cost Value': 93.33,
    'Retail Value': 280,
    'created_at': '2026-01-08T12:13:17',
    'updated_at': '2026-01-08T12:13:20',
    'customNote': 'retain me',
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'stock-record-preservation-',
    );
    Hive.init(directory.path);
    storage = OfflineStorage();
    await storage.switchStore('isolated-preservation-test');
  });
  tearDown(() async {
    await Hive.close();
    storage.dispose();
    await Future<void>.delayed(Duration.zero);
    await directory.delete(recursive: true);
  });
  test(
    'full sheet import preserves all 23 fields including padded headers',
    () async {
      await storage.overwriteLocalCounts([original()]);
      final saved = (await storage.getStockCounts()).single;
      for (final e in normalizeStockRecord(original()).entries) {
        expect(saved[e.key], e.value, reason: e.key);
      }
    },
  );
  test('full live snapshot retains all metadata and calculations', () async {
    await storage.saveRemoteStockCounts([normalizeStockRecord(original())]);
    final saved = (await storage.getStockCounts()).single;
    for (final e in normalizeStockRecord(original()).entries) {
      expect(saved[e.key], e.value, reason: e.key);
    }
  });
  test(
    'partial live snapshot and partial local edit preserve omitted fields',
    () async {
      await storage.overwriteLocalCounts([original()]);
      await storage.saveRemoteStockCounts([
        {'id': '6d421d29', 'count': 2},
      ]);
      await storage.updateStockCount({'id': '6d421d29', 'count': 3});
      final row = (await storage.getStockCounts()).single;
      expect(row['singleUnitVolume'], 750);
      expect(row['cost_value'], 93.33);
      expect(row['customNote'], 'retain me');
      expect(row['count'], 3);
      expect(row['syncStatus'], 'pending');
      // Merge preserves fields; the editor owns recalculating dependent totals.
    },
  );
  test('pending local edit still wins over a live callback', () async {
    await storage.overwriteLocalCounts([original()]);
    await storage.updateStockCount({'id': '6d421d29', 'count': 2});
    await storage.saveRemoteStockCounts([
      {'id': '6d421d29', 'count': 9},
    ]);
    expect((await storage.getStockCounts()).single['count'], 2);
  });
  test(
    'imported product has usable snapshot metadata without inventory match',
    () {
      final product = stockProductForEdit(original(), {});
      expect(product['Single Unit Volume'], 750);
      expect(product['Category'], 'White Wine');
      final unitCost = stockRecordedUnitValue(original(), 'cost_value')!;
      final unitRetail = stockRecordedUnitValue(original(), 'retail_value')!;
      validateStockEdit(original(), product, unitCost, unitRetail);
      expect(unitCost * 2, closeTo(186.66, 0.00001));
      expect(unitRetail * 2, 560);
    },
  );
  test('damaged size and missing valuation fail closed', () {
    final damaged = normalizeStockRecord(original())..['singleUnitVolume'] = 0;
    expect(
      () => validateStockEdit(damaged, stockProductForEdit(damaged, {}), 0, 0),
      throwsStateError,
    );
    final noPrice = normalizeStockRecord(original())
      ..remove('cost_value')
      ..remove('retail_value');
    expect(
      () => validateStockEdit(noPrice, stockProductForEdit(noPrice, {}), 0, 0),
      throwsStateError,
    );
  });
  test('zero is explicit, null or absence is not a manufactured zero', () {
    final merged = mergeStockRecord(normalizeStockRecord(original()), {
      'count': 0,
      'uom': null,
    });
    expect(merged['count'], 0);
    expect(merged['uom'], 'ml');
    expect(normalizeStockRecord({'id': 'x'}).containsKey('cost_value'), false);
  });
  test('preserved metadata survives encrypted close and reopen', () async {
    await storage.overwriteLocalCounts([original()]);
    await Hive.close();
    storage.dispose();
    await Future<void>.delayed(Duration.zero);
    storage = OfflineStorage();
    await storage.switchStore('isolated-preservation-test');
    final row = (await storage.getStockCounts()).single;
    expect(row['singleUnitVolume'], 750);
    expect(row['cost_value'], 93.33);
    expect(row['retail_value'], 280);
    expect(row['customNote'], 'retain me');
  });
}
