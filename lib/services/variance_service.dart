import 'package:intl/intl.dart';

class VarianceItem {
  final String productName;
  final double previousCount;
  final double purchases;
  final double sales;
  final double currentCount;
  final double costPrice;

  final List<Map<String, dynamic>> allEntries;
  final Map<String, dynamic>? inventoryItem;

  VarianceItem({
    required this.productName,
    required this.previousCount,
    required this.purchases,
    required this.sales,
    required this.currentCount,
    required this.costPrice,
    this.allEntries = const [],
    this.inventoryItem,
  });

  // Logic: Start + In - Out = Expected.
  // Variance = Actual - Expected.
  double get theoreticalStock => previousCount + purchases - sales;
  double get variance => currentCount - theoreticalStock;
  double get varianceValue => variance * costPrice;
}

class VarianceService {

  String _normalize(String? input) => input?.toString().toLowerCase().trim() ?? '';

  List<VarianceItem> calculateReport({
    required List<Map<String, dynamic>> stocks,
    required List<Map<String, dynamic>> purchases,
    // New parameters for Sales Calculation
    required List<Map<String, dynamic>> storeSalesData, // Raw POS
    required List<Map<String, dynamic>> itemSalesMap,   // Recipes
    required List<Map<String, dynamic>> inventory,

    required String dateFromStr, // YYYY-MM-DD
    required String dateToStr,   // YYYY-MM-DD
  }) {
    Map<String, double> prevCounts = {};
    Map<String, double> currCounts = {};
    Map<String, double> prodPurchases = {};
    Map<String, double> prodSales = {}; // Calculated Sales
    Map<String, double> prodCosts = {};

    Map<String, List<Map<String, dynamic>>> prodHistory = {};
    Map<String, Map<String, dynamic>> inventoryRef = {};

    // 1. Inventory & Costs
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      inventoryRef[name] = item;
      final cost = double.tryParse(item['Cost Price']?.toString() ?? '0') ?? 0.0;
      prodCosts[name] = cost;
    }

    // 2. Stock Counts (Previous vs Current)
    for (var row in stocks) {
      final name = _normalize(row['productName']);
      final rawDate = row['date'].toString();
      final dateStr = rawDate.contains('T') ? rawDate.split('T')[0] : rawDate;
      final qty = double.tryParse(row['total_bottles']?.toString() ?? '0') ?? 0.0;

      bool inRange = (dateStr.compareTo(dateFromStr) >= 0 && dateStr.compareTo(dateToStr) <= 0);
      if (inRange) {
        if (!prodHistory.containsKey(name)) prodHistory[name] = [];
        prodHistory[name]!.add(row);
      }

      if (dateStr == dateToStr) {
        currCounts[name] = (currCounts[name] ?? 0) + qty;
      } else if (dateStr == dateFromStr) {
        prevCounts[name] = (prevCounts[name] ?? 0) + qty;
      }
    }

    // 3. Purchases Logic
    final fromDt = DateTime.parse(dateFromStr);
    final toDt = DateTime.parse(dateToStr);

    for (var row in purchases) {
      final name = _normalize(row['Purchased Product Name']);
      String dateRaw = row['Inv. Date of Purchase'] ?? '';

      DateTime? invDate = _parseDate(dateRaw);

      if (invDate != null) {
        // Purchases: After Start Date, Up to End Date
        if (invDate.isAfter(fromDt) && !invDate.isAfter(toDt)) {
          final qty = double.tryParse(row['Total Stock In Bottles']?.toString() ?? '0') ?? 0.0;
          prodPurchases[name] = (prodPurchases[name] ?? 0) + qty;
        }
      }
    }

    // 4. COMPLEX SALES CALCULATION
    // First, map PLUs to Inventory Items for speed
    Map<String, Map<String, dynamic>> pluToRecipe = {};
    for (var mapItem in itemSalesMap) {
      final plu = mapItem['PLU']?.toString().trim();
      if (plu != null && plu.isNotEmpty) {
        pluToRecipe[plu] = mapItem;
      }
    }

