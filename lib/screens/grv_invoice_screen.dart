import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import 'grv_line_items_screen.dart';

class GrvInvoiceScreen extends StatefulWidget {
  const GrvInvoiceScreen({super.key});

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
  final TextEditingController _invoiceNumberController = TextEditingController();

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _safeShowSnackBar(String message, {Color backgroundColor = Colors.blue}) {
    if (_isDisposed || !mounted) return;
    print('DEBUG: Showing snackbar: $message');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  @override
  void initState() {
    super.initState();
    _supplierName = '';
    _invoiceNumber = '';
    _deliveryDate = DateTime.now();
    _loadSuppliers();
  }

  Future<void> _loadSuppliers() async {
    print('DEBUG: Loading suppliers...');
    setState(() => _isLoadingSuppliers = true);
    try {
      final suppliers = await context.read<OfflineStorage>().getMasterSuppliers();
      print('DEBUG: Loaded ${suppliers.length} suppliers');

      if (!mounted) return;

      setState(() {
        _suppliers = suppliers;
        _isLoadingSuppliers = false;
      });
    } catch (e) {
      print('ERROR: Loading suppliers failed: $e');
      if (!mounted) return;
      setState(() => _isLoadingSuppliers = false);
    }
  }

  Future<void> _saveInvoiceAndNavigate() async {
    print('DEBUG: _saveInvoiceAndNavigate() called');
    if (_isDisposed || !mounted) return;

    if (!_formKey.currentState!.validate()) return;

    // 🔴 NEW: Try to find supplier by name if not selected
    if (_selectedSupplierId == null && _supplierName.isNotEmpty) {
      print('DEBUG: Attempting to find supplier by name: $_supplierName');
      final foundId = await context.read<OfflineStorage>()
          .findSupplierIdByAnyName(_supplierName);

      if (foundId != null) {
        // Update the selected supplier ID
        _selectedSupplierId = foundId;

        // Update to canonical supplier name
        final suppliers = await context.read<OfflineStorage>().getMasterSuppliers();
        final supplier = suppliers.firstWhere(
              (s) => s['supplierID']?.toString() == foundId,
          orElse: () => <String, dynamic>{},
        );

        if (supplier.isNotEmpty) {
          final canonicalName = supplier['Supplier']?.toString();
          if (canonicalName != null && canonicalName.isNotEmpty) {
            setState(() {
              _supplierName = canonicalName;
            });
            print('DEBUG: Updated to canonical name: $canonicalName');
          }
        }

        print('DEBUG: Found supplier via mapping: $_selectedSupplierId');
      } else {
        print('DEBUG: No supplier found for name: $_supplierName');
      }
    }

    // Final check for supplier ID
    if (_selectedSupplierId == null) {
      _safeShowSnackBar('Please select a supplier or enter a valid supplier name');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final invoiceId = DateTime.now().millisecondsSinceEpoch.toString();
      print('DEBUG: Creating invoice with ID: $invoiceId');

      // 🔴 CRITICAL: Use _invoiceNumber (the String variable) instead of _invoiceNumberController
      String rawInvoiceNumber = _invoiceNumber;  // ← FIXED: Use _invoiceNumber
      String invoiceNumber = rawInvoiceNumber.trim();

      // Debug the invoice number thoroughly
      print('🔍 INVOICE NUMBER DETAILED DEBUG:');
      print('  - Raw value: "$rawInvoiceNumber"');
      print('  - Trimmed text: "$invoiceNumber"');
      print('  - Runtime type: ${invoiceNumber.runtimeType}');
      print('  - Length: ${invoiceNumber.length} characters');
      if (invoiceNumber.isNotEmpty) {
        print('  - First character: "${invoiceNumber[0]}"');
        print('  - Last character: "${invoiceNumber[invoiceNumber.length - 1]}"');
        print('  - Contains only digits: ${RegExp(r'^\d+$').hasMatch(invoiceNumber)}');
        if (RegExp(r'^\d+$').hasMatch(invoiceNumber) && invoiceNumber.length > 1) {
          print('  - Leading zeros: ${invoiceNumber[0] == '0' ? 'YES' : 'NO'}');
        }
      }

      // 🔴 CRITICAL: Create invoice with ALL fields as proper types
      final invoice = <String, dynamic>{
        'invoiceDetailsID': invoiceId,
        'Invoice Number': invoiceNumber,  // This is a String, will preserve leading zeros
        'supplierID': _selectedSupplierId!,
        'Supplier': _supplierName.trim(),
        'Date of Purchase': _deliveryDate.toIso8601String(),
        'Delivery Date': _deliveryDate.toIso8601String(),
        'Total Cost Ex Vat': 0.0,  // This should remain a number
        'syncStatus': 'pending',
      };

      // Verify the invoice number is still a string with correct value
      print('✅ FINAL INVOICE DATA:');
      print('  - Invoice ID: ${invoice['invoiceDetailsID']}');
      print('  - Invoice Number: "${invoice['Invoice Number']}" (${invoice['Invoice Number'].runtimeType})');
      print('  - Supplier: ${invoice['Supplier']}');
      print('  - Supplier ID: ${invoice['supplierID']}');
      print('  - Date: ${invoice['Date of Purchase']}');

      print('DEBUG: Saving invoice details to storage...');
      await context.read<OfflineStorage>().saveInvoiceDetails(invoice);

      // Navigate to line items screen for manual entry
      final navigationResult = await Navigator.push(
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

      if (navigationResult == true && mounted) {
        // Return success to parent screen if needed
        Navigator.pop(context, true);
      }

      if (!_isDisposed && mounted) {
        _safeShowSnackBar('✓ Invoice saved - add line items manually');
      }
    } catch (e) {
      print('ERROR: Save invoice failed: $e');
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
        title: const Text('Manual GRV Entry'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildSupplierField(),
            TextFormField(
              controller: _invoiceNumberController,
              decoration: const InputDecoration(
                labelText: 'Invoice Number *',
                prefixIcon: Icon(Icons.description),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              keyboardType: TextInputType.text,  // 🔴 Use text, not number!
              // Don't use TextInputType.number as it might strip leading zeros
              onChanged: (v) => setState(() => _invoiceNumber = v),
            ),
            const SizedBox(height: 16),
            _buildDateField('Delivery Date *', _deliveryDate, (date) => setState(() => _deliveryDate = date)),
            const SizedBox(height: 24),

            // Manual Entry Only Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isLoading ? null : _saveInvoiceAndNavigate,
                icon: _isLoading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                    : const Icon(Icons.add),
                label: Text(_isLoading ? 'Creating...' : 'Create Invoice & Add Items'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.green,
                  disabledBackgroundColor: Colors.green.shade200,
                ),
              ),
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
        DropdownButtonFormField<String>(
          value: _selectedSupplierId,
          decoration: const InputDecoration(
            labelText: 'Select supplier',
            border: OutlineInputBorder(),
          ),
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
                final supplier = _suppliers.firstWhere(
                      (s) => s['supplierID']?.toString() == val,
                  orElse: () => <String, dynamic>{},
                );
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
}