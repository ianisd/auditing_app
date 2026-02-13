import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import 'count_screen.dart';
import 'package:intl/intl.dart';

class LocationHistoryScreen extends StatefulWidget {
  final String locationName;

  const LocationHistoryScreen({super.key, required this.locationName});

  @override
  State<LocationHistoryScreen> createState() => _LocationHistoryScreenState();
}

class _LocationHistoryScreenState extends State<LocationHistoryScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _allLocationCounts = []; // Stores ALL data for this location
  List<Map<String, dynamic>> _filteredCounts = [];    // Stores FILTERED data
  Map<String, List<Map<String, dynamic>>> _groupedCounts = {};

  final TextEditingController _searchController = TextEditingController();

  // --- FILTER STATE ---
  String _filterMode = 'All'; // 'All', 'Today', 'Custom'
  final Set<String> _customSelectedDates = {}; // Stores 'YYYY-MM-DD'

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final storage = context.read<OfflineStorage>();
    final counts = await storage.getStockCounts(location: widget.locationName);

    setState(() {
      _allLocationCounts = counts;
      _applyFilters();
      _isLoading = false;
    });
  }

  // --- 1. FILTER LOGIC ---
  void _applyFilters() {
    final query = _searchController.text.toLowerCase();
    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);

    setState(() {
      _filteredCounts = _allLocationCounts.where((c) {
        // A. Search Filter
        final product = c['productName']?.toString().toLowerCase() ?? '';
        final barcode = c['barcode']?.toString().toLowerCase() ?? '';
        final matchesSearch = query.isEmpty || product.contains(query) || barcode.contains(query);

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

        return matchesSearch && matchesDate;
      }).toList();

      _groupCounts(_filteredCounts);
    });
  }

  void _onSearchChanged() {
    _applyFilters();
  }

  void _groupCounts(List<Map<String, dynamic>> counts) {
    _groupedCounts = {};

    // Sort Descending
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

  // --- 2. DATE SELECTOR DIALOG ---
  Future<void> _openDateSelector() async {
    final Set<String> availableDates = {};
    for (var c in _allLocationCounts) {
      final raw = c['date']?.toString() ?? '';
      try {
        final dt = DateTime.parse(raw);
        availableDates.add(DateFormat('yyyy-MM-dd').format(dt));
      } catch (e) {}
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
                          if (value == true) {
                            _customSelectedDates.add(dateKey);
                          } else {
                            _customSelectedDates.remove(dateKey);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () {
                      setDialogState(() => _customSelectedDates.clear());
                    },
                    child: const Text('Clear')
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _filterMode = _customSelectedDates.isNotEmpty ? 'Custom' : 'All';
                      _applyFilters();
                    });
                    Navigator.pop(context);
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- ACTIONS ---

  void _editCount(Map<String, dynamic> count) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => CountScreen(existingCount: count)),
    );
    _loadHistory();
  }

  // Add Count for Today (Default FAB)
  void _addCountDefault() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CountScreen(
          initialLocation: widget.locationName, // Lock Location
        ),
      ),
    );
    _loadHistory();
  }

  // Add Count for Specific Date (Header Button)
  void _addCountToDate(String dateStr) async {
    try {
      final date = DateTime.parse(dateStr);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CountScreen(
            initialLocation: widget.locationName, // Lock Location
            initialDate: date, // Lock Date
          ),
        ),
      );
      _loadHistory();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid Date')));
    }
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
          preferredSize: const Size.fromHeight(110), // Taller for filters
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
              const SizedBox(height: 8),

              // --- FILTER CHIPS ---
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('All Dates'),
                      selected: _filterMode == 'All',
                      onSelected: (val) { setState(() { _filterMode = 'All'; _applyFilters(); }); },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Today'),
                      selected: _filterMode == 'Today',
                      onSelected: (val) { setState(() { _filterMode = 'Today'; _applyFilters(); }); },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: Text(_filterMode == 'Custom' ? '${_customSelectedDates.length} Selected' : 'Select Dates...'),
                      selected: _filterMode == 'Custom',
                      onSelected: (val) => _openDateSelector(),
                      avatar: _filterMode == 'Custom' ? const Icon(Icons.check_circle, size: 18) : const Icon(Icons.calendar_month, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCountDefault,
        label: const Text('Add Count'),
        icon: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groupedCounts.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No counts found for this filter', style: TextStyle(color: Colors.grey)),
          ],
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.only(left: 8, right: 8, bottom: 80),
        itemCount: _groupedCounts.keys.length,
        itemBuilder: (context, index) {
          final dateKey = _groupedCounts.keys.elementAt(index);
          final items = _groupedCounts[dateKey]!;

          // Date Formatting
          String displayDate = dateKey;
          bool isToday = false;
          try {
            final dt = DateTime.parse(dateKey);
            displayDate = DateFormat('EEE, dd MMM yyyy').format(dt);

            final now = DateTime.now();
            final today = DateTime(now.year, now.month, now.day);
            final checkDate = DateTime(dt.year, dt.month, dt.day);
            isToday = checkDate.isAtSameMomentAs(today);
          } catch (e) {}

          final headerColor = isToday ? Colors.green.shade100 : Colors.grey.shade200;
          final headerIcon = isToday ? Icons.today : Icons.history;

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              side: BorderSide(color: isToday ? Colors.green : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ExpansionTile(
              initiallyExpanded: index == 0,
              collapsedBackgroundColor: headerColor,
              backgroundColor: headerColor.withOpacity(0.3),
              leading: Icon(headerIcon, color: isToday ? Colors.green[800] : Colors.blue),
              title: Text(
                  isToday ? 'Today ($displayDate)' : displayDate,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isToday ? Colors.green[900] : Colors.black87
                  )
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