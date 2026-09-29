/// Dropdown values remain exact: opening an editor must not rename a location.
class CountLocationOptions {
  final List<String> values;
  final String? selected;
  final bool isUnlisted;

  CountLocationOptions(Iterable<String?> configured, String? current)
    : selected = current == null || current.isEmpty ? null : current,
      isUnlisted =
          current != null &&
          current.isNotEmpty &&
          !configured.any((value) => value == current),
      values = List.unmodifiable({
        for (final value in configured)
          if (value != null && value.trim().isNotEmpty) value,
        if (current != null && current.isNotEmpty) current,
      });
}
