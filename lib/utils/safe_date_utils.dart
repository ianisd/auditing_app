// lib/utils/safe_date_utils.dart


class SafeDateUtils {
  /// Safe date parsing from various formats
  static DateTime? parseDate(dynamic value) {
    if (value == null) return null;

    if (value is DateTime) {
      return value;
    }

    if (value is String) {
      try {
        return DateTime.parse(value);
      } catch (e) {
        // Try alternative formats
        try {
          // Handle ISO format with timezone
          final cleaned = value.replaceAll('Z', '').replaceAll('+00:00', '');
          return DateTime.parse(cleaned);
        } catch (e2) {
          return null;
        }
      }
    }

    if (value is int) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(value);
      } catch (e) {
        return null;
      }
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