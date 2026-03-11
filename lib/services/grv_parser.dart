import 'package:csv/csv.dart';
import 'dart:math';
import '../models/grv_models.dart';

class GrvData {
  final String supplierName;
  final String invoiceNumber;
  final DateTime deliveryDate;
  final List<ParsedGrvLineItem> lineItems;

  GrvData({
    required this.supplierName,
    required this.invoiceNumber,
    required this.deliveryDate,
    required this.lineItems,
  });
}

class GrvParser {
  GrvData parse(String csvContent) {
    // 1. Sanitize Content
    String cleanContent = csvContent.replaceAll('\u0000', '').replaceAll('\uFEFF', '');
    final normalizedContent = cleanContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final rows = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
      allowInvalid: true,
    ).convert(normalizedContent);

    String supplierName = 'Unknown Supplier';
    String invoiceNumber = '';
    String goodsReceivedNumber = '';
    DateTime deliveryDate = DateTime.now();
    List<ParsedGrvLineItem> lineItems = [];

    // --- PHASE 1: Extract Metadata ---

    // A. Extract Supplier (Target Row 5)
    if (rows.length > 4) {
      // Join columns to merge split text: "DURB" | "AN" -> "DURBAN"
      String row5Content = rows[4].join('').trim();
      String upperLine = row5Content.toUpperCase();
      String cleaned = row5Content.replaceAll(RegExp(r'[,"]'), '').trim();

      if (cleaned.isNotEmpty && !upperLine.contains('BACKSTOCK')) {
        supplierName = cleaned;
      }
    }

    // B. Scan for Invoice & Date (First 20 rows)
    for (var i = 0; i < rows.length && i < 20; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;

      // 1. Normalize the row for searching labels
      // Join all cells, remove spaces to fix "Refe rence" -> "REFERENCE"
      String rawJoined = row.join(' ').trim();
      String condensed = row.join('').replaceAll(' ', '').toUpperCase(); // REFERENCE:INV123

      // 2. Extract Reference (Invoice Number)
      if (invoiceNumber.isEmpty && (condensed.contains('REFERENCE:') || condensed.contains('INV:'))) {
        // Find the original text by looking for the colon in the raw joined string
        // We use the raw string to preserve the casing of the invoice number (e.g. "inv181")
        // Strategy: Split by colon, take the last part.
        List<String> parts = row.join('').split(':');
        if (parts.length > 1) {
          // Take everything after the first colon
          String potentialInv = parts.sublist(1).join(':').trim();
          if (potentialInv.isNotEmpty) {
            invoiceNumber = potentialInv;
          }
        }
      }

      // 3. Extract Goods Received No (Fallback)
      if (goodsReceivedNumber.isEmpty && condensed.contains('GOODSRECEIVEDNO:')) {
        List<String> parts = row.join('').split(':');
        if (parts.length > 1) {
          String val = parts.sublist(1).join(':').trim();
          if (val.isNotEmpty) {
            goodsReceivedNumber = val;
          }
        }
      }

      // 4. Extract Date
      final dateMatch = RegExp(r'(\d{2})[/-](\d{2})[/-](\d{4})').firstMatch(rawJoined);
      if (dateMatch != null) {
        try {
          deliveryDate = DateTime(
              int.parse(dateMatch.group(3)!),
              int.parse(dateMatch.group(2)!),
              int.parse(dateMatch.group(1)!)
          );
        } catch (_) {}
      }
    }

    // --- PHASE 2: Finalize Invoice Number ---
    if (invoiceNumber.isEmpty) {
      if (goodsReceivedNumber.isNotEmpty) {
        // If we found a GRV Number (e.g. "183"), use it + UUID suffix
        // This ensures "183" from this year doesn't clash with "183" next year.
        String uuid = _generateHexId(4);
        invoiceNumber = '$goodsReceivedNumber-$uuid';
      } else {
        // Absolute fallback if CSV is empty/broken
        invoiceNumber = _generateHexId(8);
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

      if (rowString.contains('desc') && (rowString.contains('qty') || rowString.contains('quantity'))) {
        headerRowIndex = i;

        for (int c = 0; c < row.length; c++) {
          String header = row[c].toString().toLowerCase().trim();
          if (header == 'code') colIdxCode = c;
          else if (header.contains('desc')) colIdxDesc = c;
          else if (header == 'qty' || header == 'quantity') colIdxQty = c;
          else if (header.contains('pack')) colIdxPack = c;
          else if (header.contains('price') || header.contains('cost')) {
            if (!header.contains('total')) colIdxCost = c;
          }
        }

        if (row.length > colIdxCode && row[colIdxCode].toString().trim().isEmpty && colIdxDesc == 1) {
          colIdxCode = 0;
        }
        break;
      }
    }

    if (headerRowIndex == -1 || colIdxQty == -1) {
      return GrvData(
        supplierName: supplierName,
        invoiceNumber: invoiceNumber,
        deliveryDate: deliveryDate,
        lineItems: [],
      );
    }

    // --- PHASE 4: Parse Data Rows ---
    for (var i = headerRowIndex + 1; i < rows.length; i++) {
      final row = rows[i];

      int maxNeededIndex = [colIdxCode, colIdxDesc, colIdxQty, colIdxPack, colIdxCost].reduce(max);
      if (row.length <= maxNeededIndex) continue;

      try {
        String description = row[colIdxDesc].toString().trim();
        if (description.isEmpty || description.toLowerCase().contains('total') || description.contains('-------')) continue;

        String code = row[colIdxCode].toString().trim();
        if (code.isEmpty) code = description.hashCode.toString().substring(0, 6);

        double qty = _getDataAt(row, colIdxQty);
        double packSize = _getDataAt(row, colIdxPack);
        double cost = _getDataAt(row, colIdxCost);

        if (packSize == 0) packSize = 1;

        // Force 2 decimal places
        cost = _roundToTwoDecimal(cost);

        if (qty != 0) {
          lineItems.add(ParsedGrvLineItem(
            plu: code,
            description: description,
            quantityCases: qty.toInt(),
            unitsPerCase: packSize.toInt(),
            pricePerUnit: cost,
          ));
        }
      } catch (e) {
        // Skip malformed rows
      }
    }

    return GrvData(
      supplierName: supplierName,
      invoiceNumber: invoiceNumber,
      deliveryDate: deliveryDate,
      lineItems: lineItems,
    );
  }

  double _getDataAt(List<dynamic> row, int index) {
    if (index < 0 || index >= row.length) return 0.0;
    return _parseDouble(row[index]);
  }

  double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    String s = value.toString();
    bool isNegative = s.endsWith('-');

    s = s.replaceAll(RegExp(r'[^\d.-]'), '');
    double val = double.tryParse(s) ?? 0.0;

    if (isNegative && val > 0) return -val;
    return val;
  }

  double _roundToTwoDecimal(double value) {
    return (value * 100).roundToDouble() / 100;
  }

  String _generateHexId(int length) {
    final rnd = Random();
    final bytes = List<int>.generate((length / 2).ceil(), (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, length);
  }
}