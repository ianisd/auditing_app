import '../services/logger_service.dart';

class VarianceItem {
  final String productName;
  final String mainCategory;
  final String category;

  final double previousCount;
  final double purchases;
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
    required this.sales,
    required this.currentCount,
    required this.costPrice,
    required this.retailPrice,
    this.allEntries = const [],
    this.inventoryItem,
  });

  double get theoreticalStock => previousCount + purchases - sales;
  double get variance => currentCount - theoreticalStock;

  double get varianceCost => variance * costPrice;
  double get varianceRetail => variance * retailPrice;
  double get totalStockValueRetail => currentCount * retailPrice;

  // Convert to JSON for isolate communication
  Map<String, dynamic> toJson() => {
    'productName': productName,
    'mainCategory': mainCategory,
    'category': category,
    'previousCount': previousCount,
    'purchases': purchases,
    'sales': sales,
    'currentCount': currentCount,
    'costPrice': costPrice,
    'retailPrice': retailPrice,
    'allEntries': allEntries,
    'inventoryItem': inventoryItem,
  };

  // Create from JSON after isolate returns
  factory VarianceItem.fromJson(Map<String, dynamic> json) => VarianceItem(
    productName: json['productName'],
    mainCategory: json['mainCategory'],
    category: json['category'],
    previousCount: json['previousCount'],
    purchases: json['purchases'],
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

  // 🔥 NEW: Isolate-friendly constructor (no logger)
  VarianceService.isolate() : logger = null;

  final RegExp _exclusionRegex = RegExp(
    r'Special Shooter|Special Beverage|Cocktail Ingredient|Special Tot|Special Spirit Bottle|Special Alcoholic Beverage',
    caseSensitive: false,
  );

  // Standard Hospitality Markup (300% or Cost * 3)
  // Used to estimate missing prices so reports correlate
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

  List<VarianceItem> calculateReport({
    required List<Map<String, dynamic>> stocks,
    required List<Map<String, dynamic>> purchases,
    required List<Map<String, dynamic>> storeSalesData,
    required List<Map<String, dynamic>> itemSalesMap,
    required List<Map<String, dynamic>> inventory,
    required String dateFromStr,
    required String dateToStr,
  }) {
    final fromDtRaw = DateTime.parse(dateFromStr);
    final toDtRaw = DateTime.parse(dateToStr);

    final fromDate = _stripTime(fromDtRaw);
    final toDate = _stripTime(toDtRaw);

    print('📊 VARIANCE REPORT INPUTS:');
    print('  - Stocks: ${stocks.length}');
    print('  - Purchases: ${purchases.length}');
    print('  - StoreSalesData: ${storeSalesData.length}');
    print('  - ItemSalesMap: ${itemSalesMap.length}');
    print('  - Inventory: ${inventory.length}');
    print('  - Date Range: $dateFromStr to $dateToStr');
    print('  - Parsed From: $fromDate');
    print('  - Parsed To: $toDate');

    if (logger != null) {
      logger!.info('--- CALC START ---');
      logger!.info('Range: ${fromDate.toIso8601String().split('T')[0]} to ${toDate.toIso8601String().split('T')[0]}');
    }

    Map<String, double> prodCosts = {};
    Map<String, double> prodRetail = {}; // Will now store MAX price from sales
    Map<String, String> prodMainCat = {};
    Map<String, String> prodCat = {};
    Map<String, Map<String, dynamic>> inventoryRef = {};

    // 1. Inventory Map
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      inventoryRef[name] = item;
      prodCosts[name] = _safeDouble(item['Cost Price']);
      prodMainCat[name] = item['Main Category']?.toString() ?? 'Uncategorized';
      prodCat[name] = item['Category']?.toString() ?? 'General';
    }

    // 2. Build Recipe Map and Calculate MAX Retail Prices (like sheet's MAX query)
    Map<String, List<Map<String, dynamic>>> pluToRecipes = {};

    for (var row in itemSalesMap) {
      final plu = row['PLU']?.toString().trim();
      if (plu != null && plu.isNotEmpty) {
        if (!pluToRecipes.containsKey(plu)) {
          pluToRecipes[plu] = [];
        }
        pluToRecipes[plu]!.add(row);
      }

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
          impliedBottlePrice = sellPrice * 30.0; // Fallback estimate if ML logic fails
        } else {
          impliedBottlePrice = sellPrice;
        }

        // 🔥 UPDATED: Store the MAX price (like sheet's MAX query)
        if (impliedBottlePrice > (prodRetail[name] ?? 0)) {
          prodRetail[name] = impliedBottlePrice;
        }
      }
    }

    // 3. Stock Counts
    Map<String, double> prevCounts = {};
    Map<String, double> currCounts = {};
    Map<String, List<Map<String, dynamic>>> prodHistory = {};

    for (var row in stocks) {
      final name = _normalize(row['productName']);
      final rawDate = row['date']?.toString() ?? '';
      final dateStr = rawDate.contains('T') ? rawDate.split('T')[0] : rawDate;
      final qty = _safeDouble(row['total_bottles']);

      if (dateStr.compareTo(dateFromStr) >= 0 && dateStr.compareTo(dateToStr) <= 0) {
        if (!prodHistory.containsKey(name)) prodHistory[name] = [];
        prodHistory[name]!.add(row);
      }

      if (dateStr == dateToStr) {
        currCounts[name] = (currCounts[name] ?? 0) + qty;
      } else if (dateStr == dateFromStr) {
        prevCounts[name] = (prevCounts[name] ?? 0) + qty;
      }

      if (!prodMainCat.containsKey(name)) {
        prodMainCat[name] = row['mainCategory']?.toString() ?? 'Uncategorized';
        prodCat[name] = row['category']?.toString() ?? 'General';
      }
    }

    // 4. Purchases
    Map<String, double> prodPurchases = {};
    for (var row in purchases) {
      String dateRaw = row['Stock Delivery Date']?.toString() ?? '';
      if (dateRaw.isEmpty) continue;

      DateTime? deliveryDateRaw = _parseDate(dateRaw);

      if (deliveryDateRaw != null) {
        final deliveryDate = _stripTime(deliveryDateRaw);
        bool isAfterOrOnStart = deliveryDate.isAtSameMomentAs(fromDate) || deliveryDate.isAfter(fromDate);
        bool isStrictlyBeforeEnd = deliveryDate.isBefore(toDate);

        if (isAfterOrOnStart && isStrictlyBeforeEnd) {
          final name = _normalize(row['Purchased Product Name']);
          final qty = _safeDouble(row['Total Stock In Bottles']);
          prodPurchases[name] = (prodPurchases[name] ?? 0) + qty;
        }
      }
    }

    // 5. Sales
    Map<String, double> prodSales = {};

    print('📅 Sample StoreSalesData dates:');
    for (var i = 0; i < storeSalesData.length && i < 5; i++) {
      print('  Sale ${i+1}: "${storeSalesData[i]['Date']}"');
    }

    for (var sale in storeSalesData) {
      String dateRaw = sale['Date']?.toString() ?? '';
      DateTime? saleDateRaw = _parseDate(dateRaw);

      if (saleDateRaw == null) continue;

      final saleDate = _stripTime(saleDateRaw);
      bool isStrictlyAfterStart = saleDate.isAfter(fromDate);
      bool isBeforeOrOnEnd = saleDate.isBefore(toDate) || saleDate.isAtSameMomentAs(toDate);

      print('  Processing sale: dateRaw="$dateRaw", parsed=$saleDateRaw');

      if (isStrictlyAfterStart && isBeforeOrOnEnd) {
        final plu = sale['No.']?.toString().trim();
        final menuItemName = _normalize(sale['MenuItem'] ?? sale['Menu Item'] ?? sale['Item']);

        if (plu != null && pluToRecipes.containsKey(plu)) {
          final possibleRecipes = pluToRecipes[plu]!;
          List<Map<String, dynamic>> recipesToProcess = [];

          try {
            final matchingRecipes = possibleRecipes.where(
                    (r) => _normalize(r['Menu Item']) == menuItemName
            ).toList();

            if (matchingRecipes.isNotEmpty) {
              final firstCat = (matchingRecipes.first['Main Category'] ?? '').toString().toLowerCase();
              final isMultiIngredient = firstCat.contains('special') || firstCat.contains('cocktail');

              if (isMultiIngredient) {
                recipesToProcess = matchingRecipes;
              } else {
                final distinctProducts = matchingRecipes.map((r) => r['Product']).toSet();
                if (distinctProducts.length > 1) {
                  print('AMBIGUITY: PLU $plu "$menuItemName" collision. Using first.');
                }
                recipesToProcess = [matchingRecipes.first];
              }

              for (var selectedRecipe in recipesToProcess) {
                final productName = _normalize(selectedRecipe['Product']);
                final qtySold = _safeDouble(sale['Qty']);
                double qtyUsed = qtySold * (_safeDouble(selectedRecipe['Quantity']));
                final measure = selectedRecipe['Measure']?.toString().toLowerCase() ?? '';

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
                }
                else if (measure == 'shots' || measure.contains('tot')) {
                  finalDeduction = qtyUsed / bottleUoM;
                }
                else if (measure == 'glass') {
                  finalDeduction = qtyUsed * singleUoM;
                }
                else if (measure == 'ml') {
                  finalDeduction = qtyUsed / volumeMl;
                } else {
                  finalDeduction = qtyUsed;
                }

                prodSales[productName] = (prodSales[productName] ?? 0) + finalDeduction;
              }
            }
          } catch (e) {
            // Ignore
          }
        }
      }
    }

    // 6. Compile Report
    final allNames = {...prevCounts.keys, ...currCounts.keys, ...prodPurchases.keys, ...prodSales.keys};
    List<VarianceItem> report = [];

    for (var name in allNames) {
      if (name.isEmpty) continue;
      if ((prevCounts[name]??0) == 0 && (currCounts[name]??0) == 0 && (prodPurchases[name]??0) == 0 && (prodSales[name]??0) == 0) continue;

      double cp = prodCosts[name] ?? 0.0;
      double rp = prodRetail[name] ?? 0.0;

      // 🔥 UPDATED: Match Google Sheets logic exactly:
      // 1. Use maxPrice from sales if available
      // 2. Otherwise fall back to unitCost * 3
      double finalRetailPrice = rp > 0 ? rp : cp * _estimatedMarkup;

      // Also estimate cost if needed for variance calculations
      if (cp == 0 && rp > 0) {
        cp = rp / _estimatedMarkup;
      }

      report.add(VarianceItem(
        productName: name,
        mainCategory: prodMainCat[name] ?? 'Uncategorized',
        category: prodCat[name] ?? 'General',
        previousCount: prevCounts[name] ?? 0,
        purchases: prodPurchases[name] ?? 0,
        sales: prodSales[name] ?? 0,
        currentCount: currCounts[name] ?? 0,
        costPrice: cp,
        retailPrice: finalRetailPrice, // Use the calculated retail price
        allEntries: prodHistory[name] ?? [],
        inventoryItem: inventoryRef[name],
      ));
    }

    return report;
  }

  DateTime? _parseDate(String dateStr) {
    if (dateStr.isEmpty) return null;
    try {
      // Handle ISO format with time (2026-01-13T08:00:00.000Z)
      if (dateStr.contains('T')) {
        // Extract just the date part before T
        final datePart = dateStr.split('T')[0];
        final parts = datePart.split('-');
        if (parts.length == 3) {
          // ISO format is yyyy-MM-dd
          return DateTime.utc(
              int.parse(parts[0]),
              int.parse(parts[1]),
              int.parse(parts[2])
          );
        }
      }
      // Handle dd/MM/yyyy format (with slashes)
      else if (dateStr.contains('/')) {
        final parts = dateStr.split('/');
        if (parts.length == 3) {
          return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
        }
      }
      // Handle dd-MM-yyyy format (with hyphens)
      else if (dateStr.contains('-')) {
        final parts = dateStr.split('-');
        if (parts.length == 3) {
          return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
        }
      }
      // Try standard parsing as fallback
      return DateTime.tryParse(dateStr);
    } catch (e) {
      return null;
    }
  }
}

// 🔥 CORRECTED: Top-level function for isolate entry point (NO static keyword)
@pragma('vm:entry-point')
List<Map<String, dynamic>> calculateReportIsolate(Map<String, dynamic> params) {
  // Create service without logger (can't send logger across isolates)
  final service = VarianceService.isolate();

  // Run the calculation
  final List<VarianceItem> results = service.calculateReport(
    stocks: params['stocks'],
    purchases: params['purchases'],
    storeSalesData: params['storeSalesData'],
    itemSalesMap: params['itemSalesMap'],
    inventory: params['inventory'],
    dateFromStr: params['dateFromStr'],
    dateToStr: params['dateToStr'],
  );

  // Convert to JSON-serializable format
  return results.map((item) => item.toJson()).toList();
}