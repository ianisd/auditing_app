import 'package:csv/csv.dart';
import 'dart:math';
import '../models/grv_models.dart';

class GrvData {
  final String supplierName;
  final String invoiceNumber;
  final String grvReference;
  final DateTime deliveryDate;
  final List<ParsedGrvLineItem> lineItems;

  GrvData({
    required this.supplierName,
    required this.invoiceNumber,
    this.grvReference = '',
    required this.deliveryDate,
    required this.lineItems,
  });
}

class GrvParser {
  GrvData parse(String csvContent) {
    // 1. Sanitize Content
    String cleanContent = csvContent
        .replaceAll('\u0000', '')
        .replaceAll('\uFEFF', '');
    final normalizedContent = cleanContent
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    final rows = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
      allowInvalid: true,
    ).convert(normalizedContent);

    String supplierName = 'Unknown Supplier';
    String invoiceNumber = '';
    String goodsReceivedNumber = '';
    String grvReference = '';
    DateTime deliveryDate = DateTime.now();
    List<ParsedGrvLineItem> lineItems = [];

    // --- PHASE 1: Extract Metadata ---

    // A. Extract Supplier (Target Row 5)
    if (rows.length > 4) {
      String row5Content = rows[4].join('').trim();
      String upperLine = row5Content.toUpperCase();
      String cleaned = row5Content.replaceAll(RegExp(r'[,"]'), '').trim();

      if (cleaned.isNotEmpty && !upperLine.contains('BACKSTOCK')) {
        supplierName = cleaned;
      }
    }

    // B. Scan for Invoice, GRV Reference & Date (First 20 rows)
    for (var i = 0; i < rows.length && i < 20; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;

      String rawJoined = row.join(' ').trim();
      String condensed = row.join('').replaceAll(' ', '').toUpperCase();

      // Extract Reference (Invoice Number)
      if (invoiceNumber.isEmpty &&
          (condensed.contains('REFERENCE:') || condensed.contains('INV:'))) {
        List<String> parts = row.join('').split(':');
        if (parts.length > 1) {
          String potentialInv = parts.sublist(1).join(':').trim();
          if (potentialInv.isNotEmpty) {
            invoiceNumber = potentialInv;
          }
        }
      }

      // Extract GRV Reference (Goods Received No)
      if (grvReference.isEmpty &&
          (condensed.contains('GOODSRECEIVEDNO:') ||
              condensed.contains('GRV:') ||
              condensed.contains('GOODS RECEIVED'))) {
        List<String> parts = row.join('').split(':');
        if (parts.length > 1) {
          String val = parts.sublist(1).join(':').trim();
          if (val.isNotEmpty) {
            grvReference = val;
            print('📋 Extracted GRV Reference: $grvReference');
          }
        }
      }

      // Also check for GRV in separate columns
      if (grvReference.isEmpty) {
        for (int c = 0; c < row.length; c++) {
          String cell = row[c].toString().trim().toUpperCase();
          if (cell.contains('GRV') || cell.contains('GOODS RECEIVED')) {
            if (c + 1 < row.length) {
              String val = row[c + 1].toString().trim();
              if (val.isNotEmpty && val != cell) {
                grvReference = val;
                print('📋 Extracted GRV Reference from column: $grvReference');
                break;
              }
            }
          }
        }
      }

      // Extract Goods Received No (Fallback for invoice number)
      if (goodsReceivedNumber.isEmpty &&
          condensed.contains('GOODSRECEIVEDNO:')) {
        List<String> parts = row.join('').split(':');
        if (parts.length > 1) {
          String val = parts.sublist(1).join(':').trim();
          if (val.isNotEmpty) {
            goodsReceivedNumber = val;
          }
        }
      }

      // 🔥 FIXED: Extract Date - Try multiple formats
      DateTime? parsedDate = _parseDate(rawJoined);
      if (parsedDate != null) {
        deliveryDate = parsedDate;
        print('📅 Parsed delivery date: $deliveryDate');
      }
    }

    // --- PHASE 2: Finalize Invoice Number & GRV Reference ---

    // If no GRV reference found, use the invoice number as fallback
    if (grvReference.isEmpty) {
      grvReference = invoiceNumber;
      print('📋 Using Invoice Number as GRV Reference: $grvReference');
    }

    if (invoiceNumber.isEmpty) {
      if (goodsReceivedNumber.isNotEmpty) {
        String uuid = _generateHexId(4);
        invoiceNumber = '$goodsReceivedNumber-$uuid';
        if (grvReference.isEmpty) grvReference = goodsReceivedNumber;
      } else {
        invoiceNumber = _generateHexId(8);
        if (grvReference.isEmpty) grvReference = invoiceNumber;
      }
    }

    // --- PHASE 3: Dynamic Column Mapping ---
    int headerRowIndex = -1;
    int colIdxCode = 0;
    int colIdxDesc = 1;
    int colIdxQty = -1;
    int colIdxPack = -1;
    int colIdxCost = -1;

    for (int i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.length < 3) continue;

      final rowString = row.join(',').toLowerCase();

