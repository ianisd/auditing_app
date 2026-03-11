import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';

class DebugDataScreen extends StatefulWidget {
  const DebugDataScreen({super.key});

  @override
  State<DebugDataScreen> createState() => _DebugDataScreenState();
}

class _DebugDataScreenState extends State<DebugDataScreen> {
  List<String> purchaseDates = [];
  List<String> salesDates = [];
  bool _isMigrating = false;
  String? _migrationResult;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final storage = context.read<OfflineStorage>();

    // 1. Get Purchases
    final p = await storage.getPurchases();

    // 2. Get Sales (FIXED METHOD NAME)
    final s = await storage.getStoreSalesData();

    setState(() {
      // Map 'Inv. Date of Purchase' from Purchases
      purchaseDates = p.take(50).map((e) => "Inv: ${e['Inv. Date of Purchase']}").toList();

      // Map 'Date' from Store Sales Data
      salesDates = s.take(50).map((e) => "Sale: ${e['Date']}").toList();
    });
  }

  // 🔥 NEW: Migration method
  Future<void> _migrateInvoiceIds() async {
    setState(() {
      _isMigrating = true;
      _migrationResult = null;
    });

    try {
      final storage = context.read<OfflineStorage>();
      await storage.migrateOldInvoiceIds();

      setState(() {
        _migrationResult = '✅ Migration completed successfully';
        _isMigrating = false;
      });

      // Refresh data to show changes
      await _loadData();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invoice ID migration complete'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      setState(() {
        _migrationResult = '❌ Migration failed: $e';
        _isMigrating = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Migration error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data Debugger'),
        actions: [
          // 🔥 NEW: Migration button
          if (_isMigrating)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.update),
              tooltip: 'Migrate Invoice IDs',
              onPressed: _migrateInvoiceIds,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
        ],
      ),
      body: Column(
        children: [
          // 🔥 NEW: Migration status message
          if (_migrationResult != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: _migrationResult!.startsWith('✅')
                  ? Colors.green.shade100
                  : Colors.red.shade100,
              child: Text(
                _migrationResult!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _migrationResult!.startsWith('✅')
                      ? Colors.green.shade900
                      : Colors.red.shade900,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildList("Purchases (Raw)", purchaseDates)),
                const VerticalDivider(width: 1),
                Expanded(child: _buildList("Sales (Raw)", salesDates)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(String title, List<String> items) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          color: Colors.grey[200],
          width: double.infinity,
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.center),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text("No Data Found"))
              : ListView.builder(
            itemCount: items.length,
            itemBuilder: (c, i) => Padding(
              padding: const EdgeInsets.all(4.0),
              child: Text(items[i], style: const TextStyle(fontSize: 11)),
            ),
          ),
        ),
      ],
    );
  }
}
