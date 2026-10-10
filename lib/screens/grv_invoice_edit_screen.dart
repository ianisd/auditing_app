import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import '../services/store_manager.dart';
import '../models/grv_models.dart';
import 'grv_add_line_item_screen.dart';
import '../utils/safe_date_utils.dart';

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
  late TextEditingController _grvController;
  late DateTime _deliveryDate;
  late DateTime _purchaseDate;
  late String _supplierName;
  late String _supplierId;
  List<Map<String, dynamic>> _purchases = [];
  bool _isLoading = true;
  bool _isSaving = false;
  List<Map<String, dynamic>> _suppliers = [];
  bool _hasUnsavedChanges = false;
  // Existing purchase rows removed in the editor are staged here only.
  // Hive/Firestore are not changed until Save is pressed.
  final List<Map<String, dynamic>> _stagedDeletedPurchases = [];

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
    _grvController.removeListener(_onFieldChanged);
    _grvController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  // 🔥 FIX: Add the missing _initializeFromInvoice method
  void _initializeFromInvoice() {
    _invoiceNumberController = TextEditingController(
      text: widget.invoice['Invoice Number']?.toString() ?? '',
    );
    // 🔥 FIX: GRV Reference must never be null/empty downstream
    final grvValue = widget.invoice['GRV Reference']?.toString();
    _grvController = TextEditingController(
      text: (grvValue != null && grvValue.trim().isNotEmpty) ? grvValue : 'NO_GRV',
    );
    _deliveryDate = _parseDate(widget.invoice['Delivery Date']);
    _purchaseDate = _parseDate(widget.invoice['Date of Purchase']);
    _supplierName = widget.invoice['Supplier Name']?.toString() ??
        widget.invoice['Supplier']?.toString() ?? '';
    _supplierId = widget.invoice['supplierID']?.toString() ?? '';

    _invoiceNumberController.addListener(_onFieldChanged);
    _grvController.addListener(_onFieldChanged);
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

  DateTime _parseDate(dynamic value) {
    final parsed = SafeDateUtils.parseDate(value);

    // GRV dates must also be valid for this screen's date picker.
    // Invalid / legacy-corrupted values (for example 1946) fall back to today
    // rather than being passed to showDatePicker outside its allowed range.
    if (parsed == null || parsed.year < 2000 || parsed.year > 2100) {
      return DateTime.now();
    }

    return DateTime(parsed.year, parsed.month, parsed.day);
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

      // 🔥 FIX: Sanitize stale UI flags persisted by older builds.
      // Anything already 'synced' is by definition NOT new/edited.
      // This repairs the stuck "NEW / * Unsaved changes" records in Hive
      // (in-memory only — no extra writes, no re-sync triggered).
      for (final p in purchases) {
        if (p['syncStatus'] == 'synced') {
          p['_edited'] = false;
          p['_isNew'] = false;
        }
      }

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
    final firstDate = DateTime(2000);
    final lastDate = DateTime(2100);
    final storedDate = isDelivery ? _deliveryDate : _purchaseDate;
    final today = DateTime.now();
    final fallbackDate = DateTime(today.year, today.month, today.day);
    final initialDate = storedDate.isBefore(firstDate) || storedDate.isAfter(lastDate)
        ? fallbackDate
        : storedDate;

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
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

  // 🔥 FIX: Only ONE _addNewProduct method (remove the duplicate)
  Future<void> _addNewProduct() async {
    // 🔥 FIX: never pass an empty GRV down
    final grvRef = _grvController.text.trim().isNotEmpty
        ? _grvController.text.trim()
        : 'NO_GRV';

    final result = await Navigator.push<GrvLineItemDisplay>(
      context,
      MaterialPageRoute(
        builder: (context) => GrvAddLineItemScreen(
          invoiceDetailsID: widget.invoice['invoiceDetailsID']?.toString() ?? '',
          supplierName: _supplierName,
          deliveryDate: _deliveryDate,
          grvReference: grvRef,
        ),
      ),
    );

    if (result != null && mounted) {
      final tempId = 'TEMP_${DateTime.now().millisecondsSinceEpoch}';

      final newPurchase = {
        'purchases_ID': tempId,
        'invoiceDetailsID': widget.invoice['invoiceDetailsID'],
        'GRV Reference': grvRef,
        'Purchased Product Name': result.description,
        // 🔥 FIX: carry full metadata so Purchases rows aren't missing
        // Main Category / Category / Single Unit Volume / UoM on the sheet
        'Main Category': result.mainCategory,
        'Category': result.category,
        'Single Unit Volume': result.singleUnitVolume,
        'UoM': result.uom,
        'Qty Purchased': result.quantityCases.toDouble(),
        'Cost Per Bottle': result.pricePerUnit,
        'Case/Pack Size': 'Case ${result.unitsPerCase}',
        'Purchases Bottles': result.totalUnits.toDouble(),
        'Cost of Purchases': result.totalValue,
        'purSupplierBottleID': result.plu,
        'supplierBottleID': result.supplierBottleID, // 🔥 carry supplierBottleID
        'Barcode': result.barcode,
        // In-memory only; _saveChanges now strips these before persisting.
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
      // 🔥 FIX: preserve metadata through the edit round-trip
      mainCategory: purchase['Main Category']?.toString(),
      category: purchase['Category']?.toString(),
      singleUnitVolume: NumberParser.parse(purchase['Single Unit Volume']),
      uom: purchase['UoM']?.toString(),
    );

    final grvRef = _grvController.text.trim().isNotEmpty
        ? _grvController.text.trim()
        : 'NO_GRV';

    final result = await Navigator.push<GrvLineItemDisplay>(
      context,
      MaterialPageRoute(
        builder: (context) => GrvAddLineItemScreen(
          invoiceDetailsID: widget.invoice['invoiceDetailsID']?.toString() ?? '',
          supplierName: _supplierName,
          deliveryDate: _deliveryDate,
          grvReference: grvRef,
          initialItem: existingItem,
        ),
      ),
    );

    if (result != null && mounted) {
      final updatedPurchase = {
        ...purchase,
        'GRV Reference': grvRef,
        'Purchased Product Name': result.description,
        'Main Category': result.mainCategory,
        'Category': result.category,
        'Single Unit Volume': result.singleUnitVolume,
        'UoM': result.uom,
        'Qty Purchased': result.quantityCases.toDouble(),
        'Cost Per Bottle': result.pricePerUnit,
        'Case/Pack Size': 'Case ${result.unitsPerCase}',
        'Purchases Bottles': result.totalUnits.toDouble(),
        'Cost of Purchases': result.totalValue,
        'purSupplierBottleID': result.plu,
        'supplierBottleID': result.supplierBottleID, // 🔥 carry supplierBottleID
        'Barcode': result.barcode,
        '_edited': true,
        // 🔥 FIX: keep a real boolean (old code wrote `null` here)
        '_isNew': purchase['_isNew'] == true,
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
    final isLastRemainingLine = _purchases.length == 1;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Item'),
        content: Text(
          isLastRemainingLine
              ? 'Remove the last item from this GRV? The GRV will stay open so '
              'you can add another item. If you press Save while it is empty, '
              'the GRV will be deleted.'
              : 'Remove ${purchase['Purchased Product Name']} from this invoice?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    // TEMP_ rows exist only in this editor, so removing them needs no tombstone.
    // Existing rows are staged and become Hive tombstones only when Save is
    // pressed. Back therefore discards the removal like any other unsaved edit.
    final purchaseId = purchase['purchases_ID']?.toString() ?? '';
    final isUnsavedNewRow =
        purchase['_isNew'] == true || purchaseId.startsWith('TEMP_');

    setState(() {
      if (!isUnsavedNewRow) {
        _stagedDeletedPurchases.add(Map<String, dynamic>.from(purchase));
      }
      _purchases.removeAt(index);
      _hasUnsavedChanges = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _purchases.isEmpty
              ? 'Last item removed - add another item or Save to delete the GRV'
              : 'Product removed - press Save to confirm',
        ),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Future<void> _saveChanges() async {
    setState(() => _isSaving = true);

    try {
      final storage = context.read<OfflineStorage>();
      final invoiceId = widget.invoice['invoiceDetailsID']?.toString() ?? '';

      // An empty existing GRV is deleted only when the user explicitly presses
      // Save. Until then they may add a replacement line or press Back to
      // discard the staged deletion.
      if (_purchases.isEmpty) {
        if (invoiceId.isEmpty) {
          throw StateError('Cannot delete empty GRV: invoice ID is missing');
        }
        await storage.softDeleteInvoice(
          invoiceId,
          deletionReason: 'last_line_deleted_on_save',
        );
        if (mounted) {
          unawaited(
            context
                .read<StoreManager>()
                .syncService
                .syncInvoiceDeletionInBackground(invoiceId),
          );
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Empty GRV deleted'),
              backgroundColor: Colors.orange,
            ),
          );
          widget.onDeleted?.call();
          Navigator.pop(context, true);
        }
        return;
      }

      // Commit staged line removals to Hive only now. This makes Back a true
      // cancel for unsaved line deletions.
      for (final deletedPurchase in _stagedDeletedPurchases) {
        final purchaseId = deletedPurchase['purchases_ID']?.toString() ?? '';
        if (purchaseId.isNotEmpty) {
          await storage.softDeletePurchase(purchaseId);
        }
      }

      final newTotalCost = _calculateTotal();
      final grvRef = _grvController.text.trim().isNotEmpty
          ? _grvController.text.trim()
          : 'NO_GRV';

      final updatedInvoice = Map<String, dynamic>.from(widget.invoice);
      updatedInvoice['Invoice Number'] = _invoiceNumberController.text;
      updatedInvoice['GRV Reference'] = grvRef;
      updatedInvoice['Delivery Date'] = _deliveryDate.toIso8601String();
      updatedInvoice['Date of Purchase'] = _purchaseDate.toIso8601String();
      updatedInvoice['Supplier Name'] = _supplierName;
      updatedInvoice['supplierID'] = _supplierId;
      updatedInvoice['Total Cost Ex Vat'] = newTotalCost;
      updatedInvoice['syncStatus'] = 'pending';

      await storage.updateInvoiceDetails(updatedInvoice);

      // Canonical Purchase IDs are assigned by OfflineStorage.

      final List<Future> updateFutures = [];

      for (int i = 0; i < _purchases.length; i++) {
        var purchase = _purchases[i];
        if (purchase['_edited'] != true) continue;

        final purchaseId = purchase['purchases_ID']?.toString();
        final packSize = _extractPackSize(purchase['Case/Pack Size']);
        final qtyCases = NumberParser.parse(purchase['Qty Purchased']);
        final costPerUnit = NumberParser.parse(purchase['Cost Per Bottle']);
        final lineTotal = purchase['Cost of Purchases'] != null &&
            NumberParser.parse(purchase['Cost of Purchases']) != 0.0
            ? NumberParser.parse(purchase['Cost of Purchases'])
            : (qtyCases * packSize * costPerUnit);

        final Map<String, dynamic> updateData = {
          'GRV Reference': grvRef,
          'Invoice Nr.': _invoiceNumberController.text, // 🔥 Align with upload
          'Inv. Date of Purchase': _purchaseDate.toIso8601String(), // 🔥 Align with upload
          'Qty Purchased': qtyCases,
          'Cost Per Bottle': costPerUnit,
          'Case/Pack Size': 'Case $packSize',
          'Purchases Bottles': (qtyCases * packSize),
          'Purchase Units': 0, // 🔥 Align with upload
          'Cost of Purchases': lineTotal,
        };

        final bool isNew = purchase['_isNew'] == true;

        if (isNew) {
          updateData['Purchased Product Name'] = purchase['Purchased Product Name'];
          updateData['purSupplierBottleID'] =
              purchase['supplierBottleID'] ?? purchase['purSupplierBottleID'];
          updateData['supplierBottleID'] =
              purchase['supplierBottleID'] ?? purchase['purSupplierBottleID'];
          updateData['plu'] = purchase['purSupplierBottleID'];
          updateData['Barcode'] = purchase['Barcode'];
          updateData['Main Category'] = purchase['Main Category'];
          updateData['Category'] = purchase['Category'];
          updateData['Single Unit Volume'] = purchase['Single Unit Volume'];
          updateData['UoM'] = purchase['UoM'];

          final Map<String, dynamic> cleanPayload = {
            ...purchase,
            ...updateData,
            'invoiceDetailsID': widget.invoice['invoiceDetailsID'],
            'supplierID': _supplierId,
            'Supplier': _supplierName,
            'Stock Delivery Date': _deliveryDate.toIso8601String(),
            'syncStatus': 'pending',
            '_edited': false,
            '_isNew': false,
          };
          // TEMP_/screen IDs are not canonical. Force OfflineStorage to assign
          // the canonical ID and return it to this in-memory row.
          cleanPayload.remove('purchases_ID');
          cleanPayload.removeWhere(
                (k, _) => k.startsWith('_') && k != '_edited' && k != '_isNew',
          );

          final canonicalId = await storage.savePurchase(cleanPayload);
          if (canonicalId == null || canonicalId.isEmpty) {
            throw StateError('Failed to assign canonical Purchase ID');
          }
          purchase['purchases_ID'] = canonicalId;
        } else if (purchaseId != null && purchaseId.isNotEmpty) {
          updateFutures.add(storage.updatePurchaseItem(purchaseId, updateData));
        }

        // Keep the in-memory list consistent for the rest of this session.
        purchase.addAll(updateData);
        purchase['_edited'] = false;
        purchase['_isNew'] = false;
      }

      if (updateFutures.isNotEmpty) {
        await Future.wait(updateFutures);
      }

      if (mounted && invoiceId.isNotEmpty) {
        unawaited(
          context
              .read<StoreManager>()
              .syncService
              .syncInvoiceWithPurchasesInBackground(invoiceId),
        );
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

        await storage.softDeleteInvoice(
          invoiceId,
          deletionReason: 'user_deleted_invoice',
        );
        if (mounted && invoiceId.isNotEmpty) {
          unawaited(
            context
                .read<StoreManager>()
                .syncService
                .syncInvoiceDeletionInBackground(invoiceId),
          );
        }

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
  @override
  Widget build(BuildContext context) {
    final grandTotal = _calculateTotal();
    final isCreditNote = grandTotal < 0;

    // Responsive layout:
    // Mobile (< 700px): compact Delete/Save in AppBar and full-width
    // Add Product button below the Items / Total row.
    // Desktop/tablet (>= 700px): retain the original AppBar toolbar.
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    return Scaffold(
      appBar: AppBar(
        title: Text('Edit Invoice: ${widget.invoice['Invoice Number'] ?? ''}'),
        actions: [
          if (_hasUnsavedChanges)
            const Padding(
              padding: EdgeInsets.only(right: 8.0),
              child: Icon(Icons.circle, color: Colors.orange, size: 12),
            ),

          if (isMobile) ...[
            // MOBILE: compact document actions so nothing is cut off.
            IconButton(
              onPressed: _isSaving ? null : _deleteInvoice,
              icon: const Icon(Icons.delete_outline),
              color: Colors.red,
              tooltip: 'Delete GRV/Credit Note',
            ),
            IconButton(
              onPressed: _isSaving ? null : _saveChanges,
              icon: _isSaving
                  ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : const Icon(Icons.save),
              color: Colors.green,
              tooltip: 'Save GRV/Credit Note',
            ),
            const SizedBox(width: 4),
          ] else ...[
            // DESKTOP/TABLET: preserve the original toolbar.
            ElevatedButton.icon(
              onPressed: _addNewProduct,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Product'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _deleteInvoice,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete GRV/Credit Note'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _saveChanges,
              icon: _isSaving
                  ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
                  : const Icon(Icons.save, size: 18),
              label: const Text('Save GRV/Credit Note'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
          ],
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _refreshPurchases,
        child: SingleChildScrollView(
          controller: _scrollController,
          // 🔥 Extra bottom padding so the last card's edit/delete
          // buttons are never clipped or covered.
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
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

                      // GRV Reference Field
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

              // MOBILE ONLY: full-width Add Product directly below Items / Total.
              if (isMobile) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _addNewProduct,
                    icon: const Icon(Icons.add),
                    label: const Text(
                      'Add Product',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],

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
                        'Use "Add Product" in the top bar to add your first product',
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
                      final isNew = _isNewItem(purchase);

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
                              if (_isUnsaved(purchase))
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
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
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
      // 🔥 FAB REMOVED — it was covering the last item's edit/delete buttons.
    );
  }

  // 🔥 NEW helpers — single source of truth for the UI badges.
// UI state is now DERIVED from syncStatus, not from persisted flags alone.
  bool _isUnsaved(Map<String, dynamic> purchase) =>
      purchase['_edited'] == true || purchase['syncStatus'] == 'pending';

  bool _isNewItem(Map<String, dynamic> purchase) =>
      purchase['_isNew'] == true ||
          ((purchase['purchases_ID']?.toString().startsWith('TEMP_') ?? false) &&
              purchase['syncStatus'] == 'pending');

}