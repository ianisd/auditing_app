import 'package:csv/csv.dart';

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

class ParsedGrvLineItem {
  final String plu;
  final String description;
  final int quantityCases;
  final int unitsPerCase;
  final double pricePerUnit;

  // Derived after PLU matching (initially null)
  String? productName;
  String? barcode;
  double? costPerCase;

  ParsedGrvLineItem({
    required this.plu,
    required this.description,
    required this.quantityCases,
    required this.unitsPerCase,
    required this.pricePerUnit,
  }) : costPerCase = pricePerUnit * unitsPerCase;
}

class GrvParser {
  GrvData parse(String csvContent) {
    final normalizedContent = csvContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final rows = const CsvToListConverter(
      eol: '\n',
      fieldDelimiter: ',',
      textDelimiter: '"',
      shouldParseNumbers: false,
    ).convert(normalizedContent);

    String supplierName = 'Unknown Supplier';
    String invoiceNumber = 'INV-${DateTime.now().millisecondsSinceEpoch}';
    DateTime deliveryDate = DateTime.now();

    // ✅ FIXED: Handle your exact CSV format (metadata in specific rows)
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;

      final cell = row[0].toString().trim();

      // Extract supplier from row 4: "DURBAN NORTH LIQ"
      if (i == 4 && cell.toUpperCase().contains('LIQ')) {
        supplierName = cell.replaceAll(RegExp(r'^"|"$'), '').trim();
      }

      // Extract invoice from row 12: "Reference : inv181187"
      if (i == 12 && cell.contains('Reference')) {
        final match = RegExp(r':\s*([A-Za-z0-9\-]+)').firstMatch(cell);
        if (match != null) {
          invoiceNumber = match.group(1)!.trim();
        }
      }

      // Extract delivery date from row 13: "Date Delv : 07/02/2026"
      if (i == 13 && cell.contains('Date Delv')) {
        final match = RegExp(r':\s*(\d{1,2}/\d{1,2}/\d{4})').firstMatch(cell);
        if (match != null) {
          try {
            final parts = match.group(1)!.split('/');
            deliveryDate = DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
          } catch (e) {
            // Use default date if parsing fails
          }
        }
      }
    }

    final lineItems = <ParsedGrvLineItem>[];

    // ✅ FIXED: Start parsing line items from row with "Code" header (row 16)
    bool inDataSection = false;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;

      // Detect header row (contains "Code" in first column)
      if (row.length > 0 && row[0].toString().toLowerCase().contains('code')) {
        inDataSection = true;
        continue;
      }

      if (!inDataSection) continue;

      // Skip footer rows (totals row with empty PLU but has values)
      if (row.length >= 7 &&
          row[0].toString().trim().isEmpty &&
          (row[6].toString().contains(',') ||
              row[6].toString().contains('.'))) {
        continue;
      }

      // Skip empty rows
      if (row.every((cell) => cell.toString().trim().isEmpty)) {
        continue;
      }

      try {
        // Your CSV structure: Code,Description,-,Unit,Qty,Pack Size,Unit Price,...
        // Row example: "2756", "Appletiser 330 cans", "-", "EACH", "5.0000", "24.00", "18.0000", "2,160.00", "0.00", "2,160.00"
        if (row.length < 7) continue;

        final pluRaw = row[0].toString().trim();
        if (pluRaw.isEmpty || !RegExp(r'^\d+$').hasMatch(pluRaw)) continue;

        final description = row[1].toString().trim();
        final qtyRaw = row[4].toString().trim(); // Column 5: Qty
        final packSizeRaw = row[5].toString().trim(); // Column 6: Pack Size
        final unitPriceRaw = row[6].toString().trim(); // Column 7: Unit Price

        final qtyCases = _parseDouble(qtyRaw).toInt();
        final unitsPerCase = _parseDouble(packSizeRaw).toInt();
        final pricePerUnit = _parseDouble(unitPriceRaw);

        if (qtyCases <= 0 || unitsPerCase <= 0) continue;

        lineItems.add(ParsedGrvLineItem(
          plu: pluRaw,
          description: description,
          quantityCases: qtyCases,
          unitsPerCase: unitsPerCase,
          pricePerUnit: pricePerUnit,
        ));
      } catch (e) {
        continue; // Skip malformed rows
      }
    }

    return GrvData(
      supplierName: supplierName,
      invoiceNumber: invoiceNumber,
      deliveryDate: deliveryDate,
      lineItems: lineItems,
    );
  }

  double _parseDouble(String value) {
    // Handle values like "5.0000", "24.00", "18.0000", "2,160.00"
    final cleaned = value.replaceAll(',', '').replaceAll(RegExp(r'[^\d.]'), '');
    return double.tryParse(cleaned) ?? 0.0;
  }
}