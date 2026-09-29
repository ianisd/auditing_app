// Shared lossless field mapping for both sheet and live-document reads.
const stockFieldAliases = <String, List<String>>{
  'id': ['id', 'stock_id', 'stockId', 'stockTake_ID'],
  'date': ['date', 'Date'],
  'barcode': ['barcode', 'Barcode'],
  'productName': ['productName', 'Product Name'],
  'mainCategory': ['mainCategory', 'Main Category'],
  'category': ['category', 'Category'],
  'singleUnitVolume': ['singleUnitVolume', 'Single Unit Volume'],
  'uom': ['uom', 'UoM'],
  'gradient': ['gradient', 'Gradient'],
  'intercept': ['intercept', 'Intercept'],
  'volume_ml': ['volume_ml', 'Volume (ml)'],
  'location': ['location', 'Location'],
  'pack_size': ['pack_size', 'Case/Pack Size'],
  'count': ['count', 'Count'],
  'weight': ['weight', 'Weight (g)'],
  'open_tots': ['open_tots', 'Open Tots'],
  'total_bottles': ['total_bottles', 'Total Bottles on Hand'],
  'total_shots': ['total_shots', 'Total Shots/25ml'],
  'total_ml': ['total_ml', 'Total mL'],
  'cost_value': ['cost_value', 'Cost Value'],
  'retail_value': ['retail_value', 'Retail Value'],
  'createdAt': ['createdAt', 'created_at'],
  'updatedAt': ['updatedAt', 'updated_at'],
};

Map<String, dynamic> normalizeStockRecord(Map<String, dynamic> input) {
  final source = <String, dynamic>{
    for (final e in input.entries) e.key.trim(): e.value,
  };
  final result = Map<String, dynamic>.from(source);
  for (final entry in stockFieldAliases.entries) {
    dynamic value;
    for (final alias in entry.value) {
      if (source[alias] != null) {
        value = source[alias];
        break;
      }
    }
    for (final alias in entry.value) {
      result.remove(alias);
    }
    if (value != null) result[entry.key] = value;
  }
  if (result['id'] != null) {
    result['id'] = result['id'].toString();
    result['stock_id'] = result['id'];
  }
  return result;
}

Map<String, dynamic> mergeStockRecord(
  Map<String, dynamic> previous,
  Map<String, dynamic> incoming,
) => {...normalizeStockRecord(previous), ...normalizeStockRecord(incoming)};

double? stockNumber(dynamic value) {
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse('${value ?? ''}'.trim());
  return parsed != null && parsed.isFinite ? parsed : null;
}

Map<String, dynamic> stockProductForEdit(
  Map<String, dynamic> saved,
  Map<String, dynamic>? inventory,
) {
  final row = normalizeStockRecord(saved);
  final product = <String, dynamic>{...?inventory};
  const keys = {
    'barcode': 'Barcode',
    'productName': 'Inventory Product Name',
    'mainCategory': 'Main Category',
    'category': 'Category',
    'singleUnitVolume': 'Single Unit Volume',
    'uom': 'UoM',
    'gradient': 'Gradient',
    'intercept': 'Intercept',
  };
  for (final entry in keys.entries) {
    final value = row[entry.key];
    if (value != null && value.toString().trim().isNotEmpty)
      product[entry.value] = value;
  }
  return product;
}

// Preserve the recorded valuation basis on quantity edits. A zero total is a
// valid value; missing values are not manufactured as zero.
double? stockRecordedUnitValue(Map<String, dynamic> saved, String field) {
  final row = normalizeStockRecord(saved);
  final units = stockNumber(row['total_bottles']);
  final total = stockNumber(row[field]);
  if (units == null || units == 0 || total == null) return null;
  return total / units;
}

void validateStockEdit(
  Map<String, dynamic> saved,
  Map<String, dynamic>? product,
  double resolvedCost,
  double resolvedRetail,
) {
  if (product == null || product.isEmpty)
    throw StateError(
      'Product details are unavailable. Restore the original count or its inventory details before saving.',
    );
  for (final field in ['Main Category', 'Category', 'UoM']) {
    if ((product[field]?.toString().trim() ?? '').isEmpty)
      throw StateError(
        'Missing $field. The count has not been saved; restore its product details first.',
      );
  }
  if ((stockNumber(product['Single Unit Volume']) ?? 0) <= 0)
    throw StateError(
      'Missing or invalid unit size. The count has not been saved; restore its product details first.',
    );
  if (stockRecordedUnitValue(saved, 'cost_value') == null &&
          resolvedCost <= 0 ||
      stockRecordedUnitValue(saved, 'retail_value') == null &&
          resolvedRetail <= 0) {
    throw StateError(
      'The original valuation basis is unavailable. Restore the original count or load valid product pricing before saving.',
    );
  }
}