      if (rowString.contains('desc') &&
          (rowString.contains('qty') || rowString.contains('quantity'))) {
        headerRowIndex = i;

        for (int c = 0; c < row.length; c++) {
          String header = row[c].toString().toLowerCase().trim();
          if (header == 'code') {
            colIdxCode = c;
          } else if (header.contains('desc'))
            colIdxDesc = c;
          else if (header == 'qty' || header == 'quantity')
            colIdxQty = c;
          else if (header.contains('pack'))
            colIdxPack = c;
          else if (header.contains('price') || header.contains('cost')) {
            if (!header.contains('total')) colIdxCost = c;
          }
        }

        if (row.length > colIdxCode &&
            row[colIdxCode].toString().trim().isEmpty &&
            colIdxDesc == 1) {
          colIdxCode = 0;
        }
        break;
      }
    }

    if (headerRowIndex == -1 || colIdxQty == -1) {
      return GrvData(
        supplierName: supplierName,
        invoiceNumber: invoiceNumber,
        grvReference: grvReference,
        deliveryDate: deliveryDate,
        lineItems: [],
      );
    }

    // --- PHASE 4: Parse Data Rows ---
    for (var i = headerRowIndex + 1; i < rows.length; i++) {
      final row = rows[i];

      int maxNeededIndex = [
        colIdxCode,
        colIdxDesc,
        colIdxQty,
        colIdxPack,
        colIdxCost,
      ].reduce(max);
      if (row.length <= maxNeededIndex) continue;

      try {
        String description = row[colIdxDesc].toString().trim();
        if (description.isEmpty ||
            description.toLowerCase().contains('total') ||
            description.contains('-------'))
          continue;

        String code = row[colIdxCode].toString().trim();
        if (code.isEmpty)
          code = description.hashCode.toString().substring(0, 6);

        double qty = _getDataAt(row, colIdxQty);
        double packSize = _getDataAt(row, colIdxPack);
        double cost = _getDataAt(row, colIdxCost);

        if (packSize == 0) packSize = 1;

        cost = _roundToTwoDecimal(cost);

        if (qty != 0) {
          lineItems.add(
            ParsedGrvLineItem(
              plu: code,
              description: description,
              quantityCases: qty.toInt(),
              unitsPerCase: packSize.toInt().abs(),
              pricePerUnit: cost.abs(),
            ),
          );
        }
      } catch (e) {
        // Skip malformed rows
      }
    }

    return GrvData(
      supplierName: supplierName,
      invoiceNumber: invoiceNumber,
      grvReference: grvReference,
      deliveryDate: deliveryDate,
      lineItems: lineItems,
    );
  }

  // 🔥 NEW: Robust date parser supporting multiple formats
  DateTime? _parseDate(String rawJoined) {
    // Try YYYY/MM/DD format first (your CSV format)
    final ymdMatch = RegExp(
      r'(\d{4})[/-](\d{2})[/-](\d{2})',
    ).firstMatch(rawJoined);
    if (ymdMatch != null) {
      try {
        final year = int.parse(ymdMatch.group(1)!);
        final month = int.parse(ymdMatch.group(2)!);
        final day = int.parse(ymdMatch.group(3)!);
        // Validate the date is reasonable
        if (year > 2000 &&
            year < 2100 &&
            month >= 1 &&
            month <= 12 &&
            day >= 1 &&
            day <= 31) {
          return DateTime(year, month, day);
        }
      } catch (_) {}
    }

    // Try DD/MM/YYYY format as fallback
    final dmyMatch = RegExp(
      r'(\d{2})[/-](\d{2})[/-](\d{4})',
    ).firstMatch(rawJoined);
    if (dmyMatch != null) {
      try {
        final day = int.parse(dmyMatch.group(1)!);
        final month = int.parse(dmyMatch.group(2)!);
        final year = int.parse(dmyMatch.group(3)!);
        // Validate the date is reasonable
        if (year > 2000 &&
            year < 2100 &&
            month >= 1 &&
            month <= 12 &&
            day >= 1 &&
            day <= 31) {
          return DateTime(year, month, day);
        }
      } catch (_) {}
    }

    // Try MM/DD/YYYY format as last resort
    final mdyMatch = RegExp(
      r'(\d{2})[/-](\d{2})[/-](\d{4})',
    ).firstMatch(rawJoined);
    if (mdyMatch != null) {
      try {
        final month = int.parse(mdyMatch.group(1)!);
        final day = int.parse(mdyMatch.group(2)!);
        final year = int.parse(mdyMatch.group(3)!);
        if (year > 2000 &&
            year < 2100 &&
            month >= 1 &&
            month <= 12 &&
            day >= 1 &&
            day <= 31) {
          return DateTime(year, month, day);
        }
      } catch (_) {}
    }

    return null; // No valid date found
  }

  double _getDataAt(List<dynamic> row, int index) {
    if (index < 0 || index >= row.length) return 0.0;
    return _parseDouble(row[index]);
  }

  // ROBUST NUMBER PARSER (Handles negative signs leading/trailing, spaces, and formatting)
  double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    String s = value.toString().trim();
    if (s.isEmpty) return 0.0;

    // Check for negative indicators
    bool isNegative =
        s.startsWith('-') ||
        s.endsWith('-') ||
        (s.startsWith('(') && s.endsWith(')'));

    // Strip spaces and all non-numeric characters except digits and '.'
    String clean = s.replaceAll(RegExp(r'[^\d.]'), '');
    double val = double.tryParse(clean) ?? 0.0;

    return isNegative ? -val : val;
  }

  double _roundToTwoDecimal(double value) {
    return (value * 100).roundToDouble() / 100;
  }

  String _generateHexId(int length) {
    final rnd = Random();
    final bytes = List<int>.generate(
      (length / 2).ceil(),
      (_) => rnd.nextInt(256),
    );
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, length);
  }
}
