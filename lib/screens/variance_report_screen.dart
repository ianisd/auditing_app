import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import '../services/variance_service.dart';
import '../services/logger_service.dart';
import 'count_screen.dart';

class VarianceReportScreen extends StatefulWidget {
  const VarianceReportScreen({super.key});

  @override
  State<VarianceReportScreen> createState() => _VarianceReportScreenState();
}

class _VarianceReportScreenState extends State<VarianceReportScreen> {
  String? _startDate;
  String? _endDate;
  List<String> _availableDates = [];

  // --- FILTERS ---
  List<String> _allLocations = [];
  final Set<String> _selectedLocations = {};

  // Category Filters
  Set<String> _availableMainCategories = {};
  Set<String> _selectedMainCategories = {};

  bool _showBalanced = false;

  // View State
  bool _areCategoriesExpanded = true;
  Key _listKey = UniqueKey(); // Used to force-refresh list state

  final TextEditingController _searchController = TextEditingController();

  List<VarianceItem> _fullReport = [];
  Map<String, Map<String, List<VarianceItem>>> _groupedReport = {};

  // Totals
  double _totalVarianceCost = 0;
  double _totalVarianceRetail = 0;

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_applyLocalFilters);
    _loadInitialData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    final storage = context.read<OfflineStorage>();

    // 1. Load Dates
    final counts = await storage.getStockCounts();
    final dates = counts.map((e) {
      final raw = e['date'].toString();
      return raw.contains('T') ? raw.split('T')[0] : raw;
    }).toSet().toList();

    dates.sort((a, b) => b.compareTo(a));

    // 2. Load Locations
    final locations = await storage.getLocations();
    final locNames = locations.map((e) => e['Location'].toString()).toList();
    locNames.sort();

    setState(() {
      _availableDates = dates;
      _allLocations = locNames;

      if (dates.isNotEmpty) _endDate = dates[0];
      if (dates.length > 1) _startDate = dates[1];
    });

    if (_startDate != null && _endDate != null) {
      _runReport();
    }
  }

  Future<void> _runReport() async {
    if (_startDate == null || _endDate == null) return;

    setState(() => _isLoading = true);

    final storage = context.read<OfflineStorage>();
    final logger = context.read<LoggerService>();

    final results = await Future.wait([
      storage.getStockCounts(),
      storage.getPurchases(),
      storage.getStoreSalesData(),
      storage.getItemSalesMap(),
      storage.getAllInventory(),
    ]);

    try {
      final service = VarianceService(logger: logger);

      final reportItems = service.calculateReport(
        stocks: results[0],
        purchases: results[1],
        storeSalesData: results[2],
        itemSalesMap: results[3],
        inventory: results[4],
        dateFromStr: _startDate!,
        dateToStr: _endDate!,
      );

      if (mounted) {
        setState(() {
          _fullReport = reportItems;

          // Extract Categories
          _availableMainCategories = reportItems.map((e) => e.mainCategory).toSet();

          // Handle selection logic
          if (_selectedMainCategories.isEmpty) {
            _selectedMainCategories = Set.from(_availableMainCategories);
          } else {
            _selectedMainCategories = _selectedMainCategories.intersection(_availableMainCategories);
            if (_selectedMainCategories.isEmpty && _availableMainCategories.isNotEmpty) {
              _selectedMainCategories = Set.from(_availableMainCategories);
            }
          }

          _applyLocalFilters();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        logger.error('Report Error', e);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _applyLocalFilters() {
    final query = _searchController.text.toLowerCase();

    double tempTotalCost = 0;
    double tempTotalRetail = 0;

    final filteredList = _fullReport.where((item) {
      // 1. Balanced Filter
      if (!_showBalanced && item.variance.abs() <= 0.1) return false;

      // 2. Search Filter
      if (query.isNotEmpty && !item.productName.toLowerCase().contains(query)) return false;

      // 3. Location Filter
      if (_selectedLocations.isNotEmpty) {
        bool hasHistoryInLoc = item.allEntries.any((e) => _selectedLocations.contains(e['location']));
        if (!hasHistoryInLoc) return false;
      }

      // 4. Category Filter
      if (!_selectedMainCategories.contains(item.mainCategory)) return false;

      return true;
    }).toList();

    // Calculate Global Totals
    for (var item in filteredList) {
      tempTotalCost += item.varianceCost;
      tempTotalRetail += item.varianceRetail;
    }

    // Grouping
    Map<String, Map<String, List<VarianceItem>>> grouping = {};
    for (var item in filteredList) {
      final main = item.mainCategory.isEmpty ? 'Uncategorized' : item.mainCategory;
      final cat = item.category.isEmpty ? 'General' : item.category;

      if (!grouping.containsKey(main)) grouping[main] = {};
      if (!grouping[main]!.containsKey(cat)) grouping[main]![cat] = [];

      grouping[main]![cat]!.add(item);
    }

    // Sorting
    final sortedGroup = Map.fromEntries(
        grouping.entries.toList()..sort((a, b) => a.key.compareTo(b.key))
    );

    for (var mainKey in sortedGroup.keys) {
      for (var subKey in sortedGroup[mainKey]!.keys) {
        sortedGroup[mainKey]![subKey]!.sort((a, b) {
          return b.variance.abs().compareTo(a.variance.abs());
        });
      }
    }

    setState(() {
      _groupedReport = sortedGroup;
      _totalVarianceCost = tempTotalCost;
      _totalVarianceRetail = tempTotalRetail;
      // Force rebuild of list when filters change
      _listKey = UniqueKey();
    });
  }

  // --- ACTIONS ---

  void _toggleViewMode() {
    setState(() {
      _areCategoriesExpanded = !_areCategoriesExpanded;
      // Force rebuild of list when toggle is pressed
      _listKey = UniqueKey();
    });
  }

  void _openLocationFilter() async {
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Filter by Location'),
              content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: ListView(
                  children: _allLocations.map((loc) {
                    return CheckboxListTile(
                      title: Text(loc),
                      value: _selectedLocations.contains(loc),
                      onChanged: (val) {
                        setDialogState(() {
                          if (val == true) {
                            _selectedLocations.add(loc);
                          } else {
                            _selectedLocations.remove(loc);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(onPressed: () { _selectedLocations.clear(); Navigator.pop(context); _applyLocalFilters(); }, child: const Text('Clear All')),
                FilledButton(onPressed: () { Navigator.pop(context); _applyLocalFilters(); }, child: const Text('Apply')),
              ],
            );
          },
        );
      },
    );
  }

  void _openCategoryFilter() async {
    final sortedCats = _availableMainCategories.toList()..sort();

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Filter Categories'),
              content: SizedBox(
                width: double.maxFinite,
                height: 300,
                child: ListView(
                  children: sortedCats.map((cat) {
                    return CheckboxListTile(
                      title: Text(cat),
                      value: _selectedMainCategories.contains(cat),
                      onChanged: (val) {
                        setDialogState(() {
                          if (val == true) {
                            _selectedMainCategories.add(cat);
                          } else {
                            _selectedMainCategories.remove(cat);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () {
                      setDialogState(() => _selectedMainCategories.clear());
                    },
                    child: const Text('None')
                ),
                TextButton(
                    onPressed: () {
                      setDialogState(() => _selectedMainCategories = Set.from(_availableMainCategories));
                    },
                    child: const Text('All')
                ),
                FilledButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _applyLocalFilters();
                    },
                    child: const Text('Apply')
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _editCount(Map<String, dynamic> count) async {
    await Navigator.push(context, MaterialPageRoute(builder: (c) => CountScreen(existingCount: count)));
    _runReport();
  }
  void _addNewCount(VarianceItem item) async {
    if (item.inventoryItem == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (c) => CountScreen(initialProduct: item.inventoryItem, initialDate: DateTime.parse(_endDate!))));
    _runReport();
  }

  @override
  Widget build(BuildContext context) {
    final previousDates = _availableDates.where((d) {
      if (_endDate == null) return true;
      return d.compareTo(_endDate!) < 0;
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Variance Report')),
      body: Column(
        children: [
          // 1. DATE SELECTORS
          Card(
            margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Expanded(child: _buildDateDropdown('Previous', _startDate, previousDates, (val) { setState(() => _startDate = val); _runReport(); })),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, color: Colors.grey)),
                  Expanded(child: _buildDateDropdown('Current', _endDate, _availableDates, (val) { setState(() { _endDate = val; if(_startDate!=null && _startDate!.compareTo(val!)>=0) _startDate=null; }); _runReport(); })),
                ],
              ),
            ),
          ),

          // 2. SEARCH & FILTERS
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search Product...',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.place, size: 16),
                      label: Text(_selectedLocations.isEmpty ? 'All Locs' : 'Locs (${_selectedLocations.length})'),
                      onPressed: _openLocationFilter,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    ActionChip(
                      avatar: const Icon(Icons.category, size: 16),
                      label: Text(_selectedMainCategories.length == _availableMainCategories.length
                          ? 'All Cats'
                          : 'Cats (${_selectedMainCategories.length})'),
                      onPressed: _openCategoryFilter,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: _toggleViewMode,
                      icon: Icon(_areCategoriesExpanded ? Icons.unfold_less : Icons.unfold_more),
                      tooltip: _areCategoriesExpanded ? 'Collapse All' : 'Expand All',
                      visualDensity: VisualDensity.compact,
                    ),
                    const Spacer(),
                    const Text("Balanced", style: TextStyle(fontSize: 12)),
                    Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: _showBalanced,
                        onChanged: (val) { setState(() => _showBalanced = val); _applyLocalFilters(); },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 3. GRAND TOTALS
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.indigo.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildTotalItem('Retail Var', _totalVarianceRetail, Colors.purple),
                Container(width: 1, height: 30, color: Colors.grey.shade300),
                _buildTotalItem('Cost Var', _totalVarianceCost, Colors.blueGrey),
              ],
            ),
          ),

          // 4. REPORT LIST
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _groupedReport.isEmpty
                ? const Center(child: Text('No variance data found.'))
                : ListView.builder(
              key: _listKey, // Forces rebuild when toggled
              padding: const EdgeInsets.only(bottom: 40),
              itemCount: _groupedReport.keys.length,
              itemBuilder: (context, i) {
                final mainCat = _groupedReport.keys.elementAt(i);
                final subCats = _groupedReport[mainCat]!;
                double mainCatRetail = 0;
                for(var list in subCats.values) { for(var item in list) mainCatRetail += item.varianceRetail; }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      color: Colors.grey[200],
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(child: Text(mainCat.toUpperCase(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.black87))),
                          Text(NumberFormat.simpleCurrency(name: 'R').format(mainCatRetail), style: TextStyle(fontWeight: FontWeight.bold, color: mainCatRetail < 0 ? Colors.red : Colors.green[800])),
                        ],
                      ),
                    ),
                    ...subCats.entries.map((entry) {
                      final catName = entry.key;
                      final items = entry.value;
                      double subRetail = 0;
                      for(var item in items) subRetail += item.varianceRetail;

                      return ExpansionTile(
                        initiallyExpanded: _areCategoriesExpanded,
                        title: Row(
                          children: [
                            Expanded(child: Text(catName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blueAccent))),
                            Text(NumberFormat.simpleCurrency(name: 'R').format(subRetail), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subRetail < 0 ? Colors.red : Colors.green)),
                          ],
                        ),
                        subtitle: Text('${items.length} Items', style: const TextStyle(fontSize: 11)),
                        children: items.map((item) => _buildVarianceCard(item)).toList(),
                      );
                    }),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTotalItem(String label, double value, Color color) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500)),
        Text(
          NumberFormat.simpleCurrency(name: 'R').format(value),
          style: TextStyle(color: value < 0 ? Colors.red : Colors.green[800], fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildVarianceCard(VarianceItem item) {
    final isLoss = item.variance < -0.1;
    final isGain = item.variance > 0.1;
    final color = isLoss ? Colors.red : (isGain ? Colors.green : Colors.grey);
    final productName = item.productName.isEmpty ? 'Unknown Product' : item.productName.toUpperCase();

    final visibleEntries = item.allEntries.where((e) {
      if (_selectedLocations.isEmpty) return true;
      return _selectedLocations.contains(e['location']);
    }).toList();

    final Map<String, List<Map<String, dynamic>>> groupedCounts = {};
    for (var entry in visibleEntries) {
      final raw = entry['date'].toString();
      final d = raw.contains('T') ? raw.split('T')[0] : raw;
      if (!groupedCounts.containsKey(d)) groupedCounts[d] = [];
      groupedCounts[d]!.add(entry);
    }
    final sortedDates = groupedCounts.keys.toList()..sort((a, b) => b.compareTo(a));

    bool hasCountToday = visibleEntries.any((e) {
      final d = e['date'].toString().split('T')[0];
      return d == _endDate;
    });

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0.5,
      shape: RoundedRectangleBorder(side: BorderSide(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.1),
          child: Text(
              item.variance.abs().toStringAsFixed(1),
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)
          ),
        ),
        title: Text(productName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        subtitle: Row(
          children: [
            Text('Act: ${item.currentCount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text('Theo: ${item.theoreticalStock.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11)),
          ],
        ),
        trailing: Text(
          NumberFormat.simpleCurrency(name: 'R').format(item.varianceRetail),
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                _buildDetailRow('Previous Count', item.previousCount),
                _buildDetailRow('Purchases (+)', item.purchases),
                _buildDetailRow('Sales (-)', item.sales),
                const Divider(),
                _buildDetailRow('Theoretical', item.theoreticalStock, isBold: true),
                _buildDetailRow('Actual (Total)', item.currentCount, isBold: true),
                const Divider(),
                _buildDetailRow('Variance Qty', item.variance, color: color, isBold: true),
                _buildDetailRow('Variance Cost', item.varianceCost, color: color),
                _buildDetailRow('Variance Retail', item.varianceRetail, color: color, isBold: true),

                const SizedBox(height: 12),
                const Align(alignment: Alignment.centerLeft, child: Text('History:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey))),

                if (sortedDates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('No counts found in filter.', style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12, color: Colors.grey)),
                  ),

                ...sortedDates.map((dateKey) {
                  final entries = groupedCounts[dateKey]!;
                  String prettyDate = dateKey;
                  try { prettyDate = DateFormat('EEE, dd MMM').format(DateTime.parse(dateKey)); } catch(e){}

                  final isCurrent = dateKey == _endDate;
                  final isStart = dateKey == _startDate;
                  final headerColor = isCurrent ? Colors.green : (isStart ? Colors.blue : Colors.grey);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
                        decoration: BoxDecoration(color: headerColor.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                        child: Text(
                          isCurrent ? '$prettyDate (Current)' : (isStart ? '$prettyDate (Start)' : prettyDate),
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: headerColor),
                        ),
                      ),
                      ...entries.map((entry) {
                        final qty = double.tryParse(entry['total_bottles']?.toString() ?? '0') ?? 0;
                        return InkWell(
                          onTap: () => _editCount(entry),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                            child: Row(
                              children: [
                                Expanded(child: Text(entry['location'] ?? 'Unknown', style: const TextStyle(fontSize: 12))),
                                Text(qty.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                const SizedBox(width: 8),
                                const Icon(Icons.edit, size: 14, color: Colors.blueGrey),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  );
                }),

                if (!hasCountToday) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _addNewCount(item),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add Missing Count'),
                      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    ),
                  ),
                ]
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, double value, {bool isBold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 12, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
          Text(value.toStringAsFixed(2), style: TextStyle(fontSize: 12, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
        ],
      ),
    );
  }
}
Widget _buildDetailRow(String label, double value, {bool isBold = false, Color? color}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
        Text(value.toStringAsFixed(2), style: TextStyle(fontSize: 12, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
      ],
    ),
  );
}

Widget _buildDateDropdown(String label, String? value, List<String> items, Function(String?) onChanged) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
      DropdownButton<String>(
        isExpanded: true,
        isDense: true,
        value: items.contains(value) ? value : null,
        hint: const Text('Select'),
        items: items.map((d) {
          String display = d;
          try { display = DateFormat('dd MMM yy').format(DateTime.parse(d)); } catch(e){}
          return DropdownMenuItem(value: d, child: Text(display, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)));
        }).toList(),
        onChanged: onChanged,
      ),
    ],
  );
}