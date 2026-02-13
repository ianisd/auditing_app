import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/sync_service.dart';
import '../services/store_manager.dart';
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

  // --- FILTER STATE ---
  String _filterMode = 'All'; // 'All', 'Today', 'Custom'
  Set<String> _customSelectedDates = {};
  String? _selectedLocationFilter; // THIS WAS MISSING

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

  void _applyFilters() {
    final query = _searchController.text.toLowerCase();
    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);

    setState(() {
      _filteredCounts = _allCounts.where((c) {
        // A. Search Text Filter
        final prod = c['productName']?.toString().toLowerCase() ?? '';
        final barcode = c['barcode']?.toString().toLowerCase() ?? '';
        final matchesSearch = query.isEmpty || prod.contains(query) || barcode.contains(query);

        // B. Date Filter
        final rawDate = c['date']?.toString() ?? '';
        String itemDateKey = '';
        try {
          final dt = DateTime.parse(rawDate);
          itemDateKey = DateFormat('yyyy-MM-dd').format(dt);
        } catch (e) {
          itemDateKey = rawDate.split('T')[0];
        }

        bool matchesDate = true;
        if (_filterMode == 'Today') {
          matchesDate = itemDateKey == todayStr;
        } else if (_filterMode == 'Custom') {
          matchesDate = _customSelectedDates.contains(itemDateKey);
        }

        // C. Location Filter (RESTORED)
        bool matchesLocation = true;
        if (_selectedLocationFilter != null) {
          final loc = c['location']?.toString() ?? '';
          matchesLocation = loc == _selectedLocationFilter;
        }

        return matchesSearch && matchesDate && matchesLocation;
      }).toList();

      _groupCounts();
    });
  }

  void _onSearchChanged() {
    _applyFilters();
  }

  // --- LOCATION SELECTOR (RESTORED) ---
  Future<void> _openLocationSelector() async {
    // Get unique locations from the ACTUAL data
    final locations = _allCounts
        .map((c) => c['location']?.toString())
        .where((l) => l != null && l.isNotEmpty)
        .toSet()
        .toList();

    locations.sort();

    await showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Filter by Location'),
        children: [
          SimpleDialogOption(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
            onPressed: () {
              setState(() => _selectedLocationFilter = null);
              _applyFilters();
              Navigator.pop(ctx);
            },
            child: const Text('All Locations', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
          ),
          ...locations.map((loc) => SimpleDialogOption(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
            onPressed: () {
              setState(() => _selectedLocationFilter = loc);
              _applyFilters();
              Navigator.pop(ctx);
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(loc!),
                if (_selectedLocationFilter == loc) const Icon(Icons.check, size: 16, color: Colors.blue),
              ],
            ),
          )),
        ],
      ),
    );
  }

  // --- DATE SELECTOR ---
  Future<void> _openDateSelector() async {
    final Set<String> availableDates = {};
    for (var c in _allCounts) {
      final raw = c['date']?.toString() ?? '';
      try {
        final dt = DateTime.parse(raw);
        availableDates.add(DateFormat('yyyy-MM-dd').format(dt));
      } catch (e) { /* ignore */ }
    }

    final sortedDates = availableDates.toList()..sort((a, b) => b.compareTo(a));

    if (sortedDates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No dates available')));
      return;
    }

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Select Dates'),
              content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: sortedDates.length,
                  itemBuilder: (ctx, i) {
                    final dateKey = sortedDates[i];
                    final isSelected = _customSelectedDates.contains(dateKey);
                    final displayDate = DateFormat('EEE, dd MMM yyyy').format(DateTime.parse(dateKey));

                    return CheckboxListTile(
                      title: Text(displayDate),
                      value: isSelected,
                      onChanged: (bool? value) {
                        setDialogState(() {
                          if (value == true) _customSelectedDates.add(dateKey);
                          else _customSelectedDates.remove(dateKey);
                        });
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(onPressed: () { setDialogState(() { _customSelectedDates.clear(); }); }, child: const Text('Clear')),
                FilledButton(onPressed: () {
                  setState(() {
                    _filterMode = _customSelectedDates.isNotEmpty ? 'Custom' : 'All';
                    _applyFilters();
                  });
                  Navigator.pop(context);
                }, child: const Text('Apply')),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _downloadCounts() async {
    setState(() => _isLoading = true);
    try {
      final syncService = context.read<StoreManager>().syncService;
      final count = await syncService.downloadExistingCounts();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Downloaded $count counts'), backgroundColor: Colors.green));
        await _loadCounts();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      setState(() => _isLoading = false);
    }
  }

  void _groupCounts() {
    _groupedCounts = {};
    _filteredCounts.sort((a, b) => (b['date'] ?? '').compareTo(a['date'] ?? ''));

    for (var count in _filteredCounts) {
      final date = count['date']?.toString() ?? 'Unknown Date';
      final location = count['location']?.toString() ?? 'Unknown Location';

      if (!_groupedCounts.containsKey(date)) _groupedCounts[date] = {};
      if (!_groupedCounts[date]!.containsKey(location)) _groupedCounts[date]![location] = [];

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

  void _addCountToDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      Navigator.push(context, MaterialPageRoute(builder: (context) => CountScreen(initialDate: date)))
          .then((_) => _loadCounts());
    } catch (e) {}
  }

  void _editCount(Map<String, dynamic> count) async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => CountScreen(existingCount: count)));
    _loadCounts();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('View Counts'),
        actions: [
          IconButton(icon: const Icon(Icons.cloud_download), tooltip: 'Download', onPressed: _downloadCounts),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(110),
          child: Column(
            children: [
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
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('All Dates'),
                      selected: _filterMode == 'All',
                      onSelected: (val) { setState(() { _filterMode = 'All'; _customSelectedDates.clear(); _applyFilters(); }); },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Today'),
                      selected: _filterMode == 'Today',
                      onSelected: (val) { setState(() { _filterMode = 'Today'; _customSelectedDates.clear(); _applyFilters(); }); },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: Text(_filterMode == 'Custom' ? '${_customSelectedDates.length} Selected' : 'Dates...'),
                      selected: _filterMode == 'Custom',
                      onSelected: (val) => _openDateSelector(),
                      avatar: const Icon(Icons.calendar_month, size: 18),
                    ),
                    const SizedBox(width: 8),
                    // --- RESTORED LOCATION CHIP ---
                    FilterChip(
                      label: Text(_selectedLocationFilter ?? 'Location...'),
                      selected: _selectedLocationFilter != null,
                      onSelected: (val) => _openLocationSelector(),
                      avatar: const Icon(Icons.place, size: 18),
                      onDeleted: _selectedLocationFilter != null ? () {
                        setState(() { _selectedLocationFilter = null; _applyFilters(); });
                      } : null,
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
          ? const Center(child: Text('No counts found', style: TextStyle(fontSize: 16, color: Colors.grey)))
          : ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _groupedCounts.keys.length,
        itemBuilder: (context, dateIndex) {
          final dateKey = _groupedCounts.keys.elementAt(dateIndex);
          final locationMap = _groupedCounts[dateKey]!;

          String displayDate = dateKey;
          bool isToday = false;
          try {
            final dt = DateTime.parse(dateKey);
            displayDate = DateFormat('EEE, dd MMM yyyy').format(dt);
            final now = DateTime.now();
            if (dt.year == now.year && dt.month == now.month && dt.day == now.day) isToday = true;
          } catch (e) {}

          final headerColor = isToday ? Colors.green.shade100 : Colors.grey.shade200;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: Colors.white,
            shape: RoundedRectangleBorder(side: BorderSide(color: isToday ? Colors.green : Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
            child: ExpansionTile(
              initiallyExpanded: dateIndex == 0,
              collapsedBackgroundColor: headerColor,
              backgroundColor: headerColor.withOpacity(0.3),
              title: Row(
                children: [
                  Icon(isToday ? Icons.today : Icons.history, color: isToday ? Colors.green[800] : Colors.grey[700]),
                  const SizedBox(width: 8),
                  Text(isToday ? 'Today ($displayDate)' : displayDate, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isToday ? Colors.green[900] : Colors.black87)),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.add_circle_outline, color: Colors.blue), onPressed: () => _addCountToDate(dateKey)),
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
                      return Dismissible(
                        key: Key(item['id']),
                        background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
                        direction: DismissDirection.endToStart,
                        confirmDismiss: (dir) async { _deleteCount(item['id']); return false; },
                        child: ListTile(
                          contentPadding: const EdgeInsets.only(left: 32, right: 16),
                          title: Text(item['productName'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.w500)),
                          subtitle: Text('${item['pack_size']}'),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('${(double.tryParse(item['total_bottles']?.toString() ?? '0') ?? 0).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                              if (item['syncStatus'] == 'pending') const Icon(Icons.cloud_upload, size: 12, color: Colors.orange)
                              else const Icon(Icons.check_circle, size: 12, color: Colors.green),
                            ],
                          ),
                          onTap: () => _editCount(item),
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