import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import '../services/variance_service.dart';
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
  Set<String> _selectedLocations = {};
  bool _showBalanced = false;

  List<VarianceItem> _fullReport = [];
  List<VarianceItem> _filteredReport = [];

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
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
    final stocks = await storage.getStockCounts();
    final purchases = await storage.getPurchases();
    // CHANGED: Use specific methods, removed getSales()
    final storeSalesData = await storage.getStoreSalesData();
    final itemSalesMap = await storage.getItemSalesMap();
    final inventory = await storage.getAllInventory();

    try {
      final results = await compute(_calculateVarianceIsolated, {
        'stocks': stocks,
        'purchases': purchases,
        'storeSalesData': storeSalesData,
        'itemSalesMap': itemSalesMap,
        'inventory': inventory,
        'dateFrom': _startDate,
        'dateTo': _endDate,
      });

      if (mounted) {
        setState(() {
          _fullReport = results;
          _applyLocalFilters();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _applyLocalFilters() {
    setState(() {
      _filteredReport = _fullReport.where((item) {
        // 1. Zero Variance Filter
        if (!_showBalanced) {
          if (item.variance.abs() < 0.001) return false;
        }

        // 2. Location Filter
        if (_selectedLocations.isNotEmpty) {
          bool foundInLocation = item.allEntries.any((entry) {
            final loc = entry['location']?.toString() ?? '';
            return _selectedLocations.contains(loc);
          });

          if (!foundInLocation) return false;
        }

        return true;
      }).toList();
    });
  }

  // --- ACTIONS ---
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
                TextButton(
                    onPressed: () {
                      _selectedLocations.clear();
                      Navigator.pop(context);
                      _applyLocalFilters();
                    },
                    child: const Text('Clear All')
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _applyLocalFilters();
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

  void _editCount(Map<String, dynamic> count) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => CountScreen(existingCount: count)),
    );
    _runReport();
  }

  void _addNewCount(VarianceItem item) async {
    if (item.inventoryItem == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CountScreen(
          initialProduct: item.inventoryItem,
          initialDate: DateTime.parse(_endDate!),
        ),
      ),
    );
    _runReport();
  }

  @override
  Widget build(BuildContext context) {
    // Logic: Only show dates older than Current Date for "Previous" dropdown
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
            margin: const EdgeInsets.all(8),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Expanded(
                    child: _buildDateDropdown(
                        'Previous',
                        _startDate,
                        previousDates,
                            (val) {
                          setState(() => _startDate = val);
                          _runReport();
                        }
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.0),
                    child: Icon(Icons.arrow_forward, color: Colors.grey),
                  ),
                  Expanded(
                    child: _buildDateDropdown(
                        'Current',
                        _endDate,
                        _availableDates,
                            (val) {
                          setState(() {
                            _endDate = val;
                            if (_startDate != null && _startDate!.compareTo(val!) >= 0) {
                              if (previousDates.isNotEmpty) _startDate = previousDates[0];
                              else _startDate = null;
                            }
                          });
                          _runReport();
                        }
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 2. FILTERS ROW
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                ActionChip(
                  avatar: const Icon(Icons.filter_alt, size: 16),
                  label: Text(_selectedLocations.isEmpty
                      ? 'All Locations'
                      : '${_selectedLocations.length} Locations'),
                  onPressed: _openLocationFilter,
                ),
                const Spacer(),
                const Text("Show Balanced", style: TextStyle(fontSize: 12)),
                Switch(
                  value: _showBalanced,
                  onChanged: (val) {
                    setState(() => _showBalanced = val);
                    _applyLocalFilters();
                  },
                ),
              ],
            ),
          ),

          // 3. REPORT LIST
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredReport.isEmpty
                ? const Center(child: Text('No variance data found.'))
                : _buildReportList(),
          ),
        ],
      ),
    );
  }

  Widget _buildDateDropdown(String label, String? value, List<String> items, Function(String?) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
        DropdownButton<String>(
          isExpanded: true,
          value: items.contains(value) ? value : null,
          hint: const Text('Select'),
          items: items.map((d) {
            String display = d;
            try { display = DateFormat('dd MMM yyyy').format(DateTime.parse(d)); } catch(e){}
            return DropdownMenuItem(value: d, child: Text(display, overflow: TextOverflow.ellipsis));
          }).toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildReportList() {
    return ListView.separated(
      itemCount: _filteredReport.length,
      separatorBuilder: (c, i) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = _filteredReport[index];
        final isLoss = item.variance < -0.05;
        final isGain = item.variance > 0.05;
        final color = isLoss ? Colors.red : (isGain ? Colors.green : Colors.grey);
        final productName = item.productName.isEmpty ? 'Unknown Product' : item.productName.toUpperCase();

        final Map<String, List<Map<String, dynamic>>> groupedCounts = {};
        for (var entry in item.allEntries) {
          final d = entry['date'].toString().split('T')[0];
          if (!groupedCounts.containsKey(d)) groupedCounts[d] = [];
          groupedCounts[d]!.add(entry);
        }
        final sortedDates = groupedCounts.keys.toList()..sort((a, b) => b.compareTo(a));
        bool hasCountToday = groupedCounts.containsKey(_endDate);

        return ExpansionTile(
          leading: CircleAvatar(
            backgroundColor: color.withOpacity(0.1),
            child: Text(
                item.variance.abs().toStringAsFixed(1),
                style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)
            ),
          ),
          title: Text(productName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Theo: ${item.theoreticalStock.toStringAsFixed(2)}'),
              Text('Actual: ${item.currentCount.toStringAsFixed(2)}'),
            ],
          ),
          trailing: Text(
            NumberFormat.simpleCurrency(name: 'R').format(item.varianceValue),
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDetailRow('Previous Count', item.previousCount),
                  _buildDetailRow('Purchases (+)', item.purchases),
                  _buildDetailRow('Sales (-)', item.sales),
                  const Divider(),
                  _buildDetailRow('Theoretical', item.theoreticalStock, isBold: true),
                  _buildDetailRow('Actual Count', item.currentCount, isBold: true),
                  const Divider(),
                  _buildDetailRow('Variance', item.variance, color: color, isBold: true),

                  const SizedBox(height: 16),
                  const Text('Count History:', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),

                  if (sortedDates.isEmpty)
                    const Text('No count history in range.', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey)),

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
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          decoration: BoxDecoration(color: headerColor.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                          child: Text(
                            isCurrent ? '$prettyDate (Current)' : (isStart ? '$prettyDate (Start)' : prettyDate),
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: headerColor),
                          ),
                        ),
                        ...entries.map((entry) {
                          final qty = double.tryParse(entry['total_bottles']?.toString() ?? '0') ?? 0;
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.only(left: 8),
                            title: Text(entry['location'] ?? 'Unknown'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(qty.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(width: 8),
                                const Icon(Icons.edit, size: 16, color: Colors.blue),
                              ],
                            ),
                            onTap: () => _editCount(entry),
                          );
                        }),
                        const SizedBox(height: 8),
                      ],
                    );
                  }),

                  if (!hasCountToday) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _addNewCount(item),
                        icon: const Icon(Icons.add),
                        label: Text('Add Count for Today'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue,
                          side: const BorderSide(color: Colors.blue),
                        ),
                      ),
                    ),
                  ]
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDetailRow(String label, double value, {bool isBold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
          Text(value.toStringAsFixed(2), style: TextStyle(fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
        ],
      ),
    );
  }
}

// TOP LEVEL FUNCTION
List<VarianceItem> _calculateVarianceIsolated(Map<String, dynamic> params) {
  final service = VarianceService();
  return service.calculateReport(
    stocks: params['stocks'],
    purchases: params['purchases'],
    storeSalesData: params['storeSalesData'],
    itemSalesMap: params['itemSalesMap'],
    inventory: params['inventory'],
    dateFromStr: params['dateFrom'],
    dateToStr: params['dateTo'],
  );
}