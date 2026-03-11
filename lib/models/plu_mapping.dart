import 'package:hive/hive.dart';

part 'plu_mapping.g.dart';  // Add this line

@HiveType(typeId: 10) // Use a unique typeId not used elsewhere
class PluMapping {
  @HiveField(0)
  final String csvPlu;           // PLU from uploaded CSV (e.g., "12")

  @HiveField(1)
  final String csvDescription;    // Description from CSV (e.g., "VEUVE CLIQUOT - YELLOW L")

  @HiveField(2)
  final String correctPlu;        // Correct PLU from ItemSales (e.g., "1423")

  @HiveField(3)
  final String productName;       // Product name from inventory

  @HiveField(4)
  final String supplierId;        // Supplier-specific mapping

  @HiveField(5)
  final DateTime createdAt;

  @HiveField(6)
  final int confidence;           // How many times used successfully

  PluMapping({
    required this.csvPlu,
    required this.csvDescription,
    required this.correctPlu,
    required this.productName,
    required this.supplierId,
    required this.createdAt,
    this.confidence = 1,
  });

  Map<String, dynamic> toJson() => {
    'csvPlu': csvPlu,
    'csvDescription': csvDescription,
    'correctPlu': correctPlu,
    'productName': productName,
    'supplierId': supplierId,
    'createdAt': createdAt.toIso8601String(),
    'confidence': confidence,
  };

  factory PluMapping.fromJson(Map<String, dynamic> json) => PluMapping(
    csvPlu: json['csvPlu']?.toString() ?? '',
    csvDescription: json['csvDescription']?.toString() ?? '',
    correctPlu: json['correctPlu']?.toString() ?? '',
    productName: json['productName']?.toString() ?? '',
    supplierId: json['supplierId']?.toString() ?? '',
    createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
    confidence: (json['confidence'] as num?)?.toInt() ?? 1,
  );
}