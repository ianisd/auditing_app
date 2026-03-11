import 'package:intl/intl.dart';

// ===========================================================================
// GRV INVOICE MODEL
// ===========================================================================

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

// ===========================================================================
// GRV PARSED LINE ITEM (From CSV - contains PLU)
// ===========================================================================

class ParsedGrvLineItem {
  final String plu;           // PLU from CSV - only used for matching
  final String description;
  final int quantityCases;
  final int unitsPerCase;
  final double pricePerUnit;

  // These get filled after matching
  String? productName;
  String? barcode;
  String? supplierBottleID;   // ← This gets set AFTER matching, from MasterCosts

  ParsedGrvLineItem({
    required this.plu,
    required this.description,
    required this.quantityCases,
    required this.unitsPerCase,
    required this.pricePerUnit,
  });

  double get costPerCase => pricePerUnit * unitsPerCase;
  int get totalUnits => quantityCases * unitsPerCase;
  double get totalValue => costPerCase * quantityCases;
  bool get isMatched => productName != null;

  // Convert to Purchase record AFTER matching
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
      // ✅ CORRECT: Use supplierBottleID from MasterCosts, NOT the PLU
      'supplierBottleID': supplierBottleID ?? '',
      'purSupplierBottleID': supplierBottleID ?? '', // Keep both for compatibility
      'Cost Per Bottle': pricePerUnit,
      'Stock Delivery Date': deliveryDate.toIso8601String(),
      'Case/Pack Size': 'Case $unitsPerCase',
      'Qty Purchased': quantityCases.toDouble(),
      'Purchases Bottles': totalUnits.toDouble(),
      'Cost of Purchases': totalValue,
      'syncStatus': 'pending',
    };
  }
}

// ===========================================================================
// GRV LINE ITEM DISPLAY MODEL (Used for UI display)
// ===========================================================================

class GrvLineItemDisplay {
  final String? plu;           // From CSV, for display only
  final String description;
  final int quantityCases;
  final int unitsPerCase;
  final double pricePerUnit;

  String? productName;         // Filled after matching
  String? barcode;             // Filled after matching
  String? supplierBottleID;    // ← The REAL ID for cost lookup
  String? matchedBy;           // 🔴 NEW: Track how we matched (saved_mapping, plu_direct, fuzzy, manual)
  late final double costPerCase;

  GrvLineItemDisplay({
    this.plu,
    required this.description,
    required this.quantityCases,
    required this.unitsPerCase,
    required this.pricePerUnit,
    this.productName,
    this.barcode,
    this.supplierBottleID,
    this.matchedBy,
  }) {
    costPerCase = pricePerUnit * unitsPerCase;
  }

  int get totalUnits => quantityCases * unitsPerCase;
  double get totalValue => costPerCase;
  bool get isMatched => productName != null && productName!.isNotEmpty;

  // Convert to ParsedGrvLineItem for saving
  ParsedGrvLineItem toParsedLineItem() {
    final item = ParsedGrvLineItem(
      plu: plu ?? '',
      description: description,
      quantityCases: quantityCases,
      unitsPerCase: unitsPerCase,
      pricePerUnit: pricePerUnit,
    );
    // Copy over matched data
    item.productName = productName;
    item.barcode = barcode;
    item.supplierBottleID = supplierBottleID;
    return item;
  }
}