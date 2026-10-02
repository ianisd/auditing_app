// lib/utils/safe_date_utils.dart

class SafeDateUtils {
  /// Safe date parsing from common API / Google Sheets formats.
  ///
  /// Supports:
  /// - DateTime values
  /// - ISO-8601 strings
  /// - Unix timestamps in seconds or milliseconds
  /// - Google Sheets / Excel serial dates (days since 1899-12-30)
  static DateTime? parseDate(dynamic value) {
    if (value == null) return null;

    if (value is DateTime) return value;

    if (value is num) {
      return _parseNumericDate(value.toDouble());
    }

    if (value is String) {
      final raw = value.trim();
      if (raw.isEmpty) return null;

      // Numeric strings can be timestamps or spreadsheet serial dates.
      final numeric = double.tryParse(raw);
      if (numeric != null) {
        final parsedNumeric = _parseNumericDate(numeric);
        if (parsedNumeric != null) return parsedNumeric;
      }

      // DateTime.parse already supports ISO-8601 values with Z / offsets.
      return DateTime.tryParse(raw);
    }

    return null;
  }

  static DateTime? _parseNumericDate(double value) {
    if (!value.isFinite || value <= 0) return null;

    try {
      // Contemporary Unix timestamps in milliseconds.
      if (value >= 100000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value.round());
      }

      // Contemporary Unix timestamps in seconds.
      if (value >= 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
      }

      // Google Sheets / Excel serial date. 1899-12-30 matches the
      // spreadsheet date system (including Excel's historical leap-year quirk).
      if (value >= 1 && value < 1000000) {
        final wholeDays = value.floor();
        final fraction = value - wholeDays;
        final milliseconds = (fraction * Duration.millisecondsPerDay).round();
        return DateTime(
          1899,
          12,
          30,
        ).add(Duration(days: wholeDays, milliseconds: milliseconds));
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  /// Safely sort a list by date field
  static void sortByDate<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter,
  ) {
    items.sort((a, b) {
      final dateA = dateGetter(a);
      final dateB = dateGetter(b);

      if (dateA == null && dateB == null) return 0;
      if (dateA == null) return 1; // nulls last
      if (dateB == null) return -1; // nulls last

      return dateA.compareTo(dateB);
    });
  }

  /// Get valid dates (non-null) from a list
  static List<DateTime> getValidDates<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter,
  ) {
    return items
        .map(dateGetter)
        .where((d) => d != null)
        .cast<DateTime>()
        .toList();
  }

  /// Get the earliest valid date
  static DateTime? getEarliestDate<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter,
  ) {
    final dates = getValidDates(items, dateGetter);
    if (dates.isEmpty) return null;
    return dates.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  /// Get the latest valid date
  static DateTime? getLatestDate<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter,
  ) {
    final dates = getValidDates(items, dateGetter);
    if (dates.isEmpty) return null;
    return dates.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  /// Get date range as string
  static String getDateRangeString<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter, {
    String format = 'yyyy-MM-dd',
    String fallback = 'No dates available',
  }) {
    final dates = getValidDates(items, dateGetter);
    if (dates.isEmpty) return fallback;

    dates.sort();
    final first = dates.first;
    final last = dates.last;

    if (first == last) {
      return _formatDate(first, format);
    }
    return '${_formatDate(first, format)} - ${_formatDate(last, format)}';
  }

  static String _formatDate(DateTime date, String format) {
    switch (format) {
      case 'yyyy-MM-dd':
        return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      case 'dd/MM/yyyy':
        return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
      case 'MM/dd/yyyy':
        return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}';
      default:
        return date.toIso8601String().split('T').first;
    }
  }
}
