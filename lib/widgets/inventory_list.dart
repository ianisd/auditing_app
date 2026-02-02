import 'package:flutter/material.dart';

class InventoryList extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final Function(Map<String, dynamic>)? onTap;

  const InventoryList({
    super.key,
    required this.items,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];

        // FIX: Fallback for name
        final name = item['Inventory Product Name']?.toString() ??
            item['Product Name']?.toString() ??
            'Unknown Product';

        final barcode = item['Barcode']?.toString() ?? '';
        final category = item['Category']?.toString() ?? '';
        final packSize = item['Pack Size']?.toString() ?? '';

        return Card(
          elevation: 2,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (barcode.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: Colors.blue[50],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(barcode, style: TextStyle(color: Colors.blue[800], fontSize: 12)),
                      ),
                    if (category.isNotEmpty)
                      Flexible(child: Text(category, style: TextStyle(color: Colors.grey[600], fontSize: 12), overflow: TextOverflow.ellipsis)),
                  ],
                ),
                if (packSize.isNotEmpty && packSize != 'Single')
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Pack: $packSize', style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            onTap: onTap != null ? () => onTap!(item) : null,
          ),
        );
      },
    );
  }
}