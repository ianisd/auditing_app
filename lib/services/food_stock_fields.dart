/// Food uses grams for stored counts and grams per portion for inventory size.
/// Existing spreadsheet column names remain unchanged.
class FoodStockFields {
  static const groups = <String, List<String>>{
    'Meat': ['Beef', 'Poultry', 'Pork', 'Lamb', 'Game Meat', 'Processed Meat', 'Meat'],
    'Seafood': ['Fish', 'Shellfish', 'Seafood'],
    'Produce': ['Vegetables', 'Fruit', 'Fresh Herbs'],
    'Dairy & Eggs': ['Dairy', 'Cheese', 'Eggs'],
    'Bakery & Grains': ['Bakery', 'Bread', 'Rice', 'Pasta', 'Flour', 'Grains'],
    'Pantry': ['Dry Goods', 'Pulses', 'Nuts & Seeds', 'Spices', 'Seasonings', 'Oils & Fats', 'Sauces & Condiments', 'Sugar & Sweeteners'],
    'Prepared Food': ['Prepared Food', 'Sides', 'Desserts', 'Prepared Sauces'],
  };

  static String key(dynamic value) => (value ?? '').toString().trim().toLowerCase();
  static double number(dynamic value) => double.tryParse((value ?? '').toString().trim().replaceAll(',', '.')) ?? 0;

  static String? mainCategory(String category) {
    for (final entry in groups.entries) {
      if (entry.value.any((c) => key(c) == key(category))) return entry.key;
    }
    return null;
  }

  static bool isFood(Map<String, dynamic>? product) {
    if (product == null) return false;
    final category = key(product['Category'] ?? product['category']);
    final main = key(product['Main Category'] ?? product['mainCategory']);
    if (main == 'non-food' || category == 'consumables') return false;
    return mainCategory(category) != null ||
        groups.keys.any((g) => key(g) == main) ||
        ['food', 'proteins', 'perishables'].contains(main);
  }

  static double portionGrams(Map<String, dynamic>? product) {
    if (product == null) return 0;
    final size = number(product['Single Unit Volume'] ?? product['singleUnitVolume']);
    final unit = key(product['UoM'] ?? product['uom']);
    if (!size.isFinite || size <= 0) return 0;
    if (['g', 'gram', 'grams'].contains(unit)) return size;
    if (['kg', 'kilogram', 'kilograms'].contains(unit)) return size * 1000;
    return 0; // Never assume that millilitres are grams.
  }

  static double inputGrams(String input, String? unit) =>
      number(input) * (unit == 'Loose (kg)' ? 1000 : 1);

  static double portions(double grams, Map<String, dynamic>? product) {
    final portion = portionGrams(product);
    if (!grams.isFinite || grams < 0 || portion <= 0) return 0;
    return grams / portion;
  }

  /// Explicitly supports the supplied AppSheet weight(g) and old Flutter loose rows.
  static double recordedGrams(Map<String, dynamic> row) {
    final pack = key(row['pack_size'] ?? row['Case/Pack Size']);
    final count = number(row['count'] ?? row['Count']);
    final weight = number(row['weight'] ?? row['Weight (g)']);
    if ((count == 0 || pack == 'weight (g)') && weight != 0 &&
        ['weight (g)', 'loose (g)', 'loose (kg)'].contains(pack)) {
      return weight * (pack == 'loose (kg)' ? 1000 : 1);
    }
    return count;
  }

  static bool isWeightRecord(Map<String, dynamic> row) =>
      ['weight (g)', 'loose (g)', 'loose (kg)'].contains(key(row['pack_size'] ?? row['Case/Pack Size']));
}
