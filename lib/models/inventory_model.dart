import 'package:hive/hive.dart';

@HiveType(typeId: 1)
class InventoryItem {
  @HiveField(0)
  final String barcode;

  @HiveField(1)
  final String productName;

  @HiveField(2)
  final String mainCategory;

  @HiveField(3)
  final String category;

  @HiveField(4)
  final double singleUnitVolume;

  @HiveField(5)
  final String uom;

  @HiveField(6)
  final double gradient;

  @HiveField(7)
  final double intercept;

  @HiveField(8)
  final String packSize;

  @HiveField(9)
  final double costPrice;

  InventoryItem({
    required this.barcode,
    required this.productName,
    required this.mainCategory,
    required this.category,
    required this.singleUnitVolume,
    required this.uom,
    required this.gradient,
    required this.intercept,
    required this.packSize,
    required this.costPrice,
  });

  factory InventoryItem.fromJson(Map<String, dynamic> json) {
    return InventoryItem(
      barcode: json['Barcode']?.toString() ?? '',
      // FLEXIBLE: Checks for 'Inventory Product Name' OR 'Product Name'
      productName: json['Inventory Product Name']?.toString()
          ?? json['Product Name']?.toString()
          ?? 'Unknown Product',
      mainCategory: json['Main Category']?.toString() ?? '',
      category: json['Category']?.toString() ?? '',
      singleUnitVolume: double.tryParse(json['Single Unit Volume']?.toString() ?? '0') ?? 0.0,
      uom: json['UoM']?.toString() ?? '',
      gradient: double.tryParse(json['Gradient']?.toString() ?? '0') ?? 0.0,
      intercept: double.tryParse(json['Intercept']?.toString() ?? '0') ?? 0.0,
      packSize: json['Pack Size']?.toString() ?? '',
      costPrice: double.tryParse(json['Cost Price']?.toString() ?? '0') ?? 0.0,
    );
  }
}