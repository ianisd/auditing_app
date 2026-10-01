import 'package:csv/csv.dart';
import '../models/sales_import_model.dart';

class GaapSalesParser {
  static const int _gaapColumnCount = 12;

  bool canParse(String csvContent) {
    final normalized = _sanitize(csvContent).toLowerCase();
    return normalized.contains('rded daily menu item report') ||
        normalized.contains('recorded daily menu item report');
  }

  ParsedGaapSalesFile parse(String csvContent) {
    final normalizedContent = _sanitize(csvContent);

    if (!canParse(normalizedContent)) {
      throw const FormatException(
        'This file does not look like a GAAP Recorded Daily Menu Item Report.',
      );
    }

    final parsed = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
      allowInvalid: true,
    ).convert(normalizedContent);

    final rows = <GaapSalesRow>[];

    for (var i = 0; i < parsed.length; i++) {
      final source = parsed[i];

      // Preserve the report structure, including blank/separator/heading rows,
      // because v1 intentionally mirrors the existing copy/paste workflow.
      final cells = List<String>.generate(
        _gaapColumnCount,
            (column) => column < source.length
            ? source[column].toString().trim()
            : '',
        growable: false,
      );

      rows.add(
        GaapSalesRow(
          sourceRowNumber: i + 1,
          cells: cells,
        ),
      );
    }

    // Extract once and use both values.
    final reportRange = _extractReportRange(parsed);

    return ParsedGaapSalesFile(
      rows: rows,
      venue: _extractVenue(parsed),
      generatedDate: _extractGeneratedDate(parsed),
      reportFrom: reportRange.$1,
      reportTo: reportRange.$2,
    );
  }

  String _sanitize(String value) => value
      .replaceAll('\u0000', '')
      .replaceAll('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');

  String? _extractVenue(List<List<dynamic>> rows) {
    // GAAP commonly prints the venue immediately before the generated Date row.
    // Metadata is preview-only and never controls the audit date.
    for (var i = 0; i < rows.length && i < 15; i++) {
      final joined = rows[i].join('').trim();
      if (joined.toLowerCase().startsWith('date') && i > 0) {
        for (var j = i - 1; j >= 0; j--) {
          final candidate = rows[j].join('').trim();
          if (candidate.isEmpty || candidate.contains('~~~')) continue;
          if (candidate.toLowerCase().contains('menu item report')) continue;
          return candidate;
        }
      }
    }
    return null;
  }

  DateTime? _extractGeneratedDate(List<List<dynamic>> rows) {
    for (var i = 0; i < rows.length && i < 15; i++) {
      final joined = rows[i].join(' ').trim();
      if (RegExp(r'^date\b', caseSensitive: false).hasMatch(joined)) {
        return _firstDmyDate(joined);
      }
    }
    return null;
  }

  (DateTime?, DateTime?) _extractReportRange(
      List<List<dynamic>> rows,
      ) {
    for (var i = 0; i < rows.length && i < 20; i++) {
      // GAAP can split words and dates across CSV cells:
      // [Repo, rt Dates : 02/07/2026 -> 02/, 07/2026]
      //
      // Joining without spaces reconstructs:
      // Report Dates : 02/07/2026 -> 02/07/2026
      final joined = rows[i]
          .map((cell) => cell.toString().trim())
          .join('');

      final normalized = joined
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      if (!normalized.toLowerCase().contains('report dates')) {
        continue;
      }

      final matches = RegExp(
        r'(\d{1,2})\s*/\s*(\d{1,2})\s*/\s*(\d{4})',
      ).allMatches(normalized).toList();

      if (matches.isEmpty) {
        return (null, null);
      }

      final from = _dateFromMatch(matches[0]);

      final to = matches.length > 1
          ? _dateFromMatch(matches[1])
          : from;

      return (from, to);
    }

    return (null, null);
  }

  DateTime? _firstDmyDate(String value) {
    final match = RegExp(r'(\d{1,2})/(\d{1,2})/(\d{4})').firstMatch(value);
    return match == null ? null : _dateFromMatch(match);
  }

  DateTime? _dateFromMatch(RegExpMatch match) {
    final day = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final year = int.tryParse(match.group(3)!);
    if (day == null || month == null || year == null) return null;

    final value = DateTime(year, month, day);
    if (value.year != year || value.month != month || value.day != day) {
      return null;
    }
    return value;
  }
}
