import 'dart:core';

/// Builds a per-product retail price index from ItemSales.
///
/// Priority order must match the Google Sheet's `validCats` array exactly,
/// so the app and the sheet always resolve a product to the same bottle price.
///
/// FIX: the sales sheet already exposes a normalized "Bottle Price" column.
/// Do NOT multiply by Bottle UoM again for Shots/Tot measures — that was
/// double-counting and produced fabricated costs (e.g. R10,500 for Olmeca).
///
/// The returned map is productName (lowercased, trimmed) → bottle retail price.
Map<String, double> buildSalesPriceIndex({
  required List<Map<String, dynamic>> itemSalesData,
  required List<Map<String, dynamic>> inventory,
  required RegExp exclusionRegex,
  double Function(dynamic) safeDouble = _defaultSafeDouble,
}) {
  const priorityMap = <String, int>{
    'spirit bottle': 1,
    'fermented wine': 2,
    'spirit tot': 3,
    'alcoholic beverage': 4,
    'beverage': 5,
    'fermented wine glass': 6,
    'mixer bottle': 7,
    'mixer tot': 8,
  };
  const int defaultPriority = 99;

  final bestPriority = <String, int>{};
  final index = <String, double>{};

  // inventory is currently unused but kept for future fallback logic.
  // ignore: unused_local_variable
  final inventoryByName = <String, Map<String, dynamic>>{};
  for (var p in inventory) {
    final name =
        p['Inventory Product Name']?.toString().toLowerCase().trim() ?? '';
    if (name.isNotEmpty && !inventoryByName.containsKey(name)) {
      inventoryByName[name] = p;
    }
  }

  for (var row in itemSalesData) {
    final name = row['Product']?.toString().toLowerCase().trim() ?? '';
    if (name.isEmpty) continue;

    final mainCat = row['Main Category']?.toString().toLowerCase().trim() ?? '';
    if (exclusionRegex.hasMatch(mainCat)) continue;

    final bottlePrice = safeDouble(
      row['Bottle Price'] ??
          row['Bottle P'] ??
          row['BottleP'] ??
          row['Bottle Price '] ??
          row['Bottle P...'],
    );
    if (bottlePrice <= 0) continue;

    final priority = priorityMap[mainCat] ?? defaultPriority;
    if (!bestPriority.containsKey(name) || priority < bestPriority[name]!) {
      index[name] = bottlePrice;
      bestPriority[name] = priority;
    } else if (priority == bestPriority[name]! && bottlePrice > index[name]!) {
      index[name] = bottlePrice;
    }
  }

  return index;
}

double _defaultSafeDouble(dynamic v) {
  if (v == null) return 0.0;
  if (v is int) return v.toDouble();
  if (v is double) return v;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0.0;
}
