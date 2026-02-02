import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import 'count_screen.dart'; // For editing a specific count

class LocationHistoryScreen extends StatefulWidget {
  final String locationName;

  const LocationHistoryScreen({super.key, required this.locationName});

  @override
  State<LocationHistoryScreen> createState() => _LocationHistoryScreenState();
}

class _LocationHistoryScreenState extends State<LocationHistoryScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _locationCounts = [];
  Map<String, List<Map<String, dynamic>>> _groupedCounts = {}; // Date -> Items
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _searchController.addListener(_filterResults);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final storage = context.read<OfflineStorage>();
    // Fetch ONLY counts for this location
    final counts = await storage.getStockCounts(location: widget.locationName);

    setState(() {
      _locationCounts = counts;
      _groupCounts(counts); // Initial grouping
      _isLoading = false;
    });
  }

  void _filterResults() {
    final query = _searchController.text.toLowerCase();

    if (query.isEmpty) {
      setState(() => _groupCounts(_locationCounts));
      return;
    }

    final filtered = _locationCounts.where((item) {
      final product = item['productName']?.toString().toLowerCase() ?? '';
      final barcode = item['barcode']?.toString().toLowerCase() ?? '';
      return product.contains(query) || barcode.contains(query);
    }).toList();

    setState(() => _groupCounts(filtered));
  }

  void _groupCounts(List<Map<String, dynamic>> counts) {
    _groupedCounts = {};

    // Sort by Date Descending (Newest first)
    counts.sort((a, b) {
      final dateA = a['date'] ?? '';
      final dateB = b['date'] ?? '';
      return dateB.compareTo(dateA);
    });

    for (var item in counts) {
      final date = item['date']?.toString() ?? 'Unknown Date';
      if (!_groupedCounts.containsKey(date)) {
        _groupedCounts[date] = [];
      }
      _groupedCounts[date]!.add(item);
    }
  }

  void _editCount(Map<String, dynamic> count) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => CountScreen(existingCount: count)),
    );
    _loadHistory(); // Refresh on return
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Location History', style: TextStyle(fontSize: 16)),
            Text(widget.locationName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search products in ${widget.locationName}...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groupedCounts.isEmpty
          ? const Center(child: Text('No counts found for this location'))
          : ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _groupedCounts.keys.length,
        itemBuilder: (context, index) {
          final dateKey = _groupedCounts.keys.elementAt(index);
          final items = _groupedCounts[dateKey]!;

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              initiallyExpanded: index == 0, // Expand newest date
              leading: const Icon(Icons.calendar_month, color: Colors.blue),
              title: Text(
                  dateKey,
                  style: const TextStyle(fontWeight: FontWeight.bold)
              ),
              subtitle: Text('${items.length} items counted'),
              children: items.map((item) {
                return ListTile(
                  title: Text(item['productName'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: Text('${item['pack_size']}'),
                  trailing: Text(
                    (item['pack_size'] == 'Open Bottle')
                        ? '${item['weight']}g'
                        : '${item['count']}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  onTap: () => _editCount(item),
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }
}