    for (var sale in storeSalesData) {
      // A. Check Date Range
      String dateRaw = sale['Date'] ?? '';
      DateTime? saleDate = _parseDate(dateRaw);

      // Sales: After Start Date, Up to End Date
      if (saleDate != null && saleDate.isAfter(fromDt) && !saleDate.isAfter(toDt)) {

        // B. Get PLU and Qty
        final plu = sale['No.']?.toString().trim(); // Ensure this matches CSV column for PLU
        final qtySold = double.tryParse(sale['Qty']?.toString() ?? '0') ?? 0.0;

        if (plu != null && pluToRecipe.containsKey(plu)) {
          final recipe = pluToRecipe[plu]!;
          final productName = _normalize(recipe['Product']);

          // C. Calculate Deduction Amount
          // Formula: Qty Sold * (Quantity in Recipe)
          double qtyUsed = qtySold * (double.tryParse(recipe['Quantity']?.toString() ?? '1') ?? 1.0);

          // D. Apply Unit of Measure Conversion
          // Matches your "Bottle Price" formula logic
          final measure = recipe['Measure']?.toString().toLowerCase() ?? '';

          double finalDeduction = 0.0;

          if (measure.contains('bottle') || measure.contains('can')) {
            // 1 sold = 1 bottle deducted
            finalDeduction = qtyUsed;
          }
          else if (measure == 'shots' || measure.contains('tot')) {
            // Need Bottle UoM (e.g., 30 shots per bottle)
            // Look up UoM from Inventory
            final inventoryItem = inventoryRef[productName];
            double bottleUoM = 30.0; // Default fallback
            if (inventoryItem != null) {
              bottleUoM = double.tryParse(inventoryItem['Bottle UoM']?.toString() ?? '0') ?? 0;
              if (bottleUoM == 0) bottleUoM = 30.0;
            }
            finalDeduction = qtyUsed / bottleUoM;
          }
          else if (measure == 'glass') {
            // Similar to shots, usually 4 or 5 glasses per bottle
            // You need a specific column for Glass UoM, or use Single UoM
            final inventoryItem = inventoryRef[productName];
            double glassUoM = 5.0;
            if (inventoryItem != null) {
              // If you have a specific Glass column, use it. Otherwise guess.
              double uom = double.tryParse(inventoryItem['Single UoM']?.toString() ?? '0') ?? 0;
              if (uom > 0) glassUoM = uom;
            }
            finalDeduction = qtyUsed / glassUoM;
          }
          else {
            // Fallback: Assume 1:1
            finalDeduction = qtyUsed;
          }

          prodSales[productName] = (prodSales[productName] ?? 0) + finalDeduction;
        }
      }
    }

    // 5. Compile Report
    final allNames = {...prevCounts.keys, ...currCounts.keys, ...prodPurchases.keys, ...prodSales.keys};
    List<VarianceItem> report = [];

    for (var name in allNames) {
      if (name.isEmpty) continue;
      if ((prevCounts[name]??0) == 0 && (currCounts[name]??0) == 0 && (prodPurchases[name]??0) == 0 && (prodSales[name]??0) == 0) continue;

      report.add(VarianceItem(
        productName: name,
        previousCount: prevCounts[name] ?? 0,
        purchases: prodPurchases[name] ?? 0,
        sales: prodSales[name] ?? 0,
        currentCount: currCounts[name] ?? 0,
        costPrice: prodCosts[name] ?? 0,
        allEntries: prodHistory[name] ?? [],
        inventoryItem: inventoryRef[name],
      ));
    }

    report.sort((a, b) => a.varianceValue.compareTo(b.varianceValue));
    return report;
  }

  DateTime? _parseDate(String dateStr) {
    if (dateStr.isEmpty) return null;
    try {
      // Prioritize DD/MM/YYYY which is common in CSVs
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