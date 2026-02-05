import 'package:intl/intl.dart';

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
}

class VarianceService {

  // Normalize: Lowercase and Trim whitespace to handle small differences
  String _normalize(String? input) => input?.toString().toLowerCase().trim() ?? '';

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

    Map<String, double> prodCosts = {};
    Map<String, double> prodRetail = {};
    Map<String, String> prodMainCat = {};
    Map<String, String> prodCat = {};
    Map<String, Map<String, dynamic>> inventoryRef = {};

    // 1. Inventory Map (Cost & UoM)
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      inventoryRef[name] = item;
      prodCosts[name] = double.tryParse(item['Cost Price']?.toString() ?? '0') ?? 0.0;
      prodMainCat[name] = item['Main Category']?.toString() ?? 'Uncategorized';
      prodCat[name] = item['Category']?.toString() ?? 'General';
    }

    // 2. Build Robust Recipe Map (Handle Same PLU, Different Names)
    // Map<PLU, List<Recipe>>
    Map<String, List<Map<String, dynamic>>> pluToRecipes = {};

    for (var row in itemSalesMap) {
      final plu = row['PLU']?.toString().trim();
      if (plu == null || plu.isEmpty) continue;

      if (!pluToRecipes.containsKey(plu)) {
        pluToRecipes[plu] = [];
      }
      pluToRecipes[plu]!.add(row);

      // -- CALCULATE RETAIL PRICE --
      final name = _normalize(row['Product']);
      final measure = row['Measure']?.toString().toLowerCase() ?? '';
      final sellPrice = double.tryParse(row['Sell']?.toString() ?? '0') ?? 0.0;

      if (sellPrice > 0) {
        double calculatedBottlePrice = 0.0;
        final invItem = inventoryRef[name];
        double bottleUoM = 30.0;
        double singleUoM = 1.0;

        if (invItem != null) {
          bottleUoM = double.tryParse(invItem['Bottle UoM']?.toString() ?? '0') ?? 0;
          singleUoM = double.tryParse(invItem['Single UoM']?.toString() ?? '0') ?? 0;
          if (bottleUoM == 0) bottleUoM = 30.0;
          if (singleUoM == 0) singleUoM = 1.0;
        }

        if (measure.contains('bottle') || measure.contains('can')) {
          calculatedBottlePrice = sellPrice;
        } else if (measure == 'shots' || measure.contains('tot')) {
          calculatedBottlePrice = sellPrice * bottleUoM;
        } else if (measure == 'glass') {
          calculatedBottlePrice = sellPrice / singleUoM;
        } else {
          calculatedBottlePrice = sellPrice;
        }

        if (calculatedBottlePrice > (prodRetail[name] ?? 0)) {
          prodRetail[name] = calculatedBottlePrice;
        }
      }
    }

    // 3. Stock Counts
    Map<String, double> prevCounts = {};
    Map<String, double> currCounts = {};
    Map<String, List<Map<String, dynamic>>> prodHistory = {};

    for (var row in stocks) {
      final name = _normalize(row['productName']);
      final rawDate = row['date'].toString();
      final dateStr = rawDate.contains('T') ? rawDate.split('T')[0] : rawDate;
      final qty = double.tryParse(row['total_bottles']?.toString() ?? '0') ?? 0.0;

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
      String dateRaw = row['Stock Delivery Date'] ?? '';
      if (dateRaw.isEmpty) continue;

      DateTime? deliveryDateRaw = _parseDate(dateRaw);

      if (deliveryDateRaw != null) {
        final deliveryDate = _stripTime(deliveryDateRaw);
        bool isAfterOrOnStart = deliveryDate.isAtSameMomentAs(fromDate) || deliveryDate.isAfter(fromDate);
        bool isStrictlyBeforeEnd = deliveryDate.isBefore(toDate);

        if (isAfterOrOnStart && isStrictlyBeforeEnd) {
          final name = _normalize(row['Purchased Product Name']);
          final qty = double.tryParse(row['Total Stock In Bottles']?.toString() ?? '0') ?? 0.0;
          prodPurchases[name] = (prodPurchases[name] ?? 0) + qty;
        }
      }
    }

    // 5. Sales (STRICT MATCHING ONLY)
    Map<String, double> prodSales = {};

    for (var sale in storeSalesData) {
      String dateRaw = sale['Date'] ?? '';
      DateTime? saleDateRaw = _parseDate(dateRaw);

      if (saleDateRaw != null) {
        final saleDate = _stripTime(saleDateRaw);
        bool isStrictlyAfterStart = saleDate.isAfter(fromDate);
        bool isBeforeOrOnEnd = saleDate.isBefore(toDate) || saleDate.isAtSameMomentAs(toDate);

        if (isStrictlyAfterStart && isBeforeOrOnEnd) {
          final plu = sale['No.']?.toString().trim();
          final menuItemName = _normalize(sale['Item']);

          if (plu != null && pluToRecipes.containsKey(plu)) {
            final possibleRecipes = pluToRecipes[plu]!;

            // --- STRICT MODE ---
            // Try Exact Name Match. If not found, SKIP this sale.
            // This prevents "Burger" being deducted when the sale was actually "Coke"
            // just because they share a PLU.
            try {
              final selectedRecipe = possibleRecipes.firstWhere(
                      (r) => _normalize(r['Menu Item']) == menuItemName
              );

              final productName = _normalize(selectedRecipe['Product']);
              final qtySold = double.tryParse(sale['Qty']?.toString() ?? '0') ?? 0.0;

              double qtyUsed = qtySold * (double.tryParse(selectedRecipe['Quantity']?.toString() ?? '1') ?? 1.0);
              final measure = selectedRecipe['Measure']?.toString().toLowerCase() ?? '';

              double finalDeduction = 0.0;
              if (measure.contains('bottle') || measure.contains('can')) {
                finalDeduction = qtyUsed;
              } else if (measure == 'shots' || measure.contains('tot')) {
                double bottleUoM = 30.0;
                if (inventoryRef.containsKey(productName)) {
                  bottleUoM = double.tryParse(inventoryRef[productName]!['Bottle UoM']?.toString() ?? '0') ?? 0;
                  if (bottleUoM == 0) bottleUoM = 30.0;
                }
                finalDeduction = qtyUsed / bottleUoM;
              } else {
                finalDeduction = qtyUsed;
              }

              prodSales[productName] = (prodSales[productName] ?? 0) + finalDeduction;

            } catch (e) {
              // No exact match found for PLU + Name.
              // We intentionally do NOTHING here.
              // Better to report 0 sales than wrong sales.
            }
          }
        }
      }
    }

    // 6. Compile Report
    final allNames = {...prevCounts.keys, ...currCounts.keys, ...prodPurchases.keys, ...prodSales.keys};
    List<VarianceItem> report = [];

    for (var name in allNames) {
      if (name.isEmpty) continue;
      // Filter out items with absolutely zero activity
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
        // Assuming dd/MM/yyyy
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