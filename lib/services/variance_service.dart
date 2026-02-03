import 'package:intl/intl.dart';

class VarianceItem {
  final String productName;
  final double previousCount;
  final double purchases;
  final double sales;
  final double currentCount;
  final double costPrice;

  // CHANGED: Holds ALL counts in the date range, not just start/end
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

  double get theoreticalStock => previousCount + purchases - sales;
  double get variance => currentCount - theoreticalStock;
  double get varianceValue => variance * costPrice;
}

class VarianceService {

  String _normalize(String? input) => input?.toString().toLowerCase().trim() ?? '';

  List<VarianceItem> calculateReport({
    required List<Map<String, dynamic>> stocks,
    required List<Map<String, dynamic>> purchases,
    required List<Map<String, dynamic>> sales,
    required List<Map<String, dynamic>> inventory,
    required String dateFromStr, // YYYY-MM-DD
    required String dateToStr,   // YYYY-MM-DD
  }) {
    // 1. Dictionaries
    Map<String, double> prevCounts = {};
    Map<String, double> currCounts = {};
    Map<String, double> prodPurchases = {};
    Map<String, double> prodSales = {};
    Map<String, double> prodCosts = {};

    // CHANGED: Map to hold list of ALL relevant counts
    Map<String, List<Map<String, dynamic>>> prodHistory = {};
    Map<String, Map<String, dynamic>> inventoryRef = {};

    // 2. Build Inventory Reference
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      inventoryRef[name] = item;

      final cost = double.tryParse(item['Cost Price']?.toString() ?? '0') ?? 0.0;
      prodCosts[name] = cost;
    }

    // 3. Process Stock Counts (Trend Logic)
    final fromDt = DateTime.parse(dateFromStr);
    final toDt = DateTime.parse(dateToStr);

    for (var row in stocks) {
      final name = _normalize(row['productName']);
      final rawDate = row['date'].toString();
      final dateStr = rawDate.contains('T') ? rawDate.split('T')[0] : rawDate;

      DateTime? rowDate;
      try { rowDate = DateTime.parse(dateStr); } catch (e) { continue; }

      final qty = double.tryParse(row['total_bottles']?.toString() ?? '0') ?? 0.0;

      // Filter: Only include counts within the range
      // We use isBefore/isAfter with loose equality logic or just CompareTo
      // Simple string compare for YYYY-MM-DD works well too
      bool inRange = (dateStr.compareTo(dateFromStr) >= 0 && dateStr.compareTo(dateToStr) <= 0);

      if (inRange) {
        if (!prodHistory.containsKey(name)) prodHistory[name] = [];
        prodHistory[name]!.add(row);
      }

      // Calculation Logic (Strict Boundaries)
      if (dateStr == dateFromStr) {
        prevCounts[name] = (prevCounts[name] ?? 0) + qty;
      } else if (dateStr == dateToStr) {
        currCounts[name] = (currCounts[name] ?? 0) + qty;
      }
    }

    // 4. Process Purchases
    for (var row in purchases) {
      final name = _normalize(row['Purchased Product Name']);
      String dateRaw = row['Inv. Date of Purchase'] ?? ''; // CSV Column

      DateTime? invDate;
      try {
        if (dateRaw.contains('/')) {
          // Handle DD/MM/YYYY
          invDate = DateFormat('dd/MM/yyyy').parse(dateRaw);
        } else {
          invDate = DateTime.tryParse(dateRaw);
        }
      } catch (e) { continue; }

      // Logic: Purchase > Start Date AND <= End Date
      // We don't count purchases made ON the start date (as they are part of that stock count)
      // We DO count purchases made ON the end date (as they should be in stock)
      if (invDate != null && invDate.isAfter(fromDt) && !invDate.isAfter(toDt)) {
        final qty = double.tryParse(row['Total Stock In Bottles']?.toString() ?? '0') ?? 0.0;
        prodPurchases[name] = (prodPurchases[name] ?? 0) + qty;
      }
    }

    // 5. Process Sales
    for (var row in sales) {
      final name = _normalize(row['Product']);
      // Assuming 'Current Audit Date' in CSV matches the 'End Date' of the period
      final auditDateRaw = row['Current Audit Date']?.toString() ?? '';

      String csvDate = '';
      try {
        final dt = DateFormat('dd/MM/yyyy').parse(auditDateRaw);
        csvDate = DateFormat('yyyy-MM-dd').format(dt);
      } catch(e) {
        csvDate = auditDateRaw;
      }

      // If the sale report date matches our End Date, we include it
      if (csvDate == dateToStr) {
        final qty = double.tryParse(row['Total Qty Used']?.toString() ?? '0') ?? 0.0;
        prodSales[name] = (prodSales[name] ?? 0) + qty;
      }
    }

    // 6. Build List
    final allNames = {...prevCounts.keys, ...currCounts.keys, ...prodPurchases.keys, ...prodSales.keys};
    List<VarianceItem> report = [];

    for (var name in allNames) {
      if (name.isEmpty) continue;

      if ((prevCounts[name]??0) == 0 && (currCounts[name]??0) == 0 && (prodPurchases[name]??0) == 0) continue;

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
}