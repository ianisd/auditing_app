import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:math';
import 'dart:convert'; // 1. IMPORT THIS for encoding
import '../services/grv_parser.dart';
import '../services/offline_storage.dart';
import 'grv_line_items_screen.dart';
import 'package:provider/provider.dart';

class GrvUploadScreen extends StatefulWidget {
  const GrvUploadScreen({super.key});

  @override
  State<GrvUploadScreen> createState() => _GrvUploadScreenState();
}

class _GrvUploadScreenState extends State<GrvUploadScreen> {
  bool _isLoading = false;
  String? _selectedSupplierId;
  String? _canonicalSupplierName;

  Future<void> _pickAndParseCsv() async {
    setState(() => _isLoading = true);

    try {
      // 1. Pick CSV file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        dialogTitle: 'Select GRV CSV File',
      );

      if (result == null) {
        setState(() => _isLoading = false);
        return;
      }

      // 2. Read and parse CSV (Updated Logic)
      final file = File(result.files.single.path!);
      String content;

      try {
        // Try reading as UTF-8 first (Modern Standard)
        content = await file.readAsString();
      } catch (e) {
        print('⚠️ UTF-8 decoding failed, trying Latin-1 (Excel format)...');
        // If that fails, try reading as Latin-1 (Excel/Windows Standard)
        content = await file.readAsString(encoding: latin1);
      }

      final parser = GrvParser();
      final grvData = parser.parse(content);

      print('✅ PARSED: ${grvData.lineItems.length} items');
      print('   Supplier: ${grvData.supplierName}');
      print('   Invoice: ${grvData.invoiceNumber}');
      print('   Date: ${grvData.deliveryDate}');

      if (grvData.lineItems.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No items found in CSV')),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      // 3. Find matching supplier using mapping system
      final storage = context.read<OfflineStorage>();

      // 🔴 NEW: Try to find by mapping first
      String? supplierId;
      String? canonicalName;

      supplierId = await storage.findSupplierIdByAnyName(grvData.supplierName);

      if (supplierId != null) {
        // Get the canonical name from master suppliers
        final suppliers = await storage.getMasterSuppliers();
        final supplier = suppliers.firstWhere(
              (s) => s['supplierID']?.toString() == supplierId,
          orElse: () => <String, dynamic>{},
        );
        canonicalName = supplier['Supplier']?.toString() ?? grvData.supplierName;
        print('✅ Found mapped supplier: $canonicalName (ID: $supplierId)');
      } else {
        // Fall back to original matching
        print('⚠️ No mapping found, trying fuzzy match for: ${grvData.supplierName}');
        final suppliers = await storage.getMasterSuppliers();

        final matchingSupplier = suppliers.firstWhere(
              (s) => s['Supplier']?.toString().toLowerCase().contains(
              grvData.supplierName.toLowerCase()
          ) ?? false,
          orElse: () => <String, dynamic>{},
        );

        if (matchingSupplier.isNotEmpty) {
          supplierId = matchingSupplier['supplierID']?.toString();
          canonicalName = matchingSupplier['Supplier']?.toString() ?? grvData.supplierName;

          // 🔴 NEW: Auto-create a mapping for next time
          await storage.addSupplierMapping(grvData.supplierName, supplierId!);
          print('✅ Created new mapping: "${grvData.supplierName}" -> $canonicalName');
        } else {
          print('⚠️ No matching supplier found for: ${grvData.supplierName}');
        }
      }

      _selectedSupplierId = supplierId;
      _canonicalSupplierName = canonicalName;

      // 4. Show confirmation dialog with extracted data
      if (!mounted) return;

      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm GRV Details'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow('CSV Supplier', grvData.supplierName),
              if (_canonicalSupplierName != null && _canonicalSupplierName != grvData.supplierName)
                _buildInfoRow('Mapped To', _canonicalSupplierName!),
              _buildInfoRow('Invoice', grvData.invoiceNumber),
              _buildInfoRow('Date', grvData.deliveryDate.toIso8601String().split('T')[0]),
              _buildInfoRow('Items', '${grvData.lineItems.length}'),
              const Divider(height: 24),
              const Text('Items found:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...grvData.lineItems.take(3).map((item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• ${item.description} (${item.quantityCases} × ${item.unitsPerCase})'),
              )),
              if (grvData.lineItems.length > 3)
                Text(' ... and ${grvData.lineItems.length - 3} more'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );

      if (confirm != true) {
        setState(() => _isLoading = false);
        return;
      }

      // 5. Save invoice header (use canonical name if available)
      final invoiceId = _generateUuid(); // Requires the helper function I gave you previously
      final invoice = {
        'invoiceDetailsID': invoiceId,
        'Invoice Number': grvData.invoiceNumber,
        'supplierID': _selectedSupplierId ?? '',
        'Supplier Name': _canonicalSupplierName ?? grvData.supplierName,
        'Date of Purchase': grvData.deliveryDate.toIso8601String(),
        'Delivery Date': grvData.deliveryDate.toIso8601String(),
        'Total Cost Ex Vat': 0.0,
        'syncStatus': 'pending',
      };

      await storage.saveInvoiceDetails(invoice);
      print('✅ Invoice saved with ID: $invoiceId');

      // 6. Navigate to line items screen
      if (mounted) {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GrvLineItemsScreen(
              invoiceDetailsID: invoiceId,
              supplierName: _canonicalSupplierName ?? grvData.supplierName,
              deliveryDate: grvData.deliveryDate,
              preloadedItems: grvData.lineItems,
            ),
          ),
        );

        if (result == true && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✓ GRV saved with ${grvData.lineItems.length} items'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context, true);
        }
      }

    } catch (e) {
      print('❌ Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text('$label:', style: const TextStyle(fontWeight: FontWeight.bold))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload GRV CSV'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.upload_file,
              size: 80,
              color: Colors.blue.shade200,
            ),
            const SizedBox(height: 24),
            const Text(
              'Select a CSV file to upload',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'The system will automatically extract:\n'
                  '• Supplier name\n'
                  '• Invoice number\n'
                  '• Delivery date\n'
                  '• Line items',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _pickAndParseCsv,
              icon: _isLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload),
              label: Text(_isLoading ? 'Processing...' : 'Select CSV File'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );

  }
  // Add this inside the class
  String _generateUuid() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random();
    return String.fromCharCodes(Iterable.generate(
        8, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }
}