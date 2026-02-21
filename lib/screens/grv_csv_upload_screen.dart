import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/offline_storage.dart';
import '../services/grv_parser.dart';

class GrvCsvUploadScreen extends StatefulWidget {
  final String invoiceDetailsID;
  final String supplierName;
  final DateTime deliveryDate;

  const GrvCsvUploadScreen({
    super.key,
    required this.invoiceDetailsID,
    required this.supplierName,
    required this.deliveryDate,
  });

  @override
  State<GrvCsvUploadScreen> createState() => _GrvCsvUploadScreenState();
}

class _GrvCsvUploadScreenState extends State<GrvCsvUploadScreen> {
  bool _isLoading = false;
  String _statusMessage = 'Select a GRV CSV file to begin.';
  Color _statusColor = Colors.blue;

  Future<void> _uploadCsv() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _statusMessage = 'Selecting file...';
      _statusColor = Colors.orange;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        dialogTitle: 'Select GRV CSV File',
        withData: false,
      );

      if (result == null) {
        setState(() {
          _statusMessage = 'No file selected.';
          _statusColor = Colors.grey;
          _isLoading = false;
        });
        return;
      }

      final filePath = result.files.single.path!;
      if (filePath == null) throw Exception('File path is null');

      setState(() {
        _statusMessage = 'Reading file...';
      });

      final file = File(filePath);
      final content = await file.readAsString();

      if (content.length > 5 * 1024 * 1024) {
        throw Exception('File too large (>5MB). Please split into smaller GRVs.');
      }

      setState(() {
        _statusMessage = 'Parsing CSV...';
      });

      final parser = GrvParser();
      final grvData = parser.parse(content);

      if (grvData.lineItems.isEmpty) {
        throw Exception('No line items found in CSV.');
      }

      setState(() {
        _statusMessage = 'Saving ${grvData.lineItems.length} items...';
      });

      // Save items to purchases
      final storage = context.read<OfflineStorage>();
      int savedCount = 0;
      const batchSize = 20;

      for (var i = 0; i < grvData.lineItems.length; i += batchSize) {
        final batch = grvData.lineItems.skip(i).take(batchSize).toList();
        for (var item in batch) {
          final purchase = {
            'purchases_ID': DateTime.now().millisecondsSinceEpoch.toString(),
            'invoiceDetailsID': widget.invoiceDetailsID,
            'supplierID': '', // TODO: populate from invoice if needed
            'Supplier': widget.supplierName,
            'Barcode': item.barcode,
            'Purchased Product Name': item.description,
            'purSupplierBottleID': item.plu,
            'Cost Per Bottle': item.pricePerUnit,
            'Stock Delivery Date': widget.deliveryDate.toIso8601String(),
            'Case/Pack Size': 'Case ${item.unitsPerCase}',
            'Qty Purchased': item.quantityCases.toDouble(),
            'Purchases Bottles': (item.quantityCases * item.unitsPerCase).toDouble(),
            'Cost of Purchases': item.pricePerUnit * item.quantityCases * item.unitsPerCase,
            'syncStatus': 'pending',
          };
          await storage.savePurchase(purchase);
          savedCount++;
        }
        await Future.delayed(const Duration(milliseconds: 50)); // Small delay to prevent blocking UI
      }

      setState(() {
        _statusMessage = '✓ Successfully saved $savedCount items!';
        _statusColor = Colors.green;
        _isLoading = false;
      });

      // Optionally navigate back after a delay
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: ${e.toString().split('\n').first}';
        _statusColor = Colors.red;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upload GRV CSV')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Info Card
            Container(
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Supplier: ${widget.supplierName}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('Delivery: ${widget.deliveryDate.toIso8601String().split('T')[0]}', style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Text('This will add items from your CSV file to this GRV.', style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Status Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _statusColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _statusColor),
              ),
              child: Text(
                _statusMessage,
                style: TextStyle(color: _statusColor),
              ),
            ),

            const SizedBox(height: 24),

            // Upload Button
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _uploadCsv,
              icon: _isLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                  : const Icon(Icons.upload_file),
              label: const Text('SELECT CSV FILE'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),

            const SizedBox(height: 16),

            // Help Text
            const Text(
              'Requirements:\n• CSV format\n• Max 5MB file size\n• Must contain PLU, Description, Quantity, Price',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}