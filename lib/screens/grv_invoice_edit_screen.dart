import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import '../models/grv_models.dart';
import 'grv_add_line_item_screen.dart';

class NumberParser {
  static double parse(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) {
      final cleanString = value.replaceAll(RegExp(r'[^\d.-]'), '');
      return double.tryParse(cleanString) ?? 0.0;
    }
    return 0.0;
  }
}

class GrvInvoiceEditScreen extends StatefulWidget {
  final Map<String, dynamic> invoice;
  final VoidCallback? onDeleted;
  final VoidCallback? onUpdated;

  const GrvInvoiceEditScreen({
    super.key,
    required this.invoice,
    this.onDeleted,
    this.onUpdated,
  });

  @override
  State<GrvInvoiceEditScreen> createState() => _GrvInvoiceEditScreenState();
}

class _GrvInvoiceEditScreenState extends State<GrvInvoiceEditScreen> {
  late TextEditingController _invoiceNumberController;
  late TextEditingController _grvController;  // 🔥 ADDED
  late DateTime _deliveryDate;
  late DateTime _purchaseDate;
  late String _supplierName;
  late String _supplierId;
  List<Map<String, dynamic>> _purchases = [];
  bool _isLoading = true;
  bool _isSaving = false;
  List<Map<String, dynamic>> _suppliers = [];
  bool _hasUnsavedChanges = false;

  // Enterprise: Pagination support for large datasets
  static const int _pageSize = 50;
  int _currentPage = 0;
  bool _hasMoreItems = true;
  bool _isLoadingMore = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initializeFromInvoice();
    _loadData();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _invoiceNumberController.removeListener(_onFieldChanged);
    _invoiceNumberController.dispose();
    _grvController.removeListener(_onFieldChanged);  // 🔥 ADDED
    _grvController.dispose();  // 🔥 ADDED
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _initializeFromInvoice() {
    _invoiceNumberController = TextEditingController(
      text: widget.invoice['Invoice Number']?.toString() ?? '',
    );
    _grvController = TextEditingController(  // 🔥 ADDED
      text: widget.invoice['GRV Reference']?.toString() ?? '',
    );
    _deliveryDate = _parseDate(widget.invoice['Delivery Date']);
    _purchaseDate = _parseDate(widget.invoice['Date of Purchase']);
    _supplierName = widget.invoice['Supplier Name']?.toString() ??
        widget.invoice['Supplier']?.toString() ?? '';
    _supplierId = widget.invoice['supplierID']?.toString() ?? '';

    _invoiceNumberController.addListener(_onFieldChanged);
    _grvController.addListener(_onFieldChanged);  // 🔥 ADDED
  }

