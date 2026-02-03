import 'package:intl/intl.dart';

class VarianceItem {
  final String productName;
  final double previousCount;
  final double purchases;
  final double sales;
  final double currentCount;
  final double costPrice;
  final List<String> locations; // To show where it was counted

  VarianceItem({
    required this.productName,
    required this.previousCount,
    required this.purchases,
    required this.sales,
    required this.currentCount,
    required this.costPrice,
    this.locations = const [],
  });

  double get theoreticalStock => previousCount + purchases - sales;
  double get variance => currentCount - theoreticalStock;
  double get varianceValue => variance * costPrice;
}

class VarianceService {

  // Normalize strings for matching (Trim + Lowercase)
  String _normalize(String? input) => input?.toString().toLowerCase().trim() ?? '';

  List<VarianceItem> calculateReport({
    required List<Map<String, dynamic>> stocks,
    required List<Map<String, dynamic>> purchases,
    required List<Map<String, dynamic>> sales,
    required List<Map<String, dynamic>> inventory,
    required String dateFromStr, // YYYY-MM-DD
    required String dateToStr,   // YYYY-MM-DD
  }) {
    // 1. Dictionaries to hold data
    Map<String, double> prevCounts = {};
    Map<String, double> currCounts = {};
    Map<String, double> prodPurchases = {};
    Map<String, double> prodSales = {};
    Map<String, double> prodCosts = {};
    Map<String, Set<String>> prodLocations = {};

    // 2. Process Stock Counts (Previous & Current)
    for (var row in stocks) {
      final name = _normalize(row['productName']);
      // Handle date format differences (ISO vs Simple)
      final rawDate = row['date'].toString();
      final date = rawDate.contains('T') ? rawDate.split('T')[0] : rawDate;

      final qty = double.tryParse(row['total_bottles']?.toString() ?? '0') ?? 0.0;
      final loc = row['location']?.toString() ?? 'Unknown';

      if (date == dateFromStr) {
        prevCounts[name] = (prevCounts[name] ?? 0) + qty;
      } else if (date == dateToStr) {
        currCounts[name] = (currCounts[name] ?? 0) + qty;

        if (!prodLocations.containsKey(name)) prodLocations[name] = {};
        prodLocations[name]!.add('$loc: $qty');
      }
    }

    // 3. Process Purchases
    // Logic: Invoice Date > From AND <= To
    final fromDt = DateTime.parse(dateFromStr);
    final toDt = DateTime.parse(dateToStr);

    for (var row in purchases) {
      final name = _normalize(row['Purchased Product Name']);

      // Parse "DD/MM/YYYY" from CSV
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

    // 4. Process Sales
    // Logic: Match "Current Audit Date" column to dateToStr
    for (var row in sales) {
      final name = _normalize(row['Product']);
      final auditDateRaw = row['Current Audit Date']?.toString() ?? '';

      // Convert CSV "DD/MM/YYYY" to "YYYY-MM-DD" for comparison
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

    // 5. Get Costs
    for (var item in inventory) {
      final name = _normalize(item['Inventory Product Name']);
      final cost = double.tryParse(item['Cost Price']?.toString() ?? '0') ?? 0.0;
      prodCosts[name] = cost;
    }

    // 6. Build List
    final allNames = {...prevCounts.keys, ...currCounts.keys, ...prodPurchases.keys, ...prodSales.keys};
    List<VarianceItem> report = [];

    for (var name in allNames) {
      if (name.isEmpty) continue;

      // Skip if absolutely no activity
      if ((prevCounts[name]??0) == 0 && (currCounts[name]??0) == 0 && (prodPurchases[name]??0) == 0) continue;

      // Re-capitalize name from inventory if possible, else use map key
      String displayName = name.toUpperCase(); // Placeholder
      // Try find original casing from inventory keys? (Optimization for later)

      report.add(VarianceItem(
        productName: name,
        previousCount: prevCounts[name] ?? 0,
        purchases: prodPurchases[name] ?? 0,
        sales: prodSales[name] ?? 0,
        currentCount: currCounts[name] ?? 0,
        costPrice: prodCosts[name] ?? 0,
        locations: prodLocations[name]?.toList() ?? [],
      ));
    }

    // Sort by Variance Value (Big losses at top)
    report.sort((a, b) => a.varianceValue.compareTo(b.varianceValue));

    return report;
  }
}