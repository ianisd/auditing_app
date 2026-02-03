import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/sync_service.dart';
import 'count_screen.dart';
import 'package:intl/intl.dart';

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

  // New Filter State
  String _filterOption = 'All'; // 'All', 'Today'

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
      _applyFilters();
      _isLoading = false;
    });
  }

  // --- NEW: APPLY FILTERS ---
  void _applyFilters() {
    final query = _searchController.text.toLowerCase();
    final todayStr = DateTime.now().toIso8601String().split('T')[0];

    setState(() {
      _filteredCounts = _allCounts.where((c) {
        // 1. Search Filter
        final prod = c['productName']?.toString().toLowerCase() ?? '';
        final loc = c['location']?.toString().toLowerCase() ?? '';
        final matchesSearch = query.isEmpty || prod.contains(query) || loc.contains(query);

        // 2. Date Filter
        final date = c['date']?.toString() ?? '';
        bool matchesDate = true;
        if (_filterOption == 'Today') {
          matchesDate = date == todayStr;
        }

        return matchesSearch && matchesDate;
      }).toList();

      _groupCounts();
    });
  }

  void _onSearchChanged() {
    _applyFilters();
  }

  Future<void> _downloadCounts() async {
    setState(() => _isLoading = true);
    try {
      final syncService = context.read<SyncService>();
      final count = await syncService.downloadExistingCounts();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded $count counts'), backgroundColor: Colors.green),
        );
        await _loadCounts();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e'), backgroundColor: Colors.red),
        );
      }
      setState(() => _isLoading = false);
    }
  }

  void _groupCounts() {
    _groupedCounts = {};
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
    }
  }

  // --- NEW: BACKDATING NAVIGATION ---
  void _addCountToDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CountScreen(initialDate: date),
        ),
      ).then((_) => _loadCounts());
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid Date Format')));
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
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_download),
            tooltip: 'Download from Cloud',
            onPressed: _downloadCounts,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(110), // Taller for filters
          child: Column(
            children: [
              // Search Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
              const SizedBox(height: 8),
              // Filter Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('All Dates'),
                      selected: _filterOption == 'All',
                      onSelected: (val) { setState(() { _filterOption = 'All'; _applyFilters(); }); },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Today'),
                      selected: _filterOption == 'Today',
                      onSelected: (val) { setState(() { _filterOption = 'Today'; _applyFilters(); }); },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _filteredCounts.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_open, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No counts found', style: TextStyle(fontSize: 16, color: Colors.grey)),
          ],
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _groupedCounts.keys.length,
        itemBuilder: (context, dateIndex) {
          final dateKey = _groupedCounts.keys.elementAt(dateIndex);
          final locationMap = _groupedCounts[dateKey]!;

          // Determine Logic for Header Style
          final todayStr = DateTime.now().toIso8601String().split('T')[0];
          final isToday = dateKey == todayStr;
          final headerColor = isToday ? Colors.green.shade100 : Colors.grey.shade200;
          final headerIcon = isToday ? Icons.today : Icons.history;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: Colors.white,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: isToday ? Colors.green : Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ExpansionTile(
              initiallyExpanded: dateIndex == 0,
              collapsedBackgroundColor: headerColor,
              backgroundColor: headerColor.withOpacity(0.3),
              title: Row(
                children: [
                  Icon(headerIcon, color: isToday ? Colors.green[800] : Colors.grey[700]),
                  const SizedBox(width: 8),
                  Text(
                    isToday ? 'Today ($dateKey)' : dateKey,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: isToday ? Colors.green[900] : Colors.black87
                    ),
                  ),
                ],
              ),
              // --- NEW: Add Button on Header ---
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, color: Colors.blue),
                    tooltip: 'Add to this date',
                    onPressed: () => _addCountToDate(dateKey),
                  ),
                  const Icon(Icons.expand_more),
                ],
              ),
              children: locationMap.keys.map((locationKey) {
                final items = locationMap[locationKey]!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      color: Colors.white,
                      child: Text(locationKey, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.purple)),
                    ),
                    ...items.map((item) {
                      return Container(
                        color: Colors.white,
                        child: Dismissible(
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
                            subtitle: Text('${item['pack_size']}'),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${item['total_bottles']?.toStringAsFixed(2) ?? 0}',
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
                        ),
                      );
                    }),
                    const Divider(height: 1),
                  ],
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }
}