  void _onFieldChanged() {
    if (!_hasUnsavedChanges) {
      setState(() {
        _hasUnsavedChanges = true;
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200 &&
        !_isLoadingMore &&
        _hasMoreItems) {
      _loadMorePurchases();
    }
  }

  DateTime _parseDate(dynamic dateStr) {
    if (dateStr == null) return DateTime.now();
    try {
      return DateTime.parse(dateStr.toString());
    } catch (e) {
      return DateTime.now();
    }
  }

  String _formatCurrency(dynamic value) {
    double numVal = 0.0;
    if (value is num) {
      numVal = value.toDouble();
    } else if (value is String) {
      final cleanString = value.replaceAll(RegExp(r'[^\d.-]'), '');
      numVal = double.tryParse(cleanString) ?? 0.0;
    }

    final isNegative = numVal < 0;
    final formatted = NumberFormat.currency(symbol: 'R', decimalDigits: 2).format(numVal.abs());
    return isNegative ? '-$formatted' : formatted;
  }

  Future<void> _loadData() async {
    final storage = context.read<OfflineStorage>();

    final results = await Future.wait([
      storage.getMasterSuppliers(),
      _loadPurchasesPaginated(storage, reset: true),
    ]);

    final suppliers = results[0];
    final purchases = results[1];

    if (mounted) {
      setState(() {
        _suppliers = suppliers;
        _purchases = purchases;
        _isLoading = false;
      });

      _validateSupplierAfterLoad();
    }
  }

  Future<List<Map<String, dynamic>>> _loadPurchasesPaginated(
      OfflineStorage storage, {
        bool reset = false,
      }) async {
    if (reset) {
      _currentPage = 0;
      _hasMoreItems = true;
      _isLoadingMore = false;
    }

    if (_isLoadingMore || !_hasMoreItems) return [];

    setState(() => _isLoadingMore = true);

    try {
      final invoiceId = widget.invoice['invoiceDetailsID']?.toString() ?? '';

      final purchases = await storage.getPurchasesByInvoiceIdPaginated(
        invoiceId,
        limit: _pageSize,
        offset: _currentPage * _pageSize,
        sortBy: 'Purchased Product Name',
        sortAscending: true,
      );

      if (mounted) {
        setState(() {
          if (reset) {
            _purchases = purchases;
          } else {
            _purchases.addAll(purchases);
          }
          _hasMoreItems = purchases.length == _pageSize;
          _currentPage++;
          _isLoadingMore = false;
        });
      }

      return purchases;
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading purchases: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return [];
    }
  }

  Future<void> _loadMorePurchases() async {
    if (_isLoadingMore || !_hasMoreItems) return;

    final storage = context.read<OfflineStorage>();
    await _loadPurchasesPaginated(storage);
  }

  Future<void> _refreshPurchases() async {
    final storage = context.read<OfflineStorage>();
    await _loadPurchasesPaginated(storage, reset: true);
  }

  void _validateSupplierAfterLoad() {
    if (_supplierId.isEmpty) return;

    final match = _suppliers.firstWhere(
          (s) => s['supplierID']?.toString() == _supplierId ||
          s['Supplier']?.toString().toLowerCase() == _supplierName.toLowerCase(),
      orElse: () => <String, dynamic>{},
    );

    if (match.isNotEmpty) {
      _supplierId = match['supplierID']?.toString() ?? _supplierId;
      _supplierName = match['Supplier']?.toString() ?? _supplierName;
    }
  }

  Future<void> _selectDate(BuildContext context, bool isDelivery) async {
    final initialDate = isDelivery ? _deliveryDate : _purchaseDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        if (isDelivery) {
          _deliveryDate = picked;
        } else {
          _purchaseDate = picked;
        }
        _hasUnsavedChanges = true;
      });
    }
  }

  Future<void> _addNewProduct() async {
    final result = await Navigator.push<GrvLineItemDisplay>(
      context,
      MaterialPageRoute(
        builder: (context) => GrvAddLineItemScreen(
          invoiceDetailsID: widget.invoice['invoiceDetailsID']?.toString() ?? '',
          supplierName: _supplierName,
          deliveryDate: _deliveryDate,
          grvReference: _grvController.text,  // 🔥 ADDED - PASS GRV
        ),
      ),
    );

    if (result != null && mounted) {
      final tempId = 'TEMP_${DateTime.now().millisecondsSinceEpoch}';

      final newPurchase = {
        'purchases_ID': tempId,
        'invoiceDetailsID': widget.invoice['invoiceDetailsID'],
        'GRV Reference': _grvController.text,  // 🔥 ADDED
        'Purchased Product Name': result.description,
        'Qty Purchased': result.quantityCases.toDouble(),
        'Cost Per Bottle': result.pricePerUnit,
        'Case/Pack Size': result.unitsPerCase,
        'Purchases Bottles': result.totalUnits.toDouble(),
        'Cost of Purchases': result.totalValue,
        'purSupplierBottleID': result.plu,
        'Barcode': result.barcode,
        '_edited': true,
        '_isNew': true,
      };

      setState(() {
        _insertPurchaseAlphabetically(newPurchase);
        _hasUnsavedChanges = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Product added - remember to save invoice'),
          backgroundColor: Colors.blue,
        ),
      );
    }
  }

  void _insertPurchaseAlphabetically(Map<String, dynamic> newPurchase) {
    final newName = newPurchase['Purchased Product Name']?.toString().toLowerCase() ?? '';

    int insertIndex = _binarySearchInsertPosition(newName);
    _purchases.insert(insertIndex, newPurchase);
  }

  int _binarySearchInsertPosition(String newName) {
    int low = 0;
    int high = _purchases.length;

    while (low < high) {
      final mid = (low + high) ~/ 2;
      final midName = _purchases[mid]['Purchased Product Name']?.toString().toLowerCase() ?? '';

      if (midName.compareTo(newName) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }

    return low;
  }

  Future<void> _editPurchaseItem(int index) async {
    final purchase = _purchases[index];

    final existingItem = GrvLineItemDisplay(
      plu: purchase['purSupplierBottleID']?.toString(),
      description: purchase['Purchased Product Name']?.toString() ?? '',
      quantityCases: NumberParser.parse(purchase['Qty Purchased']).toInt(),
      unitsPerCase: _extractPackSize(purchase['Case/Pack Size']),
      pricePerUnit: NumberParser.parse(purchase['Cost Per Bottle']),
      productName: purchase['Purchased Product Name']?.toString(),
      barcode: purchase['Barcode']?.toString(),
    );

    final result = await Navigator.push<GrvLineItemDisplay>(
      context,
      MaterialPageRoute(
        builder: (context) => GrvAddLineItemScreen(
          invoiceDetailsID: widget.invoice['invoiceDetailsID']?.toString() ?? '',
          supplierName: _supplierName,
          deliveryDate: _deliveryDate,
          grvReference: _grvController.text,  // 🔥 ADDED - PASS GRV
          initialItem: existingItem,
        ),
      ),
    );

    if (result != null && mounted) {
      final updatedPurchase = {
        ...purchase,
        'GRV Reference': _grvController.text,  // 🔥 ADDED
        'Purchased Product Name': result.description,
        'Qty Purchased': result.quantityCases.toDouble(),
        'Cost Per Bottle': result.pricePerUnit,
        'Case/Pack Size': result.unitsPerCase,
        'Purchases Bottles': result.totalUnits.toDouble(),
        'Cost of Purchases': result.totalValue,
        'purSupplierBottleID': result.plu,
        'Barcode': result.barcode,
        '_edited': true,
        '_isNew': purchase['_isNew'] == true ? true : null,
      };

      setState(() {
        _purchases.removeAt(index);
        _insertPurchaseAlphabetically(updatedPurchase);
        _hasUnsavedChanges = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Product updated - remember to save invoice'),
          backgroundColor: Colors.blue,
        ),
      );
    }
  }

  Future<void> _deletePurchaseItem(int index) async {
    final purchase = _purchases[index];

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Item'),
        content: Text('Delete ${purchase['Purchased Product Name']} from this invoice?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        final storage = context.read<OfflineStorage>();
        final purchaseId = purchase['purchases_ID']?.toString();

        if (purchaseId != null && !purchaseId.startsWith('TEMP_')) {
          storage.softDeletePurchase(purchaseId);
        }

        _purchases.removeAt(index);
        _hasUnsavedChanges = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Product removed'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _saveChanges() async {
    setState(() => _isSaving = true);

    try {
      final storage = context.read<OfflineStorage>();

      final newTotalCost = _calculateTotal();

      final updatedInvoice = Map<String, dynamic>.from(widget.invoice);
      updatedInvoice['Invoice Number'] = _invoiceNumberController.text;
      updatedInvoice['GRV Reference'] = _grvController.text;  // 🔥 ADDED
      updatedInvoice['Delivery Date'] = _deliveryDate.toIso8601String();
      updatedInvoice['Date of Purchase'] = _purchaseDate.toIso8601String();
      updatedInvoice['Supplier Name'] = _supplierName;
      updatedInvoice['supplierID'] = _supplierId;
      updatedInvoice['Total Cost Ex Vat'] = newTotalCost;
      updatedInvoice['syncStatus'] = 'pending';

      await storage.updateInvoiceDetails(updatedInvoice);

      final List<Future> updateFutures = [];

      for (var purchase in _purchases) {
        if (purchase['_edited'] == true) {
          final purchaseId = purchase['purchases_ID']?.toString();

          final packSize = _extractPackSize(purchase['Case/Pack Size']);
          final qtyCases = NumberParser.parse(purchase['Qty Purchased']);
          final costPerUnit = NumberParser.parse(purchase['Cost Per Bottle']);
          final lineTotal = purchase['Cost of Purchases'] != null &&
              NumberParser.parse(purchase['Cost of Purchases']) != 0.0
              ? NumberParser.parse(purchase['Cost of Purchases'])
              : (qtyCases * packSize * costPerUnit);

          final updateData = {
            'GRV Reference': _grvController.text,  // 🔥 ADDED
            'Qty Purchased': qtyCases,
            'Cost Per Bottle': costPerUnit,
            'Case/Pack Size': 'Case $packSize',
            'Purchases Bottles': (qtyCases * packSize),
            'Cost of Purchases': lineTotal,
          };

          if (purchase['_isNew'] == true) {
            updateData['Purchased Product Name'] = purchase['Purchased Product Name'];
            updateData['purSupplierBottleID'] = purchase['purSupplierBottleID'];
            updateData['Barcode'] = purchase['Barcode'];
          }

          if (purchaseId != null && !purchaseId.startsWith('TEMP_')) {
            updateFutures.add(storage.updatePurchaseItem(purchaseId, updateData));
          } else if (purchase['_isNew'] == true) {
            updateFutures.add(storage.savePurchase({
              ...purchase,
              ...updateData,
              'invoiceDetailsID': widget.invoice['invoiceDetailsID'],
              'supplierID': _supplierId,
              'Supplier': _supplierName,
              'Stock Delivery Date': _deliveryDate.toIso8601String(),
              'syncStatus': 'pending',
            }));
          }
        }
      }

      if (updateFutures.isNotEmpty) {
        await Future.wait(updateFutures);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invoice updated'), backgroundColor: Colors.green),
        );
        widget.onUpdated?.call();
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isSaving = false);
    }
  }

  Future<void> _deleteInvoice() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Invoice'),
        content: const Text('Delete this invoice and all its items? This will sync deletion to the server.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isSaving = true);

      try {
        final storage = context.read<OfflineStorage>();
        final invoiceId = widget.invoice['invoiceDetailsID']?.toString() ?? '';

        await storage.softDeleteInvoice(invoiceId);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invoice deleted'), backgroundColor: Colors.green),
          );
          widget.onDeleted?.call();
          Navigator.pop(context, true);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      } finally {
        setState(() => _isSaving = false);
      }
    }
  }

  int _extractPackSize(dynamic packSizeVal) {
    if (packSizeVal == null) return 1;
    if (packSizeVal is int) return packSizeVal > 0 ? packSizeVal : 1;
    if (packSizeVal is num) return packSizeVal > 0 ? packSizeVal.toInt() : 1;
    final str = packSizeVal.toString();
    final match = RegExp(r'\d+').firstMatch(str);
    if (match != null) {
      final parsed = int.tryParse(match.group(0) ?? '1') ?? 1;
      return parsed > 0 ? parsed : 1;
    }
    return 1;
  }

  double _calculateLineTotal(Map<String, dynamic> purchase) {
    final qtyCases = NumberParser.parse(purchase['Qty Purchased']);
    final costPerUnit = NumberParser.parse(purchase['Cost Per Bottle']);
    final packSize = _extractPackSize(purchase['Case/Pack Size']);

    final total = qtyCases.abs() * packSize * costPerUnit;
    return qtyCases < 0 ? -total : total;
  }

  double _calculateTotal() {
    double total = 0.0;
    for (var purchase in _purchases) {
      total += _calculateLineTotal(purchase);
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final grandTotal = _calculateTotal();
    final isCreditNote = grandTotal < 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('Edit Invoice: ${widget.invoice['Invoice Number'] ?? ''}'),
        actions: [
          if (_hasUnsavedChanges)
            const Padding(
              padding: EdgeInsets.only(right: 8.0),
              child: Icon(Icons.circle, color: Colors.orange, size: 12),
            ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: _deleteInvoice,
          ),
          IconButton(
            icon: _isSaving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            onPressed: _isSaving ? null : _saveChanges,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _refreshPurchases,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Invoice Details Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: _suppliers.any((s) => s['supplierID']?.toString() == _supplierId)
                            ? _supplierId
                            : null,
                        decoration: InputDecoration(
                          labelText: 'Supplier',
                          hintText: _supplierName.isNotEmpty ? _supplierName : 'Select Supplier',
                          border: const OutlineInputBorder(),
                        ),
                        items: _suppliers.map((s) {
                          return DropdownMenuItem(
                            value: s['supplierID']?.toString(),
                            child: Text(s['Supplier']?.toString() ?? ''),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            final supplier = _suppliers.firstWhere(
                                  (s) => s['supplierID']?.toString() == val,
                            );
                            setState(() {
                              _supplierId = val;
                              _supplierName = supplier['Supplier']?.toString() ?? '';
                              _hasUnsavedChanges = true;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),

                      // 🔥 ADDED: GRV Reference Field
                      TextFormField(
                        controller: _grvController,
                        decoration: const InputDecoration(
                          labelText: 'GRV Reference',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => _onFieldChanged(),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _invoiceNumberController,
                        decoration: const InputDecoration(
                          labelText: 'Invoice Number',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => _onFieldChanged(),
                      ),
                      const SizedBox(height: 16),
                      ListTile(
                        leading: const Icon(Icons.calendar_today),
                        title: const Text('Delivery Date'),
                        subtitle: Text(DateFormat('dd MMM yyyy').format(_deliveryDate)),
                        onTap: () => _selectDate(context, true),
                      ),
                      ListTile(
                        leading: const Icon(Icons.receipt),
                        title: const Text('Purchase Date'),
                        subtitle: Text(DateFormat('dd MMM yyyy').format(_purchaseDate)),
                        onTap: () => _selectDate(context, false),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Items Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Items (${_purchases.length})',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      if (_hasMoreItems && _purchases.length >= _pageSize)
                        Text(
                          'Showing ${_purchases.length}+ items',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                    ],
                  ),
                  Text(
                    'Total: ${_formatCurrency(grandTotal)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: isCreditNote ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Items List or Empty State
              _purchases.isEmpty
                  ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    children: [
                      Icon(
                        Icons.inbox,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No items on this invoice',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap the + button to add your first product',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                ),
              )
                  : Column(
                children: [
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _purchases.length + (_hasMoreItems ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _purchases.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16.0),
                          child: Center(
                            child: _isLoadingMore
                                ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                                : const SizedBox.shrink(),
                          ),
                        );
                      }

                      final purchase = _purchases[index];
                      final qtyCases = NumberParser.parse(purchase['Qty Purchased']);
                      final pricePerUnit = NumberParser.parse(purchase['Cost Per Bottle']);
                      final packSize = _extractPackSize(purchase['Case/Pack Size']);
                      final lineTotal = _calculateLineTotal(purchase);
                      final isNew = purchase['_isNew'] == true;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  purchase['Purchased Product Name'] ?? '',
                                  style: TextStyle(
                                    fontWeight: isNew ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (isNew)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.blue,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text(
                                    'NEW',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${qtyCases.toStringAsFixed(2)} cases ($packSize pk) @ R${pricePerUnit.toStringAsFixed(2)}/unit'),
                              if (purchase['_edited'] == true)
                                const Text(
                                  '* Unsaved changes',
                                  style: TextStyle(color: Colors.orange, fontSize: 10),
                                ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _formatCurrency(lineTotal),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: lineTotal < 0 ? Colors.green : Colors.red,
                                ),
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                icon: const Icon(Icons.edit, size: 20, color: Colors.blue),
                                onPressed: () => _editPurchaseItem(index),
                                tooltip: 'Edit item',
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                                onPressed: () => _deletePurchaseItem(index),
                                tooltip: 'Delete item',
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  if (_isLoadingMore && _purchases.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addNewProduct,
        icon: const Icon(Icons.add),
        label: const Text('Add Product'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}