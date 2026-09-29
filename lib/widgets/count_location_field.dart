import 'package:flutter/material.dart';
import 'count_location_options.dart';

/// Preserves a recorded location even when store reference data is incomplete.
class CountLocationField extends StatelessWidget {
  final List<String?> locations;
  final String? value;
  final bool readOnly;
  final ValueChanged<String?> onChanged;

  const CountLocationField({
    super.key,
    required this.locations,
    required this.value,
    required this.onChanged,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final options = CountLocationOptions(locations, value);
    final notice = options.isUnlisted
        ? readOnly
              ? '${options.selected} isn’t in this store’s location list. The recorded location is kept.'
              : '${options.selected} isn’t in this store’s location list. Keep it or select another location.'
        : options.values.isEmpty
        ? 'No locations are available. Add a store location before creating a count.'
        : null;
    final decoration = InputDecoration(
      labelText: 'Location',
      border: const OutlineInputBorder(),
      helperText: notice,
      helperMaxLines: 4,
      suffixIcon: readOnly ? const Icon(Icons.lock, color: Colors.grey) : null,
    );
    if (readOnly) {
      return TextFormField(
        key: ValueKey('fixed-location:${options.selected}'),
        initialValue: value,
        readOnly: true,
        decoration: decoration,
      );
    }
    return DropdownButtonFormField<String>(
      // FormField initialValue is not controlled after creation. Recreate when
      // the parent changes the selection, including a later loaded record.
      key: ValueKey<String?>(options.selected),
      initialValue: options.selected,
      isExpanded: true,
      decoration: decoration,
      items: options.values
          .map(
            (location) => DropdownMenuItem<String>(
              value: location,
              child: Text(
                location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: options.values.isEmpty ? null : onChanged,
    );
  }
}
