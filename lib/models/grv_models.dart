import 'package:intl/intl.dart';

class GrvInvoice {
  final String invoiceDetailsID;
  final String invoiceNumber;
  final String supplierID;
  final String supplierName;
  final DateTime dateOfPurchase;
  final DateTime deliveryDate;
  final double totalExclVat;
  final String syncStatus;

  GrvInvoice({
    required this.invoiceDetailsID,
    required this.invoiceNumber,
    required this.supplierID,
    required this.supplierName,
    required this.dateOfPurchase,
    required this.deliveryDate,
    required this.totalExclVat,
    required this.syncStatus,
  });

  // Convert to Map for Hive storage (matches your existing pattern)
  Map<String, dynamic> toJson() => {
    'invoiceDetailsID': invoiceDetailsID,
    'Invoice Number': invoiceNumber,
    'supplierID': supplierID,
    'Supplier Name': supplierName,
    'Date of Purchase': dateOfPurchase.toIso8601String(),
    'Delivery Date': deliveryDate.toIso8601String(),
    'Total Cost Ex Vat': totalExclVat,
    'syncStatus': syncStatus,
  };

  // Create from Hive Map (matches your existing _safeCast pattern)
  factory GrvInvoice.fromJson(Map<String, dynamic> json) {
    return GrvInvoice(
      invoiceDetailsID: json['invoiceDetailsID']?.toString() ?? '',
      invoiceNumber: json['Invoice Number']?.toString() ?? '',
      supplierID: json['supplierID']?.toString() ?? '',
      supplierName: json['Supplier Name']?.toString() ?? json['Supplier']?.toString() ?? '',
      dateOfPurchase: _parseDate(json['Date of Purchase']) ?? DateTime.now(),
      deliveryDate: _parseDate(json['Delivery Date']) ?? DateTime.now(),
      totalExclVat: (json['Total Cost Ex Vat'] as num?)?.toDouble() ?? 0.0,
      syncStatus: json['syncStatus']?.toString() ?? 'pending',
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) {
      try {
        return DateTime.tryParse(value) ??
            DateFormat('yyyy-MM-dd').parse(value, true);
      } catch (e) {
        return null;
      }
    }
    return null;
  }
}

class GrvLineItem {
  final String plu;
  final String description;
  final int quantityCases;
  final int unitsPerCase;
  final double pricePerUnit;
  final String? productName;
  final String? barcode;

  GrvLineItem({
    required this.plu,
    required this.description,
    required this.quantityCases,
    required this.unitsPerCase,
    required this.pricePerUnit,
    this.productName,
    this.barcode,
  });

  double get costPerCase => pricePerUnit * unitsPerCase;
  int get totalUnits => quantityCases * unitsPerCase;
  double get totalValue => costPerCase * quantityCases;
  bool get isMatched => productName != null;

  // Convert to Purchases table format (reuses existing schema)
  Map<String, dynamic> toPurchaseRecord({
    required String invoiceDetailsID,
    required String supplierID,
    required String supplierName,
    required DateTime deliveryDate,
  }) {
    return {
      'purchases_ID': DateTime.now().millisecondsSinceEpoch.toString(),
      'invoiceDetailsID': invoiceDetailsID,
      'supplierID': supplierID,
      'Supplier': supplierName,
      'Barcode': barcode ?? '',
      'Purchased Product Name': productName ?? description,
      'purSupplierBottleID': plu, // CRITICAL: Link to cost lookup
      'Cost Per Bottle': pricePerUnit, // Per single unit (not case)
      'Stock Delivery Date': deliveryDate.toIso8601String(),
      'Case/Pack Size': 'Case $unitsPerCase',
      'Qty Purchased': quantityCases.toDouble(),
      'Purchases Bottles': totalUnits.toDouble(),
      'Cost of Purchases': totalValue,
      'syncStatus': 'pending',
    };
  }
}