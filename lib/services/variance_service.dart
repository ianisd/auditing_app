import 'package:intl/intl.dart';
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
  final double retailPrice; // Calculated "Highest Valid" Bottle Price

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

  // This is the "Retail Value for Stock Count"
  double get totalStockValueRetail => currentCount * retailPrice;
}

class VarianceService {
  final LoggerService? logger;

  VarianceService({this.logger});

  // --- REGEX FOR EXCLUSIONS ---
  // Matches the Sheet Formula: REGEXMATCH(J2:J, "Special Shooter|...")
  final RegExp _exclusionRegex = RegExp(
    r'Special Shooter|Special Beverage|Cocktail Ingredient|Special Tot|Special Spirit Bottle|Special Alcoholic Beverage',
    caseSensitive: false,
  );

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

    if (logger != null) {
      logger!.info('--- CALC START ---');
      logger!.info('Range: ${fromDate.toIso8601String().split('T')[0]} to ${toDate.toIso8601String().split('T')[0]}');
    }

    Map<String, double> prodCosts = {};
    Map<String, double> prodRetail = {};
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

    // 2. Build Recipe Map & Calculate Highest Valid Retail Price
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
        // --- 2a. APPLY EXCLUSION LOGIC ---
        final mainCat = row['Main Category']?.toString() ?? '';

        // If it matches the "Special/Cocktail" regex, SKIP IT.
        if (_exclusionRegex.hasMatch(mainCat)) {
          continue;
        }

        // --- 2b. CALCULATE IMPLIED BOTTLE PRICE ---
        final measure = row['Measure']?.toString().toLowerCase() ?? '';
        double impliedBottlePrice = 0.0;

        // Get UoM info
        final invItem = inventoryRef[name];
        double bottleUoM = 30.0;
        double singleUoM = 1.0;

        if (invItem != null) {
          bottleUoM = _safeDouble(invItem['Bottle UoM']);
          singleUoM = _safeDouble(invItem['Single UoM']);
          if (bottleUoM == 0) bottleUoM = 30.0;
          if (singleUoM == 0) singleUoM = 1.0;
        }

        // Apply Formula: IFS(Bottle|Can, Price, Shots, Price*UoM, Glass, Price/UoM)
        if (measure.contains('bottle') || measure.contains('can')) {
          impliedBottlePrice = sellPrice;
        } else if (measure == 'shots' || measure.contains('tot')) {
          impliedBottlePrice = sellPrice * bottleUoM;
        } else if (measure == 'glass') {
          impliedBottlePrice = sellPrice / singleUoM;
        } else {
          impliedBottlePrice = sellPrice;
        }

        // --- 2c. KEEP HIGHEST PRICE ---
        // If this valid recipe yields a higher bottle price, store it.
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

    // 5. Sales (SMART MATCHING)
    Map<String, double> prodSales = {};

    for (var sale in storeSalesData) {
      String dateRaw = sale['Date']?.toString() ?? '';
      DateTime? saleDateRaw = _parseDate(dateRaw);

      if (saleDateRaw == null) continue;

      final saleDate = _stripTime(saleDateRaw);
      bool isStrictlyAfterStart = saleDate.isAfter(fromDate);
      bool isBeforeOrOnEnd = saleDate.isBefore(toDate) || saleDate.isAtSameMomentAs(toDate);

      if (isStrictlyAfterStart && isBeforeOrOnEnd) {
        final plu = sale['No.']?.toString().trim();
        final menuItemName = _normalize(sale['Item']);

        if (plu != null && pluToRecipes.containsKey(plu)) {
          final possibleRecipes = pluToRecipes[plu]!;
          Map<String, dynamic>? selectedRecipe;

          // Smart Match
          if (possibleRecipes.length == 1) {
            selectedRecipe = possibleRecipes.first;
          } else {
            try {
              selectedRecipe = possibleRecipes.firstWhere(
                      (r) => _normalize(r['Menu Item']) == menuItemName
              );
            } catch (e) {
              selectedRecipe = null;
            }
          }

          if (selectedRecipe != null) {
            final productName = _normalize(selectedRecipe['Product']);
            final qtySold = _safeDouble(sale['Qty']);
            double qtyUsed = qtySold * (_safeDouble(selectedRecipe['Quantity']));
            final measure = selectedRecipe['Measure']?.toString().toLowerCase() ?? '';

            double finalDeduction = 0.0;
            if (measure.contains('bottle') || measure.contains('can')) {
              finalDeduction = qtyUsed;
            } else if (measure == 'shots' || measure.contains('tot')) {
              double bottleUoM = 30.0;
              if (inventoryRef.containsKey(productName)) {
                bottleUoM = _safeDouble(inventoryRef[productName]!['Bottle UoM']);
                if (bottleUoM == 0) bottleUoM = 30.0;
              }
              finalDeduction = qtyUsed / bottleUoM;
            } else {
              finalDeduction = qtyUsed;
            }

            prodSales[productName] = (prodSales[productName] ?? 0) + finalDeduction;
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

      report.add(VarianceItem(
        productName: name,
        mainCategory: prodMainCat[name] ?? 'Uncategorized',
        category: prodCat[name] ?? 'General',
        previousCount: prevCounts[name] ?? 0,
        purchases: prodPurchases[name] ?? 0,
        sales: prodSales[name] ?? 0,
        currentCount: currCounts[name] ?? 0,
        costPrice: prodCosts[name] ?? 0,
        retailPrice: prodRetail[name] ?? 0,
        allEntries: prodHistory[name] ?? [],
        inventoryItem: inventoryRef[name],
      ));
    }

    return report;
  }

  DateTime? _parseDate(String dateStr) {
    if (dateStr.isEmpty) return null;
    try {
      if (dateStr.contains('/')) {
        final parts = dateStr.split('/');
        if (parts.length == 3) {
          return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
        }
      }
      return DateTime.tryParse(dateStr);
    } catch (e) {
      return null;
    }
  }
}