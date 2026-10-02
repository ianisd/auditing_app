import '../services/logger_service.dart';

import 'dart:async';
import 'dart:isolate';

// 🔥 Runs variance report with true cancellation support
Future<Map<String, dynamic>> runVarianceReportWithCancellation(
  Map<String, dynamic> params, {
  required Duration timeout,
}) async {
  final resultPort = ReceivePort();
  final errorPort = ReceivePort();
  final completer = Completer<Map<String, dynamic>>();
  Isolate? isolate;

  final resultSub = resultPort.listen((message) {
    if (!completer.isCompleted) {
      completer.complete(message as Map<String, dynamic>);
    }
  });

  final errorSub = errorPort.listen((errorData) {
    if (!completer.isCompleted) {
      final errorList = errorData as List;
      completer.completeError(
        Exception('Isolate error: ${errorList[0]}'),
        StackTrace.fromString(errorList[1]?.toString() ?? ''),
      );
    }
  });

  try {
    isolate = await Isolate.spawn(
      _varianceIsolateEntryPoint,
      {'sendPort': resultPort.sendPort, 'params': params},
      onError: errorPort.sendPort,
      errorsAreFatal: true,
      debugName: 'varianceReport',
    );

    return await completer.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException(
          'Report calculation timed out after ${timeout.inSeconds}s',
        );
      },
    );
  } finally {
    resultSub.cancel();
    errorSub.cancel();
    resultPort.close();
    errorPort.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

@pragma('vm:entry-point')
void _varianceIsolateEntryPoint(Map<String, dynamic> message) {
  final sendPort = message['sendPort'] as SendPort;
  final params = message['params'] as Map<String, dynamic>;

  final service = VarianceService.isolate();
  final result = service.calculateReportWithDiagnostics(
    stocks: params['stocks'],
    purchases: params['purchases'],
    itemsIssuedMap: params['itemsIssuedMap'] ?? [],
    stockIssues: params['stockIssues'] ?? [],
    storeSalesData: params['storeSalesData'],
    itemSalesMap: params['itemSalesMap'],
    inventory: params['inventory'],
    dateFromStr: params['dateFromStr'],
    dateToStr: params['dateToStr'],
  );

  sendPort.send(result);
}

@pragma('vm:entry-point')
Map<String, dynamic> calculateReportIsolate(Map<String, dynamic> params) {
  final service = VarianceService.isolate();

  return service.calculateReportWithDiagnostics(
    stocks: params['stocks'],
    purchases: params['purchases'],
    itemsIssuedMap: params['itemsIssuedMap'] ?? [],
    stockIssues: params['stockIssues'] ?? [],
    storeSalesData: params['storeSalesData'],
    itemSalesMap: params['itemSalesMap'],
    inventory: params['inventory'],
    dateFromStr: params['dateFromStr'],
    dateToStr: params['dateToStr'],
  );
}

class VarianceItem {
  final String productName;
  final String mainCategory;
  final String category;

  final double previousCount;
  final double purchases;
  final double issues;
  final double sales;
  final double currentCount;

  final double costPrice;
  final double retailPrice;

  final List<Map<String, dynamic>> allEntries;
  final Map<String, dynamic>? inventoryItem;

  VarianceItem({
    required this.productName,
    required this.mainCategory,
    required this.category,
    required this.previousCount,
    required this.purchases,
    required this.issues,
    required this.sales,
    required this.currentCount,
    required this.costPrice,
    required this.retailPrice,
    this.allEntries = const [],
    this.inventoryItem,
  });

  double get theoreticalStock => previousCount + purchases + issues - sales;
  double get variance => currentCount - theoreticalStock;

  double get varianceCost => variance * costPrice;
  double get varianceRetail => variance * retailPrice;
  double get totalStockValueRetail => currentCount * retailPrice;

  Map<String, dynamic> toJson() => {
    'productName': productName,
    'mainCategory': mainCategory,
    'category': category,
    'previousCount': previousCount,
    'purchases': purchases,
    'issues': issues,
    'sales': sales,
    'currentCount': currentCount,
    'costPrice': costPrice,
    'retailPrice': retailPrice,
    'allEntries': allEntries,
    'inventoryItem': inventoryItem,
  };

  factory VarianceItem.fromJson(Map<String, dynamic> json) => VarianceItem(
    productName: json['productName'],
    mainCategory: json['mainCategory'],
    category: json['category'],
    previousCount: json['previousCount'],
    purchases: json['purchases'],
    issues: json['issues'] ?? 0,
    sales: json['sales'],
    currentCount: json['currentCount'],
    costPrice: json['costPrice'],
    retailPrice: json['retailPrice'],
    allEntries: List<Map<String, dynamic>>.from(json['allEntries'] ?? []),
    inventoryItem: json['inventoryItem'] as Map<String, dynamic>?,
  );
}

class VarianceService {
  final LoggerService? logger;

  VarianceService({this.logger});

  VarianceService.isolate() : logger = null;

  final RegExp _exclusionRegex = RegExp(
    r'Special Shooter|Special Beverage|Cocktail Ingredient|Special Tot|Special Spirit Bottle|Special Alcoholic Beverage',
    caseSensitive: false,
  );

  static const double _estimatedMarkup = 3.0;

  String _normalize(dynamic input) {
    if (input == null) return '';
    return input.toString().toLowerCase().trim();
  }

  double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return double.tryParse(value.toString()) ?? 0.0;
  }

  DateTime _stripTime(DateTime dt) {
    return DateTime(dt.year, dt.month, dt.day);
  }

  bool _fuzzyMatch(String a, String b) {
    final aNorm = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '');
    final bNorm = b.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '');

    if (aNorm.contains(bNorm) || bNorm.contains(aNorm)) return true;

    final aWords = aNorm.split(RegExp(r'\s+'));
    final bWords = bNorm.split(RegExp(r'\s+'));

    int matches = 0;
    for (var aWord in aWords) {
      if (aWord.length < 3) continue;
      for (var bWord in bWords) {
        if (bWord.length < 3) continue;
        if (aWord == bWord || aWord.contains(bWord) || bWord.contains(aWord)) {
          matches++;
          break;
        }
      }
    }

    return matches >= (aWords.length / 2).ceil();
  }

  Map<String, dynamic> calculateReportWithDiagnostics({
    required List<Map<String, dynamic>> stocks,
    required List<Map<String, dynamic>> purchases,
    required List<Map<String, dynamic>> itemsIssuedMap,
    required List<Map<String, dynamic>> stockIssues,
    required List<Map<String, dynamic>> storeSalesData,
    required List<Map<String, dynamic>> itemSalesMap,
    required List<Map<String, dynamic>> inventory,
    required String dateFromStr,
    required String dateToStr,
  }) {
    print('🔍 ===== VARIANCE REPORT START =====');
    print('📊 Input Data Counts:');
    print('  - stocks: ${stocks.length}');
    print('  - purchases: ${purchases.length}');
    print('  - itemsIssuedMap: ${itemsIssuedMap.length}');
    print('  - stockIssues: ${stockIssues.length}');
    print('  - storeSalesData: ${storeSalesData.length}');
    print('  - itemSalesMap: ${itemSalesMap.length}');
    print('  - inventory: ${inventory.length}');
    print('  - dateFrom: $dateFromStr');
    print('  - dateTo: $dateToStr');
    print('');

    final fromDtRaw = DateTime.parse(dateFromStr);
    final toDtRaw = DateTime.parse(dateToStr);

    final fromDate = _stripTime(fromDtRaw);
    final toDate = _stripTime(toDtRaw);

    print(
      '🔍 DATE RANGE: from=${fromDate.toIso8601String()}, to=${toDate.toIso8601String()}',
    );
    print('');

    final diagnostics = {
      'stocksCount': stocks.length,
      'purchasesCount': purchases.length,
      'storeSalesCount': storeSalesData.length,
      'itemSalesMapCount': itemSalesMap.length,
      'inventoryCount': inventory.length,
      'itemsIssuedMapCount': itemsIssuedMap.length,
      'stockIssuesCount': stockIssues.length,
      'dateFrom': dateFromStr,
      'dateTo': dateToStr,
      'sampleDates': <String>[],
      'ambiguousPluCollisions': 0,
      'salesInRange': 0,
      'issuesInRange': 0,
      'productsWithVariance': 0,
      'parsingErrors': 0,
    };

    Map<String, double> prodCosts = {};
    Map<String, double> prodRetail = {};
    Map<String, String> prodMainCat = {};
    Map<String, String> prodCat = {};
    Map<String, Map<String, dynamic>> inventoryRef = {};

    // 1. Inventory Map
    print('📦 Building Inventory Reference...');
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      inventoryRef[name] = item;
      prodCosts[name] = _safeDouble(item['Cost Price']);
      prodMainCat[name] = item['Main Category']?.toString() ?? 'Uncategorized';
      prodCat[name] = item['Category']?.toString() ?? 'General';
    }
    print('  - ${inventoryRef.length} unique products in inventory');
    print('');

    // ============================================================================
    // 2. SALES MAPPING (ItemSalesMap) - FOR SALES ONLY
    // ============================================================================
    print('📦 Building ItemSalesMap lookup (SALES ONLY)...');

    // Build PLU → List of recipes from ItemSalesMap
    Map<String, List<Map<String, dynamic>>> pluToRecipes = {};

    for (var row in itemSalesMap) {
      final plu = row['PLU']?.toString().trim();
      if (plu != null && plu.isNotEmpty) {
        if (!pluToRecipes.containsKey(plu)) {
          pluToRecipes[plu] = [];
        }
        pluToRecipes[plu]!.add(row);
      }

      // Calculate retail prices from ItemSalesMap
      final name = _normalize(row['Product']);
      final sellPrice = _safeDouble(row['Sell']);

      if (sellPrice > 0) {
        final mainCat = row['Main Category']?.toString() ?? '';
        if (_exclusionRegex.hasMatch(mainCat)) continue;

        final measure = row['Measure']?.toString().toLowerCase() ?? '';
        double impliedBottlePrice = 0.0;
        final invItem = inventoryRef[name];

        double bottleUoM = 30.0;
        double singleUoM = 1.0;
        double volumeMl = 750.0;

        if (invItem != null) {
          bottleUoM = _safeDouble(invItem['Bottle UoM']);
          singleUoM = _safeDouble(invItem['Single UoM']);
          volumeMl = _safeDouble(invItem['Single Unit Volume']);

          if (bottleUoM == 0) bottleUoM = 30.0;
          if (singleUoM == 0) singleUoM = 1.0;
          if (volumeMl == 0) volumeMl = 750.0;
        }

        if (measure.contains('bottle') || measure.contains('can')) {
          impliedBottlePrice = sellPrice;
        } else if (measure == 'shots' || measure.contains('tot')) {
          impliedBottlePrice = sellPrice * bottleUoM;
        } else if (measure == 'glass') {
          impliedBottlePrice = sellPrice * singleUoM;
        } else if (measure == 'ml') {
          impliedBottlePrice = sellPrice * 30.0;
        } else {
          impliedBottlePrice = sellPrice;
        }

        if (impliedBottlePrice > (prodRetail[name] ?? 0)) {
          prodRetail[name] = impliedBottlePrice;
        }
      }
    }
    print('  - ${pluToRecipes.length} PLU entries in ItemSalesMap');
    print('');

    // ============================================================================
    // 3. ISSUES MAPPING (ItemsIssuedMap) - FOR ISSUES ONLY
    // ============================================================================
    print('📦 Building ItemsIssuedMap lookup (ISSUES ONLY)...');

    // Build PLU → Product name for fast issues lookup
    Map<String, String> pluToProductMap = {};
    Map<String, List<Map<String, dynamic>>> pluToIssuedMappings = {};

    for (var row in itemsIssuedMap) {
      final plu = row['PLU']?.toString().trim();
      if (plu != null && plu.isNotEmpty) {
        if (!pluToIssuedMappings.containsKey(plu)) {
          pluToIssuedMappings[plu] = [];
        }
        pluToIssuedMappings[plu]!.add(row);

        final product =
            row['Product']?.toString().trim() ??
            row['Menu Item']?.toString().trim() ??
            '';
        if (product.isNotEmpty) {
          pluToProductMap[plu] = _normalize(product);
        }
      }
    }
    print('  - ${pluToIssuedMappings.length} PLU entries in ItemsIssuedMap');
    print('');

    // ============================================================================
    // 4. STOCK COUNTS - Get Previous and Current counts
    // ============================================================================
    print('📊 Processing Stock Counts...');
    Map<String, double> prevCounts = {};
    Map<String, double> currCounts = {};
    Map<String, List<Map<String, dynamic>>> prodHistory = {};

    for (var row in stocks) {
      final name = _normalize(row['productName']);
      final rawDate = row['date']?.toString() ?? '';
      final dateStr = rawDate.contains('T') ? rawDate.split('T')[0] : rawDate;
      final qty = _safeDouble(row['total_bottles']);

      if (dateStr == dateToStr) {
        currCounts[name] = (currCounts[name] ?? 0) + qty;
      } else if (dateStr == dateFromStr) {
        prevCounts[name] = (prevCounts[name] ?? 0) + qty;
      }

      if (dateStr.compareTo(dateFromStr) >= 0 &&
          dateStr.compareTo(dateToStr) <= 0) {
        if (!prodHistory.containsKey(name)) prodHistory[name] = [];
        prodHistory[name]!.add(row);
      }

      if (!prodMainCat.containsKey(name)) {
        prodMainCat[name] = row['mainCategory']?.toString() ?? 'Uncategorized';
        prodCat[name] = row['category']?.toString() ?? 'General';
      }
    }
    print('  - Previous counts: ${prevCounts.length} products');
    print('  - Current counts: ${currCounts.length} products');
    print('');

    // ============================================================================
    // 5. PURCHASES - Aggregate within date range (exclusive of end date)
    // ============================================================================
    print('📦 Processing Purchases...');
    Map<String, double> prodPurchases = {};
    int purchaseInRange = 0;
    for (var row in purchases) {
      String dateRaw = row['Stock Delivery Date']?.toString() ?? '';
      if (dateRaw.isEmpty) continue;

      DateTime? deliveryDateRaw = _parseDate(dateRaw);

      if (deliveryDateRaw != null) {
        final deliveryDate = _stripTime(deliveryDateRaw);
        bool isOnOrAfterStart = deliveryDate.compareTo(fromDate) >= 0;
        bool isBeforeEnd = deliveryDate.compareTo(toDate) < 0;

        if (isOnOrAfterStart && isBeforeEnd) {
          final name = _normalize(row['Purchased Product Name']);
          final qty = _safeDouble(row['Total Stock In Bottles']);
          prodPurchases[name] = (prodPurchases[name] ?? 0) + qty;
          purchaseInRange++;
        }
      }
    }
    print('  - $purchaseInRange purchases in range');
    print('  - ${prodPurchases.length} unique products with purchases');
    print('');

    // ============================================================================
    // 6. ISSUES - Match the sheet formula exactly
    // ============================================================================
    print('📦 Processing Stock Issues (ISSUES ONLY)...');
    print('  - Total stockIssues records: ${stockIssues.length}');

    Map<String, double> productBottleUoM = {};
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      final bottleUoM = _safeDouble(item['Bottle UoM']);
      if (bottleUoM > 0) {
        productBottleUoM[name] = bottleUoM;
      }
    }

    Map<String, double> pluToQuantity = {};
    for (var row in itemsIssuedMap) {
      final plu = row['PLU']?.toString().trim();
      if (plu != null && plu.isNotEmpty) {
        pluToQuantity[plu] = _safeDouble(row['Quantity']);
      }
    }

    Map<String, double> pluNetTotals = {};
    Map<String, String> pluToProductName = {};
    int issuesInRange = 0;
    int issuesSkipped = 0;
    int issuesMatched = 0;

    for (var row in stockIssues) {
      String dateRaw = row['Date']?.toString() ?? '';
      if (dateRaw.isEmpty) continue;

      DateTime? issueDateRaw = _parseDate(dateRaw);
      if (issueDateRaw == null) continue;

      final issueDate = _stripTime(issueDateRaw);

      bool isAfterStart = issueDate.compareTo(fromDate) > 0;
      bool isOnOrBeforeEnd = issueDate.compareTo(toDate) <= 0;

      if (isAfterStart && isOnOrBeforeEnd) {
        issuesInRange++;

        final plu = row['Item']?.toString().trim() ?? '';
        final name = row['Name']?.toString().trim() ?? '';
        final issued = _safeDouble(row['Issued'] ?? 0);

        if (issued == 0) {
          issuesSkipped++;
          continue;
        }

        String productName = '';
        if (plu.isNotEmpty && pluToProductMap.containsKey(plu)) {
          productName = pluToProductMap[plu]!;
        } else if (name.isNotEmpty && inventoryRef.containsKey(name)) {
          productName = name;
        } else {
          productName = name.isNotEmpty ? name : plu;
        }

        if (productName.isNotEmpty) {
          double quantity = pluToQuantity[plu] ?? 1.0;
          double bottleUoM = productBottleUoM[productName] ?? 30.0;
          double totalQtyIssuedBtl = (issued * quantity) / bottleUoM;

          pluNetTotals[plu] = (pluNetTotals[plu] ?? 0) + totalQtyIssuedBtl;
          pluToProductName[plu] = productName;
          issuesMatched++;
        }
      }
    }

    Map<String, double> prodIssues = {};
    for (var entry in pluNetTotals.entries) {
      final plu = entry.key;
      final netTotal = entry.value;

      if (netTotal.abs() < 0.001) {
        print('  ⏭️ PLU $plu cancels to 0, skipping');
        continue;
      }

      final productName = pluToProductName[plu] ?? plu;
      prodIssues[productName] = (prodIssues[productName] ?? 0) + netTotal;
    }

    print('  - Issues in date range: $issuesInRange');
    print('  - Issues skipped (qty == 0): $issuesSkipped');
    print('  - Issues matched to products: $issuesMatched');
    print('  - ${prodIssues.length} unique products with issues');
    print('');

    // ============================================================================
    // 7. SALES - Match the sheet formula exactly
    // ============================================================================
    print('📦 Processing Store Sales (SALES ONLY)...');

    // 🔥 Build PLU → List of recipes, only include if Total Qty Used > 0
    // PLU keys are normalized here (e.g. "105.0" -> "105") so lookups
    // don't need any retry/fallback logic on the sales side.
    Map<String, List<Map<String, dynamic>>> pluToAllRecipes = {};
    for (var row in itemSalesMap) {
      final pluRaw = row['PLU']?.toString().trim();
      final plu = pluRaw != null && pluRaw.isNotEmpty
          ? (int.tryParse(pluRaw)?.toString() ?? pluRaw)
          : null;
      final totalQtyUsed = _safeDouble(row['Total Qty Used']);

      if (plu != null && plu.isNotEmpty && totalQtyUsed > 0) {
        pluToAllRecipes.putIfAbsent(plu, () => []);
        pluToAllRecipes[plu]!.add(row);
      }
    }

    Map<String, double> prodSales = {};
    int salesInRange = 0;
    int salesMatched = 0;
    int salesUnmatched = 0;

    for (var sale in storeSalesData) {
      String dateRaw = sale['Date']?.toString() ?? '';
      DateTime? saleDateRaw = _parseDate(dateRaw);
      if (saleDateRaw == null) continue;

      final saleDate = _stripTime(saleDateRaw);

      bool isAfterStart = saleDate.compareTo(fromDate) > 0;
      bool isOnOrBeforeEnd = saleDate.compareTo(toDate) <= 0;

      if (isAfterStart && isOnOrBeforeEnd) {
        salesInRange++;

        final salePluRaw = sale['No.']?.toString().trim();
        final salePlu = salePluRaw != null && salePluRaw.isNotEmpty
            ? (int.tryParse(salePluRaw)?.toString() ?? salePluRaw)
            : null;
        final qtySold = _safeDouble(sale['Qty']);

        if (salePlu != null && salePlu.isNotEmpty && qtySold > 0) {
          final allRecipes = pluToAllRecipes[salePlu] ?? [];

          if (allRecipes.isNotEmpty) {
            salesMatched++;

            Map<String, Map<String, dynamic>> uniqueProductRecipes = {};
            for (var recipe in allRecipes) {
              final productName = _normalize(recipe['Product']);
              if (productName.isNotEmpty &&
                  !uniqueProductRecipes.containsKey(productName)) {
                uniqueProductRecipes[productName] = recipe;
              }
            }

            for (var recipe in uniqueProductRecipes.values) {
              final productName = _normalize(recipe['Product']);
              final recipeQuantity = _safeDouble(recipe['Quantity']);
              final measure = recipe['Measure']?.toString().toLowerCase() ?? '';

              double qtyUsed = qtySold * recipeQuantity;
              double finalDeduction = _calculateDeduction(
                productName: productName,
                qtyUsed: qtyUsed,
                measure: measure,
                inventoryRef: inventoryRef,
              );

              prodSales[productName] =
                  (prodSales[productName] ?? 0) + finalDeduction;
            }
          } else {
            salesUnmatched++;
            if (salesUnmatched <= 10) {
              print('⚠️ No recipe found for PLU: "$salePlu"');
            }
          }
        }
      }
    }

    print('  - $salesInRange sales in range');
    print('  - $salesMatched sales matched, $salesUnmatched unmatched');
    print('  - ${prodSales.length} unique products with sales');
    print('');

    // ============================================================================
    // 8. COMPILE REPORT
    // ============================================================================
    print('📊 Compiling Variance Report...');
    final allNames = {
      ...prevCounts.keys,
      ...currCounts.keys,
      ...prodPurchases.keys,
      ...prodIssues.keys,
      ...prodSales.keys,
    };
    print('  - ${allNames.length} unique product names found');
    print('');

    List<VarianceItem> report = [];

    for (var name in allNames) {
      if (name.isEmpty) continue;
      if ((prevCounts[name] ?? 0) == 0 &&
          (currCounts[name] ?? 0) == 0 &&
          (prodPurchases[name] ?? 0) == 0 &&
          (prodIssues[name] ?? 0) == 0 &&
          (prodSales[name] ?? 0) == 0) {
        continue;
      }

      double cp = prodCosts[name] ?? 0.0;
      double rp = prodRetail[name] ?? 0.0;

      double finalRetailPrice = rp > 0 ? rp : cp * _estimatedMarkup;

      if (cp == 0 && rp > 0) {
        cp = rp / _estimatedMarkup;
      }

      report.add(
        VarianceItem(
          productName: name,
          mainCategory: prodMainCat[name] ?? 'Uncategorized',
          category: prodCat[name] ?? 'General',
          previousCount: prevCounts[name] ?? 0,
          purchases: prodPurchases[name] ?? 0,
          issues: prodIssues[name] ?? 0,
          sales: prodSales[name] ?? 0,
          currentCount: currCounts[name] ?? 0,
          costPrice: cp,
          retailPrice: finalRetailPrice,
          allEntries: prodHistory[name] ?? [],
          inventoryItem: inventoryRef[name],
        ),
      );
    }

    diagnostics['productsWithVariance'] = report.length;
    diagnostics['issuesInRange'] = issuesInRange;
    diagnostics['salesInRange'] = salesInRange;

    print('📊 Final Report: ${report.length} variance items');
    print('🔍 ===== VARIANCE REPORT END =====');
    print('');

    return {
      'items': report.map((item) => item.toJson()).toList(),
      'diagnostics': diagnostics,
    };
  }

  DateTime? _parseDate(String dateStr) {
    if (dateStr.isEmpty) return null;
    try {
      if (dateStr.contains('T')) {
        final datePart = dateStr.split('T')[0];
        final parts = datePart.split('-');
        if (parts.length == 3) {
          return DateTime.utc(
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          );
        }
      } else if (dateStr.contains('/')) {
        final parts = dateStr.split('/');
        if (parts.length == 3) {
          return DateTime(
            int.parse(parts[2]),
            int.parse(parts[1]),
            int.parse(parts[0]),
          );
        }
      } else if (dateStr.contains('-')) {
        final parts = dateStr.split('-');
        if (parts.length == 3) {
          return DateTime(
            int.parse(parts[2]),
            int.parse(parts[1]),
            int.parse(parts[0]),
          );
        }
      }
      return DateTime.tryParse(dateStr);
    } catch (e) {
      return null;
    }
  }

  double _calculateDeduction({
    required String productName,
    required double qtyUsed,
    required String measure,
    required Map<String, Map<String, dynamic>> inventoryRef,
  }) {
    double finalDeduction = 0.0;
    double bottleUoM = 30.0;
    double singleUoM = 1.0;
    double volumeMl = 750.0;

    if (inventoryRef.containsKey(productName)) {
      bottleUoM = _safeDouble(inventoryRef[productName]!['Bottle UoM']);
      singleUoM = _safeDouble(inventoryRef[productName]!['Single UoM']);
      volumeMl = _safeDouble(inventoryRef[productName]!['Single Unit Volume']);
      if (bottleUoM == 0) bottleUoM = 30.0;
      if (singleUoM == 0) singleUoM = 1.0;
      if (volumeMl == 0) volumeMl = 750.0;
    }

    if (measure.contains('bottle') || measure.contains('can')) {
      finalDeduction = qtyUsed;
    } else if (measure == 'shots' || measure.contains('tot')) {
      finalDeduction = qtyUsed / bottleUoM;
    } else if (measure == 'glass') {
      finalDeduction = qtyUsed * singleUoM;
    } else if (measure == 'ml') {
      finalDeduction = qtyUsed / volumeMl;
    } else {
      finalDeduction = qtyUsed;
    }

    return finalDeduction;
  }
}
