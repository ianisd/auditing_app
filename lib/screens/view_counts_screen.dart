import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/sync_service.dart'; // Import SyncService
import 'count_screen.dart';

class ViewCountsScreen extends StatefulWidget {
  const ViewCountsScreen({super.key});

  @override
  State<ViewCountsScreen> createState() => _ViewCountsScreenState();
}

class _ViewCountsScreenState extends State<ViewCountsScreen> {
  List<Map<String, dynamic>> _allCounts = [];
  List<Map<String, dynamic>> _filteredCounts = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  // Structure: Date -> Location -> List of Items
  Map<String, Map<String, List<Map<String, dynamic>>>> _groupedCounts = {};

  @override
  void initState() {
    super.initState();
    _loadCounts();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCounts() async {
    setState(() => _isLoading = true);
    final storage = context.read<OfflineStorage>();
    final counts = await storage.getStockCounts();

    setState(() {
      _allCounts = counts;
      _filteredCounts = counts;
      _groupCounts();
      _isLoading = false;
    });
  }

  // --- NEW: DOWNLOAD FUNCTION ---
  Future<void> _downloadCounts() async {
    setState(() => _isLoading = true);
    try {
      final syncService = context.read<SyncService>();
      final count = await syncService.downloadExistingCounts();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Downloaded $count counts from Cloud'),
            backgroundColor: Colors.green,
          ),
        );
        // Reload from local storage to display them
        await _loadCounts();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() => _isLoading = false);
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredCounts = _allCounts;
      } else {
        _filteredCounts = _allCounts.where((c) {
          final prod = c['productName']?.toString().toLowerCase() ?? '';
          final loc = c['location']?.toString().toLowerCase() ?? '';
          final cat = c['category']?.toString().toLowerCase() ?? '';
          return prod.contains(query) || loc.contains(query) || cat.contains(query);
        }).toList();
      }
      _groupCounts();
    });
  }

  void _groupCounts() {
    _groupedCounts = {};

    // Sort by Date Descending
    _filteredCounts.sort((a, b) {
      final dateA = a['date'] ?? '';
      final dateB = b['date'] ?? '';
      return dateB.compareTo(dateA);
    });

    for (var count in _filteredCounts) {
      final date = count['date']?.toString() ?? 'Unknown Date';
      final location = count['location']?.toString() ?? 'Unknown Location';

      if (!_groupedCounts.containsKey(date)) {
        _groupedCounts[date] = {};
      }
      if (!_groupedCounts[date]!.containsKey(location)) {
        _groupedCounts[date]![location] = [];
      }
      _groupedCounts[date]![location]!.add(count);
    }
  }

  Future<void> _deleteCount(String id) async {
    bool confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry?'),
        content: const Text('This will remove it from the device and mark for deletion on server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    ) ?? false;

    if (confirm) {
      await context.read<OfflineStorage>().deleteStockCount(id);
      _loadCounts();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marked for deletion. Sync to apply.')));
    }
  }

  void _editCount(Map<String, dynamic> count) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CountScreen(existingCount: count),
      ),
    );
    _loadCounts();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('View Counts'),
        // --- ADDED DOWNLOAD BUTTON HERE ---
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_download),
            tooltip: 'Download from Cloud',
            onPressed: _downloadCounts,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search product, location...',
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
          : _filteredCounts.isEmpty
      // --- ADDED EMPTY STATE BUTTON HERE ---
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_open, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No counts found locally', style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _downloadCounts,
              icon: const Icon(Icons.cloud_download),
              label: const Text('Download from Cloud'),
            ),
          ],
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _groupedCounts.keys.length,
        itemBuilder: (context, dateIndex) {
          final dateKey = _groupedCounts.keys.elementAt(dateIndex);
          final locationMap = _groupedCounts[dateKey]!;

          // Level 1: DATE
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: Colors.grey[100],
            child: ExpansionTile(
              initiallyExpanded: dateIndex == 0,
              title: Text(dateKey, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              leading: const Icon(Icons.calendar_today, color: Colors.blue),
              children: locationMap.keys.map((locationKey) {
                final items = locationMap[locationKey]!;

                // Level 2: LOCATION
                return ExpansionTile(
                  title: Text(locationKey, style: const TextStyle(fontWeight: FontWeight.w600)),
                  leading: const Icon(Icons.location_on, color: Colors.purple, size: 20),
                  children: items.map((item) {

                    // Level 3: ITEMS
                    return Dismissible(
                      key: Key(item['id']),
                      background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
                      direction: DismissDirection.endToStart,
                      confirmDismiss: (dir) async {
                        _deleteCount(item['id']);
                        return false;
                      },
                      child: ListTile(
                        contentPadding: const EdgeInsets.only(left: 32, right: 16),
                        title: Text(item['productName'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.w500)),
                        subtitle: Text('${item['category']} • ${item['pack_size']}'),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              (item['pack_size'] == 'Open Bottle')
                                  ? '${item['weight']}g'
                                  : '${item['count']} units',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            if (item['syncStatus'] == 'pending')
                              const Icon(Icons.cloud_upload, size: 12, color: Colors.orange)
                            else if (item['syncStatus'] == 'deleted')
                              const Icon(Icons.delete_forever, size: 12, color: Colors.red)
                            else
                              const Icon(Icons.check_circle, size: 12, color: Colors.green),
                          ],
                        ),
                        onTap: () => _editCount(item),
                      ),
                    );
                  }).toList(),
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }
}