import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
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
  bool _isDragging = false;
  String? _selectedSupplierId;
  String? _canonicalSupplierName;

  Future<void> _pickAndParseCsvFromPath(String filePath) async {
    setState(() => _isLoading = true);
    try {
      final file = File(filePath);
      String content;
      try {
        content = await file.readAsString();
      } catch (e) {
        content = await file.readAsString(encoding: latin1);
      }
      await _processContent(content);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isDragging = false;
        });
      }
    }
  }

  Future<void> _pickAndParseCsv() async {
    setState(() => _isLoading = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        dialogTitle: 'Select GRV CSV File',
      );

      if (result == null) {
        setState(() => _isLoading = false);
        return;
      }

      final file = File(result.files.single.path!);
      String content;

      try {
        content = await file.readAsString();
      } catch (e) {
        print('⚠️ UTF-8 decoding failed, trying Latin-1 (Excel format)...');
        content = await file.readAsString(encoding: latin1);
      }
      await _processContent(content);
    } catch (e) {
      print('❌ Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _processContent(String content) async {
    final parser = GrvParser();
    final grvData = parser.parse(content);

    print('✅ PARSED: ${grvData.lineItems.length} items');
    print('   Supplier: ${grvData.supplierName}');
    print('   Invoice: ${grvData.invoiceNumber}');
    print('   GRV Ref: ${grvData.grvReference}');
    print('   Delivery Date: ${grvData.deliveryDate}');

    if (grvData.lineItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No items found in CSV')));
      }
      return;
    }

    final storage = context.read<OfflineStorage>();

    String? supplierId;
    String? canonicalName;

    // Get supplier with auto-creation
    supplierId = await storage.findSupplierIdByAnyName(
      grvData.supplierName,
      allowAutoCreate: true,
    );

    if (supplierId != null) {
      final suppliers = await storage.getMasterSuppliers();
      final supplier = suppliers.firstWhere(
        (s) => s['supplierID']?.toString() == supplierId,
        orElse: () => <String, dynamic>{},
      );
      canonicalName = supplier['Supplier']?.toString() ?? grvData.supplierName;
      print('✅ Found mapped supplier: $canonicalName (ID: $supplierId)');
    } else {
      supplierId = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
      canonicalName = grvData.supplierName;
      print('⚠️ Using fallback supplier: $canonicalName');
    }

    _selectedSupplierId = supplierId;
    _canonicalSupplierName = canonicalName;

    if (!mounted) return;

    // 🔥 Check for duplicate with ALL 4 factors: Supplier ID + Invoice Number + GRV + Delivery Date
    Map<String, dynamic>? existingInvoice;
    if (grvData.invoiceNumber.isNotEmpty) {
      existingInvoice = await storage.findInvoiceBySupplierAndNumber(
        supplierName: grvData.supplierName,
        invoiceNumber: grvData.invoiceNumber,
        grvReference: grvData.grvReference,
        supplierId: supplierId,
        deliveryDate: grvData.deliveryDate
            .toIso8601String(), // 🔥 Pass delivery date
      );
    }

    // Build dialog content with date info
    final confirm = await showDialog<dynamic>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          existingInvoice != null
              ? '⚠️ Duplicate GRV Detected'
              : 'Confirm GRV Details',
          style: TextStyle(
            color: existingInvoice != null ? Colors.orange : Colors.blue,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (existingInvoice != null) ...[
              Text(
                'Invoice #${grvData.invoiceNumber} from $_canonicalSupplierName already exists.',
              ),
              const SizedBox(height: 8),
              Text(
                'Existing date: ${existingInvoice['Delivery Date']?.toString().split('T')[0] ?? existingInvoice['Date of Purchase']?.toString().split('T')[0] ?? 'Unknown'}',
              ),
              Text(
                'New date: ${grvData.deliveryDate.toIso8601String().split('T')[0]}',
              ),
              const SizedBox(height: 4),
              Text(
                'Existing GRV: ${existingInvoice['GRV Reference'] ?? 'N/A'}',
              ),
              Text('New GRV: ${grvData.grvReference}'),
              const SizedBox(height: 16),
              const Text(
                'What would you like to do?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('• UPDATE: Keep existing invoice, add/update items'),
              const Text('• CREATE NEW: Create a new GRV (keeps both)'),
              const Text('• CANCEL: Stop this upload'),
            ] else ...[
              _buildInfoRow('Supplier', grvData.supplierName),
              if (_canonicalSupplierName != grvData.supplierName)
                _buildInfoRow('Mapped To', _canonicalSupplierName!),
              _buildInfoRow('Invoice', grvData.invoiceNumber),
              _buildInfoRow('GRV Ref', grvData.grvReference),
              _buildInfoRow(
                'Delivery Date',
                grvData.deliveryDate.toIso8601String().split('T')[0],
              ),
              _buildInfoRow('Items', '${grvData.lineItems.length}'),
              const Divider(height: 24),
              const Text(
                'Items found:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              ...grvData.lineItems
                  .take(3)
                  .map(
                    (item) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '• ${item.description} (${item.quantityCases} × ${item.unitsPerCase})',
                      ),
                    ),
                  ),
              if (grvData.lineItems.length > 3)
                Text(' ... and ${grvData.lineItems.length - 3} more'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          if (existingInvoice != null)
            OutlinedButton(
              onPressed: () => Navigator.pop(context, 'create_new'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
              child: const Text('CREATE NEW'),
            ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: existingInvoice != null
                  ? Colors.blue
                  : Colors.green,
            ),
            child: Text(existingInvoice != null ? 'UPDATE' : 'CONTINUE'),
          ),
        ],
      ),
    );

    if (confirm == false || confirm == null) {
      setState(() => _isLoading = false);
      return;
    }

    // Handle the duplicate action
    String finalInvoiceId;

    if (existingInvoice != null && confirm == 'create_new') {
      finalInvoiceId = _generateUuid();
      print('🆕 Creating new GRV with new ID: $finalInvoiceId');
    } else if (existingInvoice != null && confirm == true) {
      finalInvoiceId =
          existingInvoice['invoiceDetailsID']?.toString() ?? _generateUuid();
      print('🔄 Updating existing GRV with ID: $finalInvoiceId');
    } else {
      finalInvoiceId = _generateUuid();
    }

    // Save the invoice
    final invoiceData = {
      'invoiceDetailsID': finalInvoiceId,
      'Invoice Number': grvData.invoiceNumber,
      'GRV Reference': grvData.grvReference ?? '',
      'supplierID': supplierId ?? '',
      'Supplier Name': canonicalName ?? grvData.supplierName,
      'Date of Purchase': grvData.deliveryDate.toIso8601String(),
      'Delivery Date': grvData.deliveryDate.toIso8601String(),
      'Total Cost Ex Vat': 0.0,
      'syncStatus': 'pending',
    };

    final savedInvoiceId = await storage.saveInvoiceDetails(invoiceData);
    print('✅ Invoice saved/updated with ID: $savedInvoiceId');

    if (mounted) {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => GrvLineItemsScreen(
            invoiceDetailsID: savedInvoiceId,
            supplierName: canonicalName ?? grvData.supplierName,
            deliveryDate: grvData.deliveryDate,
            grvReference: grvData.grvReference,
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
        if (Navigator.canPop(context)) {
          Navigator.pop(context, true);
        }
      }
    }
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);

    return Scaffold(
      appBar: AppBar(title: const Text('Upload GRV CSV')),
      body: SingleChildScrollView(
        // ✅ FIX: Wrap in SingleChildScrollView
        padding: const EdgeInsets.all(32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20), // Top spacing
                // Drag-and-drop zone (desktop only)
                if (isDesktop)
                  DropTarget(
                    onDragDone: (details) async {
                      final files = details.files;
                      if (files.isEmpty) return;
                      final path = files.first.path;
                      if (!path.toLowerCase().endsWith('.csv')) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Only CSV files are supported'),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }
                      await _pickAndParseCsvFromPath(path);
                    },
                    onDragEntered: (_) => setState(() => _isDragging = true),
                    onDragExited: (_) => setState(() => _isDragging = false),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: double.infinity,
                      height: 200,
                      decoration: BoxDecoration(
                        color: _isDragging
                            ? Colors.blue.shade50
                            : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _isDragging
                              ? Colors.blue
                              : Colors.grey.shade300,
                          width: _isDragging ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _isDragging
                                ? Icons.file_download
                                : Icons.upload_file,
                            size: 48,
                            color: _isDragging
                                ? Colors.blue
                                : Colors.grey.shade400,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _isDragging
                                ? 'Drop to upload'
                                : 'Drag & drop a CSV file here',
                            style: TextStyle(
                              fontSize: 16,
                              color: _isDragging
                                  ? Colors.blue
                                  : Colors.grey.shade500,
                              fontWeight: _isDragging
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (isDesktop) const SizedBox(height: 16),
                if (isDesktop)
                  Row(
                    children: [
                      Expanded(child: Divider(color: Colors.grey.shade300)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'or',
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                      ),
                      Expanded(child: Divider(color: Colors.grey.shade300)),
                    ],
                  ),

                if (!isDesktop) ...[
                  Icon(
                    Icons.upload_file,
                    size: 80,
                    color: Colors.blue.shade200,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Select a CSV file to upload',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                ],

                const SizedBox(height: 16),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _pickAndParseCsv,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open),
                    label: Text(
                      _isLoading ? 'Processing...' : 'Browse for CSV File',
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Info text
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'The system will automatically extract:\n'
                    '• Supplier name\n'
                    '• Invoice number\n'
                    '• Delivery date\n'
                    '• Line items',
                    style: TextStyle(color: Colors.blueGrey, fontSize: 13),
                  ),
                ),

                const SizedBox(height: 20), // Bottom spacing
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _generateUuid() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random();
    return String.fromCharCodes(
      Iterable.generate(8, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))),
    );
  }
}
