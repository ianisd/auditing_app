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
    required List<Map<String, dynamic>> storeSalesData,
    required List<Map<String, dynamic>> itemSalesMap,
    required List<Map<String, dynamic>> inventory,
    required String dateFromStr,
    required String dateToStr,
  }) {
    // 1. Optimization: Pre-calculate Dates
    final fromDt = DateTime.parse(dateFromStr);
    final toDt = DateTime.parse(dateToStr);

    // 2. Optimization: Pre-map Inventory for O(1) lookup
    Map<String, double> prodCosts = {};
    Map<String, Map<String, dynamic>> inventoryRef = {};
    // New: Map "Normalized Name" -> "Inventory Item"
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      inventoryRef[name] = item;
      prodCosts[name] = double.tryParse(item['Cost Price']?.toString() ?? '0') ?? 0.0;
    }

    // 3. Process Counts
    Map<String, double> prevCounts = {};
    Map<String, double> currCounts = {};
    Map<String, List<Map<String, dynamic>>> prodHistory = {};

    for (var row in stocks) {
      final name = _normalize(row['productName']);
      final rawDate = row['date'].toString();
      final dateStr = rawDate.contains('T') ? rawDate.split('T')[0] : rawDate;
      final qty = double.tryParse(row['total_bottles']?.toString() ?? '0') ?? 0.0;

      // History
      if (dateStr.compareTo(dateFromStr) >= 0 && dateStr.compareTo(dateToStr) <= 0) {
        if (!prodHistory.containsKey(name)) prodHistory[name] = [];
        prodHistory[name]!.add(row);
      }

      if (dateStr == dateToStr) {
        currCounts[name] = (currCounts[name] ?? 0) + qty;
      } else if (dateStr == dateFromStr) {
        prevCounts[name] = (prevCounts[name] ?? 0) + qty;
      }
    }

    // 4. Process Purchases (Optimized Date Parsing)
    Map<String, double> prodPurchases = {};
    for (var row in purchases) {
      String dateRaw = row['Inv. Date of Purchase'] ?? '';
      if (dateRaw.isEmpty) continue;

      // Fast check before parsing
      DateTime? invDate = _parseDate(dateRaw);

      if (invDate != null && invDate.isAfter(fromDt) && !invDate.isAfter(toDt)) {
        final name = _normalize(row['Purchased Product Name']);
        final qty = double.tryParse(row['Total Stock In Bottles']?.toString() ?? '0') ?? 0.0;
        prodPurchases[name] = (prodPurchases[name] ?? 0) + qty;
      }
    }

    // 5. Process Sales (Optimized Recipe Lookup)
    Map<String, double> prodSales = {};

    // Pre-process Item Sales Map into a Dictionary
    Map<String, Map<String, dynamic>> pluDict = {};
    for (var m in itemSalesMap) {
      final code = m['PLU']?.toString().trim();
      if (code != null && code.isNotEmpty) pluDict[code] = m;
    }

    for (var sale in storeSalesData) {
      // 1. Date Check
      String dateRaw = sale['Date'] ?? '';
      DateTime? saleDate = _parseDate(dateRaw);

      if (saleDate != null && saleDate.isAfter(fromDt) && !saleDate.isAfter(toDt)) {

        // 2. PLU Lookup
        final plu = sale['No.']?.toString().trim();
        if (plu != null && pluDict.containsKey(plu)) {
          final recipe = pluDict[plu]!;
          final productName = _normalize(recipe['Product']);
          final qtySold = double.tryParse(sale['Qty']?.toString() ?? '0') ?? 0.0;

          // 3. Conversion Logic
          double qtyUsed = qtySold * (double.tryParse(recipe['Quantity']?.toString() ?? '1') ?? 1.0);
          final measure = recipe['Measure']?.toString().toLowerCase() ?? '';

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
            finalDeduction = qtyUsed; // Default
          }

          prodSales[productName] = (prodSales[productName] ?? 0) + finalDeduction;
        }
      }
    }

    // 6. Compile
    final allNames = {...prevCounts.keys, ...currCounts.keys, ...prodPurchases.keys, ...prodSales.keys};
    List<VarianceItem> report = [];

    for (var name in allNames) {
      if (name.isEmpty) continue;
      // Skip dead items
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