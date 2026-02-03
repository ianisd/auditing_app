import 'package:intl/intl.dart';

class VarianceItem {
  final String productName;
  final double previousCount;
  final double purchases;
  final double sales;
  final double currentCount;
  final double costPrice;

  // CHANGED: Now holds full objects, not just strings
  final List<Map<String, dynamic>> countEntries;
  // ADDED: Holds the master inventory details (needed to Add New Count)
  final Map<String, dynamic>? inventoryItem;

  VarianceItem({
    required this.productName,
    required this.previousCount,
    required this.purchases,
    required this.sales,
    required this.currentCount,
    required this.costPrice,
    this.countEntries = const [],
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

    // CHANGED: Store list of actual count objects
    Map<String, List<Map<String, dynamic>>> prodEntries = {};
    // CHANGED: Store inventory reference
    Map<String, Map<String, dynamic>> inventoryRef = {};

    // 2. Build Inventory Reference (for Add Button)
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      inventoryRef[name] = item;

      final cost = double.tryParse(item['Cost Price']?.toString() ?? '0') ?? 0.0;
      prodCosts[name] = cost;
    }

    // 3. Process Stock Counts
    for (var row in stocks) {
      final name = _normalize(row['productName']);
      final rawDate = row['date'].toString();
      final date = rawDate.contains('T') ? rawDate.split('T')[0] : rawDate;

      final qty = double.tryParse(row['total_bottles']?.toString() ?? '0') ?? 0.0;

      if (date == dateFromStr) {
        prevCounts[name] = (prevCounts[name] ?? 0) + qty;
      } else if (date == dateToStr) {
        currCounts[name] = (currCounts[name] ?? 0) + qty;

        // Store the full row for editing later
        if (!prodEntries.containsKey(name)) prodEntries[name] = [];
        prodEntries[name]!.add(row);
      }
    }

    // 4. Process Purchases
    final fromDt = DateTime.parse(dateFromStr);
    final toDt = DateTime.parse(dateToStr);

    for (var row in purchases) {
      final name = _normalize(row['Purchased Product Name']);

      String dateRaw = row['Inv. Date of Purchase'] ?? '';
      DateTime? invDate;
      try {
        if (dateRaw.contains('/')) {
          invDate = DateFormat('dd/MM/yyyy').parse(dateRaw);
        } else {
          invDate = DateTime.tryParse(dateRaw);
        }
      } catch (e) { continue; }

      if (invDate != null && invDate.isAfter(fromDt) && !invDate.isAfter(toDt)) {
        final qty = double.tryParse(row['Total Stock In Bottles']?.toString() ?? '0') ?? 0.0;
        prodPurchases[name] = (prodPurchases[name] ?? 0) + qty;
      }
    }

    // 5. Process Sales
    for (var row in sales) {
      final name = _normalize(row['Product']);
      final auditDateRaw = row['Current Audit Date']?.toString() ?? '';

      String csvDate = '';
      try {
        final dt = DateFormat('dd/MM/yyyy').parse(auditDateRaw);
        csvDate = DateFormat('yyyy-MM-dd').format(dt);
      } catch(e) {
        csvDate = auditDateRaw;
      }

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
        countEntries: prodEntries[name] ?? [],
        inventoryItem: inventoryRef[name], // Pass the inventory object
      ));
    }

    report.sort((a, b) => a.varianceValue.compareTo(b.varianceValue));

    return report;
  }
}