import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import '../services/variance_service.dart';

class VarianceReportScreen extends StatefulWidget {
  const VarianceReportScreen({super.key});

  @override
  State<VarianceReportScreen> createState() => _VarianceReportScreenState();
}

class _VarianceReportScreenState extends State<VarianceReportScreen> {
  String? _startDate; // YYYY-MM-DD
  String? _endDate;   // YYYY-MM-DD
  List<String> _availableDates = [];
  List<VarianceItem> _report = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadAvailableDates();
  }

  Future<void> _loadAvailableDates() async {
    final storage = context.read<OfflineStorage>();
    final counts = await storage.getStockCounts();
    final dates = counts.map((e) {
      final raw = e['date'].toString();
      // Handle T08:00...
      return raw.contains('T') ? raw.split('T')[0] : raw;
    }).toSet().toList();

    // Sort Newest First
    dates.sort((a, b) => b.compareTo(a));

    setState(() {
      _availableDates = dates;
      // Auto-select latest 2 dates if available
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

    // Slight delay to allow UI to render spinner
    await Future.delayed(const Duration(milliseconds: 100));

    final storage = context.read<OfflineStorage>();
    final stocks = await storage.getStockCounts();
    final purchases = await storage.getPurchases();
    final sales = await storage.getSales();
    final inventory = await storage.getAllInventory();

    final service = VarianceService();
    final results = service.calculateReport(
      stocks: stocks,
      purchases: purchases,
      sales: sales,
      inventory: inventory,
      dateFromStr: _startDate!,
      dateToStr: _endDate!,
    );

    if (mounted) {
      setState(() {
        _report = results;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Variance Report')),
      body: Column(
        children: [
          // --- DATE SELECTORS ---
          Card(
            margin: const EdgeInsets.all(8),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Expanded(
                    child: _buildDateDropdown('Previous', _startDate, (val) {
                      setState(() => _startDate = val);
                      _runReport();
                    }),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.0),
                    child: Icon(Icons.arrow_forward, color: Colors.grey),
                  ),
                  Expanded(
                    child: _buildDateDropdown('Current', _endDate, (val) {
                      setState(() => _endDate = val);
                      _runReport();
                    }),
                  ),
                ],
              ),
            ),
          ),

          // --- REPORT BODY ---
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _report.isEmpty
                ? const Center(child: Text('No variance data found for these dates.'))
                : _buildReportList(),
          ),
        ],
      ),
    );
  }

  Widget _buildDateDropdown(String label, String? value, Function(String?) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
        DropdownButton<String>(
          isExpanded: true,
          value: value,
          hint: const Text('Select Date'),
          items: _availableDates.map((d) {
            // Pretty Date for Dropdown
            String display = d;
            try { display = DateFormat('dd MMM').format(DateTime.parse(d)); } catch(e){}
            return DropdownMenuItem(value: d, child: Text(display));
          }).toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildReportList() {
    return ListView.separated(
      itemCount: _report.length,
      separatorBuilder: (c, i) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = _report[index];
        final isLoss = item.variance < 0;
        final isGain = item.variance > 0;
        final color = isLoss ? Colors.red : (isGain ? Colors.green : Colors.grey);

        return ExpansionTile(
          leading: CircleAvatar(
            backgroundColor: color.withOpacity(0.1),
            child: Text(
                item.variance.abs().toStringAsFixed(1),
                style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)
            ),
          ),
          title: Text(item.productName.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
                children: [
                  _buildDetailRow('Previous Count', item.previousCount),
                  _buildDetailRow('Purchases (+)', item.purchases),
                  _buildDetailRow('Sales (-)', item.sales),
                  const Divider(),
                  _buildDetailRow('Theoretical', item.theoreticalStock, isBold: true),
                  _buildDetailRow('Actual Count', item.currentCount, isBold: true),
                  const Divider(),
                  _buildDetailRow('Variance', item.variance, color: color, isBold: true),
                  const SizedBox(height: 10),
                  const Text('Count Locations:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  if (item.locations.isEmpty)
                    const Text('No count data found', style: TextStyle(fontStyle: FontStyle.italic))
                  else
                    ...item.locations.map((l) => Text(l, style: const TextStyle(fontSize: 12))),
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