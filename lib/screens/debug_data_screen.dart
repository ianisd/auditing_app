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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data Debugger')),
      body: Row(
        children: [
          Expanded(child: _buildList("Purchases (Raw)", purchaseDates)),
          const VerticalDivider(width: 1),
          Expanded(child: _buildList("Sales (Raw)", salesDates)),
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