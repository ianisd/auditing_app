import 'package:counting_app/screens/purchases_line_items_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../services/offline_storage.dart';
import '../services/grv_parser.dart';

class GrvInvoiceScreen extends StatefulWidget {
  final GrvData? preloadedData;

  const GrvInvoiceScreen({super.key, this.preloadedData});

  @override
  State<GrvInvoiceScreen> createState() => _GrvInvoiceScreenState();
}

class _GrvInvoiceScreenState extends State<GrvInvoiceScreen> {
  final _formKey = GlobalKey<FormState>();
  late String _supplierName;
  late String _invoiceNumber;
  late DateTime _deliveryDate;
  String? _selectedSupplierId;
  bool _isLoadingSuppliers = true;
  bool _isLoading = false;
  List<Map<String, dynamic>> _suppliers = [];
  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _safeShowSnackBar(String message, {Color backgroundColor = Colors.blue}) {
    if (_isDisposed || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  @override
  void initState() {
    super.initState();
    _supplierName = widget.preloadedData?.supplierName ?? '';
    _invoiceNumber = widget.preloadedData?.invoiceNumber ?? '';
    _deliveryDate = widget.preloadedData?.deliveryDate ?? DateTime.now();
    _loadSuppliers();
  }

  Future<void> _loadSuppliers() async {
    setState(() => _isLoadingSuppliers = true);
    try {
      final suppliers = await context.read<OfflineStorage>().getMasterSuppliers();

      if (!mounted) return;

      setState(() {
        _suppliers = suppliers;
        _isLoadingSuppliers = false;

        if (widget.preloadedData != null && suppliers.isNotEmpty) {
          _autoMatchSupplier(widget.preloadedData!.supplierName, suppliers);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingSuppliers = false);
    }
  }

  void _autoMatchSupplier(String supplierName, List<Map<String, dynamic>> suppliers) {
    final match = suppliers.firstWhere(
            (s) => _fuzzySupplierMatch(s['Supplier']?.toString() ?? '', supplierName),
        orElse: () => <String, dynamic>{} // Returns EMPTY MAP (non-null) instead of null
    );

    // Check for empty map instead of null
    if (match.isNotEmpty) {
      setState(() {
        _selectedSupplierId = match['supplierID']?.toString();
        _supplierName = match['Supplier']?.toString() ?? supplierName;
      });
    }
  }

  bool _fuzzySupplierMatch(String a, String b) {
    final cleanA = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final cleanB = b.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return cleanA.contains(cleanB) || cleanB.contains(cleanA);
  }

  Future<void> _uploadGrvCsv() async {
    if (_isDisposed || !mounted) return;

    if (!_formKey.currentState!.validate()) return;
    if (_selectedSupplierId == null) {
      _safeShowSnackBar('Please select a supplier');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        dialogTitle: 'Select GRV CSV File',
        withData: false,
      );

      if (result == null) return;

      final filePath = result.files.single.path!;
      if (filePath == null) throw Exception('File path is null - try again');

      final file = File(filePath);
      final content = await file.readAsString();

      if (content.length > 5 * 1024 * 1024) { // 5MB limit
        throw Exception('File too large (>5MB). Please split into smaller GRVs.');
      }

      final parser = GrvParser();
      final grvData = parser.parse(content);

      if (grvData.lineItems.isEmpty) {
        _safeShowSnackBar('⚠️ No line items found in CSV');
        return;
      }

      // Navigate to line items screen with preloaded data
      final navigationResult = await Navigator.push( // ✅ RENAMED: 'result' → 'navigationResult'
        context,
        MaterialPageRoute(
          builder: (context) => GrvLineItemsScreen(
            invoiceDetailsID: DateTime.now().millisecondsSinceEpoch.toString(),
            supplierName: _supplierName,
            deliveryDate: _deliveryDate,
            preloadedItems: grvData.lineItems,
          ),
        ),
      );

      if (navigationResult is GrvData) { // ✅ USE RENAMED VARIABLE
        Navigator.pop(context, navigationResult);
        return;
      }

      if (!_isDisposed && mounted) {
        _safeShowSnackBar('✓ CSV processed successfully');
      }
    } catch (e) {
      _safeShowSnackBar('CSV Error: $e', backgroundColor: Colors.red);
    } finally {
      if (!_isDisposed && mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _saveInvoiceAndNavigate() async {
    if (_isDisposed || !mounted) return;

    if (!_formKey.currentState!.validate()) return;
    if (_selectedSupplierId == null) {
      _safeShowSnackBar('Please select a supplier');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final invoiceId = DateTime.now().millisecondsSinceEpoch.toString();

      final invoice = {
        'invoiceDetailsID': invoiceId,
        'Invoice Number': _invoiceNumber.trim(),
        'supplierID': _selectedSupplierId!,
        'Supplier Name': _supplierName.trim(),
        'Date of Purchase': _deliveryDate.toIso8601String(),
        'Delivery Date': _deliveryDate.toIso8601String(),
        'Total Cost Ex Vat': 0.0,
        'syncStatus': 'pending',
      };

      await context.read<OfflineStorage>().saveInvoiceDetails(invoice);

      // Navigate to line items screen for manual entry
      final navigationResult = await Navigator.push( // ✅ RENAMED: 'result' → 'navigationResult'
        context,
        MaterialPageRoute(
          builder: (context) => GrvLineItemsScreen(
            invoiceDetailsID: invoiceId,
            supplierName: _supplierName,
            deliveryDate: _deliveryDate,
            preloadedItems: null, // No preloaded items for manual entry
          ),
        ),
      );

      if (navigationResult is GrvData) { // ✅ USE RENAMED VARIABLE
        Navigator.pop(context, navigationResult);
        return;
      }

      if (!_isDisposed && mounted) {
        _safeShowSnackBar('✓ Invoice saved - add line items manually');
      }
    } catch (e) {
      _safeShowSnackBar('Save error: $e', backgroundColor: Colors.red);
    } finally {
      if (!_isDisposed && mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GRV: Invoice Details'),
        actions: [
          if (widget.preloadedData != null)
            IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: _showCsvMetadata,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildSupplierField(),
            TextFormField(
              initialValue: _invoiceNumber,
              decoration: const InputDecoration(
                labelText: 'Invoice Number *',
                prefixIcon: Icon(Icons.description),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              onChanged: (v) => setState(() => _invoiceNumber = v ?? ''),
            ),
            const SizedBox(height: 16),
            _buildDateField('Delivery Date *', _deliveryDate, (date) => setState(() => _deliveryDate = date)),
            const SizedBox(height: 24),

            // ✅ COMBINED: CSV Upload + Manual Entry Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _uploadGrvCsv,
                    icon: _isLoading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                        : const Icon(Icons.upload_file),
                    label: const Text('CSV UPLOAD'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.blue,
                      disabledBackgroundColor: Colors.blue.shade200,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _saveInvoiceAndNavigate,
                    icon: const Icon(Icons.add),
                    label: const Text('MANUAL ENTRY'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.green,
                      disabledBackgroundColor: Colors.green.shade200,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'ℹ️ Delivery Date will be used for:\n• Date of Purchase\n• Delivery Date\n• Stock Delivery Date',
              style: TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupplierField() {
    if (_isLoadingSuppliers) {
      return const ListTile(
        leading: CircularProgressIndicator.adaptive(),
        title: Text('Loading suppliers...'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Supplier *', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        // initialValue (not deprecated 'value') + explicit type + null filtering
        DropdownButtonFormField<String>(
          value: _selectedSupplierId,
          decoration: const InputDecoration(
            labelText: 'Select supplier',
            border: OutlineInputBorder(),
          ),
          // Filter out items with null values BEFORE toList()
          items: _suppliers
              .where((s) => s['supplierID'] != null)
              .map((s) => DropdownMenuItem<String>(
            value: s['supplierID']?.toString(),
            child: Text(s['Supplier']?.toString() ?? 'Unknown'),
          ))
              .toList(),
          onChanged: (String? val) {
            setState(() {
              _selectedSupplierId = val;
              if (val != null) {
                // Safe firstWhere with non-null orElse
                final supplier = _suppliers.firstWhere(
                      (s) => s['supplierID']?.toString() == val,
                  orElse: () => <String, dynamic>{},
                );
                // Null-aware access (no unconditional [])
                _supplierName = supplier['Supplier']?.toString() ?? '';
              }
            });
          },
          validator: (v) => v == null ? 'Required' : null,
        ),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: _supplierName,
          decoration: const InputDecoration(
            labelText: 'Supplier Name',
            helperText: 'Auto-filled from supplier selection',
          ),
          enabled: false,
        ),
      ],
    );
  }

  Widget _buildDateField(String label, DateTime date, ValueChanged<DateTime> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.calendar_today),
          title: Text(label),
          subtitle: Text(DateFormat('EEEE, dd MMM yyyy').format(date)),
          onTap: () async {
            final safeContext = context;
            final picked = await showDatePicker(
              context: safeContext,
              initialDate: date,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (picked != null) onChanged(picked);
          },
        ),
      ],
    );
  }

  void _showCsvMetadata() {
    if (widget.preloadedData == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('CSV Metadata Extracted'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Supplier: ${widget.preloadedData!.supplierName}'),
            Text('Invoice: ${widget.preloadedData!.invoiceNumber}'),
            Text('Date: ${widget.preloadedData!.deliveryDate.toIso8601String().split('T')[0]}'),
            const SizedBox(height: 16),
            const Text('This data was auto-extracted from your GRV CSV file.', style: TextStyle(fontStyle: FontStyle.italic)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}