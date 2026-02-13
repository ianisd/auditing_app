import 'dart:io';
import 'dart:math' as math;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/offline_storage.dart';
import '../services/grv_parser.dart';
import 'grv_add_line_item_screen.dart';
import 'grv_csv_upload_screen.dart';

class GrvLineItemDisplay {
  final String? plu;
  final String description;
  final int quantityCases;
  final int unitsPerCase;
  final double pricePerUnit;

  String? productName;
  String? barcode;
  final double costPerCase;

  GrvLineItemDisplay({
    this.plu,
    required this.description,
    required this.quantityCases,
    required this.unitsPerCase,
    required this.pricePerUnit,
    this.productName,
    this.barcode,
  }) : costPerCase = pricePerUnit * unitsPerCase;

  int get totalUnits => quantityCases * unitsPerCase;
  double get totalValue => costPerCase;
  bool get isMatched => productName != null;
}

class GrvLineItemsScreen extends StatefulWidget {
  final String invoiceDetailsID;
  final String supplierName;
  final DateTime deliveryDate;
  final List<ParsedGrvLineItem>? preloadedItems;

  const GrvLineItemsScreen({
    super.key,
    required this.invoiceDetailsID,
    required this.supplierName,
    required this.deliveryDate,
    this.preloadedItems,
  });

  @override
  State<GrvLineItemsScreen> createState() => _GrvLineItemsScreenState();
}

