class GaapSalesRow {
  final int sourceRowNumber;
  final List<String> cells;

  const GaapSalesRow({
    required this.sourceRowNumber,
    required this.cells,
  });

  String cell(int index) => index < cells.length ? cells[index] : '';

  bool get isBlank => cells.every((value) => value.trim().isEmpty);

  /// Mirrors the current StoreSalesData layout:
  /// Date + salesID + the 12 GAAP report columns.
  ///
  /// The four downstream mapping/status columns are intentionally omitted.
  Map<String, dynamic> toStoreSalesData({
    required DateTime auditDate,
    String salesId = '',
  }) {
    final dateOnly = DateTime(auditDate.year, auditDate.month, auditDate.day);

    return {
      'Date': dateOnly.toIso8601String(),
      'salesID': salesId,
      'No.': cell(0),
      'MenuItem': cell(1),
      'Qty': cell(2),
      'Item': cell(3),
      'Excl': cell(4),
      'Incl': cell(5),
      'Discounts': cell(6),
      // StoreSalesData historically has two columns both named "Discounts".
      // Keep the second value separately in the import model. The eventual
      // POST serializer must write by column position, not a Map key, so that
      // neither value is lost.
      'Discounts_2': cell(7),
      'Cost': cell(8),
      'Sales': cell(9),
      'Profit': cell(10),
      'T/O': cell(11),
    };
  }

  /// Positional representation for the eventual backend upload.
  /// This safely preserves both duplicate "Discounts" columns.
  List<dynamic> toStoreSalesDataColumns({
    required DateTime auditDate,
    String salesId = '',
  }) {
    final dateOnly = DateTime(auditDate.year, auditDate.month, auditDate.day);
    return <dynamic>[
      dateOnly.toIso8601String(), // A Date
      salesId,                    // B salesID
      ...cells.take(12),          // C:N raw GAAP report columns
    ];
  }
}

class ParsedGaapSalesFile {
  final List<GaapSalesRow> rows;
  final String? venue;
  final DateTime? generatedDate;
  final DateTime? reportFrom;
  final DateTime? reportTo;

  const ParsedGaapSalesFile({
    required this.rows,
    this.venue,
    this.generatedDate,
    this.reportFrom,
    this.reportTo,
  });

  int get rowCount => rows.length;
  int get nonBlankRowCount => rows.where((row) => !row.isBlank).length;

  /// Actual sale/menu rows are identified only for preview information.
  /// They are NOT the only rows retained by the parser.
  int get saleLineCount => rows.where((row) {
    final plu = row.cell(0).trim();
    final qty = row.cell(2).trim();
    return RegExp(r'^\d+$').hasMatch(plu) &&
        double.tryParse(qty.replaceAll(',', '')) != null;
  }).length;
}