class _GrvLineItemsScreenState extends State<GrvLineItemsScreen> {
  final List<GrvLineItemDisplay> _items = [];
  bool _isMatching = false;
  bool _isLoading = false;
  double _totalValue = 0.0;
  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.preloadedItems != null) {
      _autoMatchPluItems(widget.preloadedItems!);
    }
  }

  Future<void> _autoMatchPluItems(List<ParsedGrvLineItem> items) async {
    if (_isDisposed || !mounted) return;
    setState(() => _isMatching = true);

    final storage = context.read<OfflineStorage>();
    final matchedItems = <GrvLineItemDisplay>[];

    // Show progress for large files
    if (items.length > 20 && !_isDisposed && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Matching Products...'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Processing ${items.length} items...'),
            ],
          ),
        ),
      );
    }

    int matchedCount = 0;
    for (var i = 0; i < items.length; i++) {
      if (_isDisposed || !mounted) return;

      final item = items[i];
      Map<String, dynamic>? product;
      double? costOverride;

      // Try PLU matching first
      if (item.plu.isNotEmpty) {
        product = await storage.findProductByPlu(item.plu);

        if (product != null) {
          final allSuppliers = await storage.getMasterSuppliers();
          final supplier = allSuppliers.firstWhere(
                (s) => s['Supplier']?.toString() == widget.supplierName,
            orElse: () => <String, dynamic>{},
          );

          if (supplier.isNotEmpty) {
            final supplierID = supplier['supplierID']?.toString();
            if (supplierID != null) {
              costOverride = await storage.getCostBySupplierAndBottleId(
                supplierID,
                item.plu,
              );
            }
          }
        }
      }

      // Fallback: description match
      if (product == null && item.description.isNotEmpty) {
        final allInventory = await storage.getAllInventory();
        product = allInventory.firstWhere(
              (inv) =>
          inv['Inventory Product Name']
              ?.toString()
              .toLowerCase()
              .contains(item.description.toLowerCase()) ?? false,
          orElse: () => <String, dynamic>{},
        );
        if (product!.isEmpty) product = null;
      }

      matchedItems.add(GrvLineItemDisplay(
        plu: item.plu,
        description: item.description,
        quantityCases: item.quantityCases,
        unitsPerCase: item.unitsPerCase,
        pricePerUnit: costOverride ?? item.pricePerUnit,
        productName: product?['Inventory Product Name'],
        barcode: product?['Barcode'],
      ));

      if (product != null) matchedCount++;

      if (i % 10 == 0 && items.length > 20) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    if (_isDisposed || !mounted) return;
    if (items.length > 20) Navigator.pop(context);

    setState(() {
      _items.clear();
      _items.addAll(matchedItems);
      _calculateTotal();
      _isMatching = false;

      if (items.length > 20) {
        _safeShowSnackBar('✓ Matched $matchedCount/${items.length} items');
      }
    });
  }

  void _calculateTotal() {
    _totalValue = _items.fold(0.0, (sum, item) => sum + item.totalValue);
  }

  void _safeShowSnackBar(String message, {Color backgroundColor = Colors.blue}) {
    if (_isDisposed || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  Future<void> _uploadCsv() async {
    if (_isDisposed || !mounted) return;
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
      if (filePath == null) throw Exception('File path is null');

      final file = File(filePath);
      final content = await file.readAsString();

      if (content.length > 5 * 1024 * 1024) {
        throw Exception('File too large (>5MB). Please split into smaller GRVs.');
      }

      final parser = GrvParser();
      final grvData = parser.parse(content);

      if (grvData.lineItems.isEmpty) {
        _safeShowSnackBar('⚠️ No line items found in CSV');
        return;
      }

      await _autoMatchPluItems(grvData.lineItems);
      _safeShowSnackBar('✓ Parsed ${grvData.lineItems.length} items');
    } catch (e) {
      _safeShowSnackBar('Error: ${e.toString().split('\n').first}', backgroundColor: Colors.red);
    } finally {
      if (!_isDisposed && mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveAllItems() async {
    if (_isDisposed || !mounted) return;

    if (_items.isEmpty) {
      _safeShowSnackBar('⚠️ No items to save');
      return;
    }

    final unmappedCount = _items.where((i) => !i.isMatched).length;
    if (unmappedCount > 0) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Unmapped Items'),
          content: Text('$unmappedCount item(s) not linked to inventory.\n\nSave mapped items only?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save Mapped Items'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    setState(() => _isLoading = true);

    try {
      final storage = context.read<OfflineStorage>();
      final invoice = await storage.getInvoiceDetails(widget.invoiceDetailsID);
      if (invoice == null) throw Exception('Invoice details not found');

      int savedCount = 0;
      const batchSize = 20;

      for (var i = 0; i < _items.length; i += batchSize) {
        if (_isDisposed || !mounted) return;

        final batch = _items.skip(i).take(batchSize).where((item) => item.isMatched).toList();

        for (var item in batch) {
          final purchase = {
            'purchases_ID': DateTime.now().millisecondsSinceEpoch.toString(),
            'invoiceDetailsID': widget.invoiceDetailsID,
            'supplierID': invoice['supplierID'] ?? '',
            'Supplier': widget.supplierName,
            'Barcode': item.barcode ?? '',
            'Purchased Product Name': item.productName!,
            'purSupplierBottleID': item.plu ?? '',
            'Cost Per Bottle': item.pricePerUnit,
            'Stock Delivery Date': widget.deliveryDate.toIso8601String(),
            'Case/Pack Size': 'Case ${item.unitsPerCase}',
            'Qty Purchased': item.quantityCases.toDouble(),
            'Purchases Bottles': item.totalUnits.toDouble(),
            'Cost of Purchases': item.totalValue,
            'syncStatus': 'pending',
          };
          await storage.savePurchase(purchase);
          savedCount++;
        }

        if (i + batchSize < _items.length) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }

      await storage.saveInvoiceDetails({...invoice, 'Total Cost Ex Vat': _totalValue});

      if (!_isDisposed && mounted) {
        Navigator.pop(context);
        _safeShowSnackBar('✓ Saved $savedCount items to Purchases');
      }
    } catch (e) {
      _safeShowSnackBar('Save failed: ${e.toString().split('\n').first}', backgroundColor: Colors.red);
    } finally {
      if (!_isDisposed && mounted) setState(() => _isLoading = false);
    }
  }

  void _startManualEntry() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GrvAddLineItemScreen(
          invoiceDetailsID: widget.invoiceDetailsID,
          supplierName: widget.supplierName,
          deliveryDate: widget.deliveryDate,
        ),
      ),
    );

    if (result is GrvLineItemDisplay) {
      setState(() {
        _items.add(result);
        _calculateTotal();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added: ${result.description}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: const Text('GRV: Line Items')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // === HEADER CARD ===
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${_items.length} items', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('R${_totalValue.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.green)),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ✅ PRIMARY BUTTON: "ADD ITEM" (like Count Screen)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _startManualEntry,
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('ADD ITEM', style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // ✅ SECONDARY BUTTON: "Upload GRV CSV"
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => GrvCsvUploadScreen(
                    invoiceDetailsID: widget.invoiceDetailsID,
                    supplierName: widget.supplierName,
                    deliveryDate: widget.deliveryDate,
                  ),
                ),
              ),
              icon: const Icon(Icons.upload_file),
              label: const Text('Upload GRV CSV'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.grey[300]!),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),

            const SizedBox(height: 24),

            // === ITEMS LIST ===
            _items.isEmpty
                ? Center(
              child: Column(
                children: [
                  Icon(Icons.inventory_2, size: 48, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text('No items added yet', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Text('Upload a GRV CSV or add items manually', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            )
                : ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: item.isMatched ? Colors.green.shade100 : Colors.red.shade100,
                      child: Text(
                        item.plu?.substring(0, math.min(2, item.plu?.length ?? 0)) ?? '?',
                        style: TextStyle(
                          color: item.isMatched ? Colors.green.shade900 : Colors.red.shade900,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(item.description),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${item.quantityCases} × ${item.unitsPerCase} @ R${item.pricePerUnit.toStringAsFixed(2)}/unit'),
                        if (!item.isMatched) Text('⚠️ Unmatched', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                    trailing: Text('R${item.totalValue.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                );
              },
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saveAllItems,
        icon: const Icon(Icons.save),
        label: Text(
          _items.isEmpty
              ? 'SAVE 0 ITEMS'
              : 'SAVE ${_items.length} ITEMS',
          style: const TextStyle(fontSize: 16),
        ),
        backgroundColor: _items.isEmpty ? Colors.grey : Colors.green,
      ),
    );
  }
}