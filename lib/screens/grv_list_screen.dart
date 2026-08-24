import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import '../services/store_manager.dart';
import 'grv_invoice_edit_screen.dart';
import 'grv_invoice_screen.dart';

// Constants for better maintainability
class InvoiceStatus {
  static const String pending = 'pending';
  static const String synced = 'synced';
  static const String all = 'All';
  static const String pendingLabel = 'Pending';
  static const String syncedLabel = 'Synced';
}

class SortBy {
  static const String deliveryDate = 'deliveryDate';
  static const String supplier = 'supplier';
  static const String total = 'total';
}

class DateFilter {
  static const String all = 'All';
  static const String today = 'Today';
  static const String thisWeek = 'This Week';
  static const String thisMonth = 'This Month';
  static const String custom = 'Custom';
}

// Search mode for invoice vs product search
enum SearchMode { invoice, product }

class GrvListScreen extends StatefulWidget {
  const GrvListScreen({super.key});

  @override
  State<GrvListScreen> createState() => _GrvListScreenState();
}

class _GrvListScreenState extends State<GrvListScreen> {
  // Data State
  List<Map<String, dynamic>> _invoices = [];
  final Map<String, List<Map<String, dynamic>>> _expandedPurchasesCache = {};
  bool _isLoading = true;
  double? _cachedTotalValueSum;
  List<Map<String, dynamic>>? _cachedFilteredInvoices;
  Timer? _debounceTimer;

  // Search & Filters
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  SearchMode _searchMode = SearchMode.invoice;

  String _statusFilter = InvoiceStatus.all;
  String _dateFilter = DateFilter.all;
  DateTimeRange? _customDateRange;

  String _sortBy = SortBy.deliveryDate;
  bool _sortAscending = false;

  // UI State
  final Set<String> _expandedInvoices = {};
  final Set<String> _loadingInvoiceIds = {};
  bool _areAllExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadInvoices();
    // Using debounced search
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text.toLowerCase().trim();
          _cachedFilteredInvoices = null;
          _cachedTotalValueSum = null;
        });
      }
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _cachedFilteredInvoices = null;
      _cachedTotalValueSum = null;
    });
    FocusScope.of(context).unfocus();
  }

  void _toggleSearchMode() {
    setState(() {
      _searchMode = _searchMode == SearchMode.invoice
          ? SearchMode.product
          : SearchMode.invoice;
      _cachedFilteredInvoices = null;
      _cachedTotalValueSum = null;
      _searchController.clear();
      _searchQuery = '';
    });
  }

  Future<void> _loadInvoices({int retryCount = 3}) async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final storage = context.read<OfflineStorage>();
      final allInvoices = await storage.getAllInvoiceDetails();

      if (mounted) {
        setState(() {
          _invoices = allInvoices;
          _isLoading = false;
          _cachedFilteredInvoices = null;
          _cachedTotalValueSum = null;
        });

        // 🔥 Auto-fetch purchases for all invoices to get correct totals
        final invoiceIds = allInvoices
            .map((i) => i['invoiceDetailsID']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();

        if (invoiceIds.isNotEmpty) {
          await _fetchPurchasesForInvoices(invoiceIds);

          // 🔥 Recalculate cache after purchases loaded
          if (mounted) {
            setState(() {
              _cachedFilteredInvoices = null;
              _cachedTotalValueSum = null;
            });
          }
        }
      }
    } catch (e) {
      if (retryCount > 0 && mounted) {
        await Future.delayed(Duration(seconds: (3 - retryCount + 1) * 2));
        return _loadInvoices(retryCount: retryCount - 1);
      }

      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar(
          'Error loading invoices: ${e.toString()}',
          isError: true,
        );
      }
    }
  }

  Future<void> _fetchPurchasesForInvoices(Set<String> invoiceIds) async {
    final missingIds = invoiceIds
        .where((id) => !_expandedPurchasesCache.containsKey(id))
        .toList();

    if (missingIds.isEmpty) return;

    setState(() => _loadingInvoiceIds.addAll(missingIds));

    try {
      final storage = context.read<OfflineStorage>();
      final results = await Future.wait(
        missingIds.map((id) => storage.getPurchasesByInvoiceId(id)),
      );

      if (mounted) {
        setState(() {
          for (int i = 0; i < missingIds.length; i++) {
            _expandedPurchasesCache[missingIds[i]] = results[i];
          }
          _loadingInvoiceIds.removeAll(missingIds);
          _cachedFilteredInvoices = null;
          _cachedTotalValueSum = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingInvoiceIds.removeAll(missingIds));
        _showSnackBar('Error loading purchases: $e', isError: true);
      }
    }
  }

  Future<void> _toggleExpandAll() async {
    final filteredInvoices = _getFilteredAndSortedInvoices();
    final visibleIds = filteredInvoices
        .map((i) => i['invoiceDetailsID']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    if (_areAllExpanded) {
      setState(() {
        _expandedInvoices.clear();
        _areAllExpanded = false;
      });
    } else {
      setState(() {
        _expandedInvoices.addAll(visibleIds);
        _areAllExpanded = true;
      });

      // Fetch purchases for all visible invoices
      await _fetchPurchasesForInvoices(visibleIds);
    }
  }

  Future<void> _toggleInvoiceExpansion(String invoiceId) async {
    final isExpanding = !_expandedInvoices.contains(invoiceId);

    setState(() {
      if (isExpanding) {
        _expandedInvoices.add(invoiceId);
      } else {
        _expandedInvoices.remove(invoiceId);
      }

      // Update global expand state
      final visibleIds = _getFilteredAndSortedInvoices()
          .map((i) => i['invoiceDetailsID']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      _areAllExpanded = visibleIds.isNotEmpty && _expandedInvoices.containsAll(visibleIds);
    });

    if (isExpanding && !_expandedPurchasesCache.containsKey(invoiceId)) {
      await _fetchPurchasesForInvoices({invoiceId});

      // 🔥 Recalculate after purchases loaded
      if (mounted) {
        setState(() {
          _cachedFilteredInvoices = null;
          _cachedTotalValueSum = null;
        });
      }
    }
  }

  List<Map<String, dynamic>> _getFilteredAndSortedInvoices() {
    // Return cached result if available
    if (_cachedFilteredInvoices != null) {
      return _cachedFilteredInvoices!;
    }

    var filtered = List<Map<String, dynamic>>.from(_invoices);

    // Status Filter
    if (_statusFilter == InvoiceStatus.pendingLabel) {
      filtered = filtered.where((i) => i['syncStatus'] == InvoiceStatus.pending).toList();
    } else if (_statusFilter == InvoiceStatus.syncedLabel) {
      filtered = filtered.where((i) => i['syncStatus'] == InvoiceStatus.synced).toList();
    }

    // Date Filter
    filtered = _applyDateFilter(filtered);

    // Search Query - Now supports both invoice and product search
    if (_searchQuery.isNotEmpty) {
      filtered = _applySearchFilter(filtered);
    }

    // Sorting
    filtered = _applySorting(filtered);

    // Cache the result
    _cachedFilteredInvoices = filtered;
    return filtered;
  }

  List<Map<String, dynamic>> _applyDateFilter(List<Map<String, dynamic>> filtered) {
    if (_dateFilter == DateFilter.all) return filtered;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return filtered.where((invoice) {
      final date = _parseInvoiceDate(invoice);
      final invoiceDate = DateTime(date.year, date.month, date.day);

      switch (_dateFilter) {
        case DateFilter.today:
          return invoiceDate == today;
        case DateFilter.thisWeek:
          final weekStart = today.subtract(Duration(days: today.weekday - 1));
          final weekEnd = weekStart.add(const Duration(days: 7));
          return invoiceDate.isAfter(weekStart.subtract(const Duration(days: 1))) &&
              invoiceDate.isBefore(weekEnd);
        case DateFilter.thisMonth:
          return invoiceDate.year == now.year && invoiceDate.month == now.month;
        case DateFilter.custom:
          if (_customDateRange == null) return true;
          final start = DateTime(
            _customDateRange!.start.year,
            _customDateRange!.start.month,
            _customDateRange!.start.day,
          );
          final end = DateTime(
            _customDateRange!.end.year,
            _customDateRange!.end.month,
            _customDateRange!.end.day,
            23, 59, 59,
          );
          return invoiceDate.isAfter(start.subtract(const Duration(seconds: 1))) &&
              invoiceDate.isBefore(end.add(const Duration(seconds: 1)));
        default:
          return true;
      }
    }).toList();
  }

  List<Map<String, dynamic>> _applySearchFilter(List<Map<String, dynamic>> filtered) {
    if (_searchMode == SearchMode.invoice) {
      // Search by invoice fields
      return filtered.where((invoice) {
        final number = invoice['Invoice Number']?.toString().toLowerCase() ?? '';
        final supplier = _getSupplierName(invoice).toLowerCase();
        final grvRef = invoice['GRV Reference']?.toString().toLowerCase() ?? '';  // 🔥 ADDED
        final deliveryDate = invoice['Delivery Date']?.toString().toLowerCase() ?? '';
        final purchaseDate = invoice['Date of Purchase']?.toString().toLowerCase() ?? '';

        return number.contains(_searchQuery) ||
            supplier.contains(_searchQuery) ||
            grvRef.contains(_searchQuery) ||  // 🔥 ADDED
            deliveryDate.contains(_searchQuery) ||
            purchaseDate.contains(_searchQuery);
      }).toList();
    } else {
      // Search by product name in purchases
      return filtered.where((invoice) {
        final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';

        // Check if we have purchases cached
        if (_expandedPurchasesCache.containsKey(invoiceId)) {
          final purchases = _expandedPurchasesCache[invoiceId] ?? [];
          return purchases.any((purchase) {
            final productName = purchase['Purchased Product Name']?.toString().toLowerCase() ?? '';
            return productName.contains(_searchQuery);
          });
        }

        // If not cached, we need to fetch purchases for this invoice
        // This is handled async, but for filtering we use what we have
        return false;
      }).toList();
    }
  }

  List<Map<String, dynamic>> _applySorting(List<Map<String, dynamic>> filtered) {
    filtered.sort((a, b) {
      int comp = 0;
      switch (_sortBy) {
        case SortBy.deliveryDate:
          comp = _parseInvoiceDate(a).compareTo(_parseInvoiceDate(b));
          break;
        case SortBy.supplier:
          comp = _getSupplierName(a).toLowerCase().compareTo(_getSupplierName(b).toLowerCase());
          break;
        case SortBy.total:
          comp = _getInvoiceTotal(a).compareTo(_getInvoiceTotal(b));
          break;
      }
      return _sortAscending ? comp : -comp;
    });
    return filtered;
  }

  DateTime _parseInvoiceDate(Map<String, dynamic> invoice) {
    final str = invoice['Delivery Date']?.toString() ??
        invoice['Date of Purchase']?.toString() ??
        '';
    return DateTime.tryParse(str) ?? DateTime.now();
  }

  String _getSupplierName(Map<String, dynamic> invoice) {
    return invoice['Supplier Name']?.toString() ??
        invoice['Supplier']?.toString() ??
        'Unknown Supplier';
  }

  double _getInvoiceTotal(Map<String, dynamic> invoice) {
    final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';
    final purchases = _expandedPurchasesCache[invoiceId] ?? [];

    // 🔥 Always calculate from purchases if available
    if (purchases.isNotEmpty) {
      double calculatedTotal = 0.0;
      for (var item in purchases) {
        final qty = _parseDouble(item['Qty Purchased']);
        final price = _parseDouble(item['Cost Per Bottle']);
        final packSize = _extractPackSize(item['Case/Pack Size']);

        // 🔥 FIX: Use Purchases Bottles (which already accounts for pack size)
        final bottles = _parseDouble(item['Purchases Bottles']);

        // 🔥 Calculate correctly: Purchases Bottles × Cost Per Bottle
        final lineTotal = bottles * price;
        calculatedTotal += lineTotal;
      }
      return calculatedTotal;
    }

    // Fallback: Use stored total from invoice
    final rawVal = invoice['Total Cost Ex Vat'];
    if (rawVal is num) {
      return rawVal.toDouble();
    } else if (rawVal is String) {
      return double.tryParse(rawVal.replaceAll(RegExp(r'[^\d.-]'), '')) ?? 0.0;
    }
    return 0.0;
  }

  String _formatCurrency(dynamic value) {
    double numVal = 0.0;
    if (value is num) {
      numVal = value.toDouble();
    } else if (value is String) {
      numVal = double.tryParse(value.replaceAll(RegExp(r'[^\d.-]'), '')) ?? 0.0;
    }

    final isNegative = numVal < 0;
    final formatted = NumberFormat.currency(symbol: 'R', decimalDigits: 2).format(numVal.abs());
    return isNegative ? '-$formatted' : formatted;
  }

  double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value.replaceAll(RegExp(r'[^\d.-]'), '')) ?? 0.0;
    }
    return 0.0;
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

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _updateDateFilter(String newFilter) {
    setState(() {
      _dateFilter = newFilter;
      _cachedFilteredInvoices = null;
      _cachedTotalValueSum = null;
    });
  }

  Future<void> _syncInvoices() async {
    final pendingCount = _invoices.where((i) => i['syncStatus'] == InvoiceStatus.pending).length;

    if (pendingCount == 0) {
      _showSnackBar('All invoices are up to date!');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync Pending Invoices'),
        content: Text('Upload $pendingCount pending invoice(s) to Google Sheets?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            child: const Text('Sync Now'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Show progress dialog with mounted check
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Syncing invoices...'),
          ],
        ),
      ),
    );

    try {
      final syncService = context.read<StoreManager>().syncService;
      final result = await syncService.syncAll();

      if (mounted) {
        // Use a separate context for navigation to avoid using the same context across async gap
        Navigator.of(context, rootNavigator: true).pop();
        _showSnackBar(result.message, isError: !result.success);
        await _loadInvoices();
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showSnackBar('Sync error: $e', isError: true);
      }
    }
  }

  Future<void> _downloadAllInvoices() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download Server Invoices'),
        content: const Text('This will fetch all invoices from Google Sheets and refresh your local cache.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // ✅ FIX: Add mounted guard before using context again
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      final syncService = context.read<StoreManager>().syncService;
      final invoices = await syncService.downloadInvoices();
      if (mounted) {
        _showSnackBar('Downloaded ${invoices.length} invoices successfully!');
        await _loadInvoices();
      }
    } catch (e) {
      if (mounted) _showSnackBar('Download error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshDataFromServer() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      final syncService = context.read<StoreManager>().syncService;
      final result = await syncService.refreshMasterData();

      if (result.success) {
        _showSnackBar('✅ Data refreshed successfully from server!');

        // Reload invoices and fetch purchases
        await _loadInvoices();

        // Force fetch all purchases for correct totals
        final invoiceIds = _invoices
            .map((i) => i['invoiceDetailsID']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
        if (invoiceIds.isNotEmpty) {
          await _fetchPurchasesForInvoices(invoiceIds);
          if (mounted) {
            setState(() {
              _cachedFilteredInvoices = null;
              _cachedTotalValueSum = null;
            });
          }
        }
      } else {
        _showSnackBar('⚠️ Refresh failed: ${result.message}', isError: true);
      }
    } catch (e) {
      _showSnackBar('❌ Refresh error: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _navigateToNewGrv() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const GrvInvoiceScreen()),
    ).then((_) => _loadInvoices());
  }

  void _viewInvoiceDetails(Map<String, dynamic> invoice) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GrvInvoiceEditScreen(
          invoice: invoice,
          onDeleted: _loadInvoices,
          onUpdated: _loadInvoices,
        ),
      ),
    );
    if (result == true) _loadInvoices();
  }

  Future<void> _pickCustomDateRange(BuildContext context, StateSetter setSheetState) async {
    final picked = await showDateRangePicker(
      context: context,
      useRootNavigator: true,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _customDateRange ?? DateTimeRange(
        start: DateTime.now().subtract(const Duration(days: 7)),
        end: DateTime.now(),
      ),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            primaryColor: Colors.blue,
            colorScheme: const ColorScheme.light(primary: Colors.blue),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setSheetState(() {
        _customDateRange = picked;
        _dateFilter = DateFilter.custom;
      });
      _updateDateFilter(DateFilter.custom);
    }
  }

  void _showFilterBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final customLabel = _customDateRange != null
                ? '${DateFormat('dd MMM').format(_customDateRange!.start)} - ${DateFormat('dd MMM').format(_customDateRange!.end)}'
                : 'Custom Range';

            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Filter & Sort GRVs', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text('Date Range', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ...[DateFilter.all, DateFilter.today, DateFilter.thisWeek, DateFilter.thisMonth]
                          .map((d) {
                        return ChoiceChip(
                          label: Text(d),
                          selected: _dateFilter == d,
                          onSelected: (val) {
                            setSheetState(() => _dateFilter = d);
                            _updateDateFilter(d);
                          },
                        );
                      }),
                      ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(customLabel),
                            const SizedBox(width: 4),
                            const Icon(Icons.date_range, size: 14),
                          ],
                        ),
                        selected: _dateFilter == DateFilter.custom,
                        onSelected: (val) {
                          _pickCustomDateRange(context, setSheetState);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Sort By', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Delivery Date '),
                            Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
                          ],
                        ),
                        selected: _sortBy == SortBy.deliveryDate,
                        onSelected: (_) {
                          setSheetState(() {
                            if (_sortBy == SortBy.deliveryDate) {
                              _sortAscending = !_sortAscending;
                            } else {
                              _sortBy = SortBy.deliveryDate;
                              _sortAscending = false;
                            }
                          });
                          setState(() {
                            _cachedFilteredInvoices = null;
                            _cachedTotalValueSum = null;
                          });
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Supplier'),
                        selected: _sortBy == SortBy.supplier,
                        onSelected: (_) {
                          setSheetState(() => _sortBy = SortBy.supplier);
                          setState(() {
                            _sortBy = SortBy.supplier;
                            _cachedFilteredInvoices = null;
                            _cachedTotalValueSum = null;
                          });
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Amount'),
                        selected: _sortBy == SortBy.total,
                        onSelected: (_) {
                          setSheetState(() => _sortBy = SortBy.total);
                          setState(() {
                            _sortBy = SortBy.total;
                            _cachedFilteredInvoices = null;
                            _cachedTotalValueSum = null;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Apply Filters', style: TextStyle(color: Colors.white, fontSize: 16)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredInvoices = _getFilteredAndSortedInvoices();
    final pendingCount = _invoices.where((i) => i['syncStatus'] == InvoiceStatus.pending).length;

    // ✅ FIX: Use explicit type argument for fold
    _cachedTotalValueSum ??= filteredInvoices.fold<double>(
      0.0,
          (sum, inv) => sum + _getInvoiceTotal(inv),
    );

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: _buildAppBar(pendingCount),
      body: Column(
        children: [
          _buildKpiDashboard(filteredInvoices, pendingCount),
          _buildSearchAndFilters(pendingCount),
          const Divider(height: 1),
          _buildInvoiceList(filteredInvoices),
        ],
      ),
      floatingActionButton: _buildFloatingActionButton(),
    );
  }

  PreferredSizeWidget _buildAppBar(int pendingCount) {
    return AppBar(
      title: const Text('GRV Invoices', style: TextStyle(fontWeight: FontWeight.bold)),
      centerTitle: false,
      actions: [
        IconButton(
          icon: const Icon(Icons.cloud_sync),
          onPressed: _refreshDataFromServer,
          tooltip: 'Refresh Data from Server',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadInvoices,
          tooltip: 'Refresh List',
        ),
        IconButton(
          icon: const Icon(Icons.cloud_download_outlined),
          onPressed: _downloadAllInvoices,
          tooltip: 'Download Server Invoices',
        ),
        IconButton(
          icon: Stack(
            children: [
              const Icon(Icons.cloud_upload_outlined, size: 26),
              if (pendingCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 12, minHeight: 12),
                  ),
                ),
            ],
          ),
          onPressed: _syncInvoices,
          tooltip: 'Upload Pending Invoices',
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildKpiDashboard(List<Map<String, dynamic>> filteredInvoices, int pendingCount) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _buildKpiCard(
              title: 'TOTAL VALUE',
              value: _formatCurrency(_cachedTotalValueSum ?? 0),
              icon: Icons.account_balance_wallet,
              color: (_cachedTotalValueSum ?? 0) < 0 ? Colors.green : Colors.red,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              title: 'GRV COUNT',
              value: '${filteredInvoices.length}',
              icon: Icons.receipt_long,
              color: Colors.blue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              title: 'PENDING SYNC',
              value: '$pendingCount',
              icon: Icons.sync_problem,
              color: pendingCount > 0 ? Colors.orange : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    // Using withValues() instead of deprecated withOpacity()
    final colorWithOpacity = color.withValues(alpha: 0.08);
    final borderColorWithOpacity = color.withValues(alpha: 0.2);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(
        color: colorWithOpacity,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColorWithOpacity),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey.shade900),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters(int pendingCount) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.search, color: Colors.grey.shade600, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    decoration: InputDecoration(
                      hintText: _searchMode == SearchMode.invoice
                          ? 'Search invoice #, GRV, supplier, or date...'  // 🔥 UPDATED
                          : 'Search by product name...',
                      hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                // Search mode toggle button
                Tooltip(
                  message: _searchMode == SearchMode.invoice
                      ? 'Switch to Product Search'
                      : 'Switch to Invoice Search',
                  child: IconButton(
                    icon: Icon(
                      _searchMode == SearchMode.invoice
                          ? Icons.receipt_outlined
                          : Icons.shopping_cart_outlined,
                      size: 18,
                      color: Colors.blue.shade700,
                    ),
                    onPressed: _toggleSearchMode,
                  ),
                ),
                if (_searchQuery.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: _clearSearch,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilterChip(
                label: Text('All (${_invoices.length})'),
                selected: _statusFilter == InvoiceStatus.all,
                onSelected: (_) => setState(() {
                  _statusFilter = InvoiceStatus.all;
                  _cachedFilteredInvoices = null;
                  _cachedTotalValueSum = null;
                }),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: Text('Pending ($pendingCount)'),
                selected: _statusFilter == InvoiceStatus.pendingLabel,
                selectedColor: Colors.orange.shade100,
                onSelected: (_) => setState(() {
                  _statusFilter = InvoiceStatus.pendingLabel;
                  _cachedFilteredInvoices = null;
                  _cachedTotalValueSum = null;
                }),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: Text('Synced (${_invoices.length - pendingCount})'),
                selected: _statusFilter == InvoiceStatus.syncedLabel,
                selectedColor: Colors.green.shade100,
                onSelected: (_) => setState(() {
                  _statusFilter = InvoiceStatus.syncedLabel;
                  _cachedFilteredInvoices = null;
                  _cachedTotalValueSum = null;
                }),
                visualDensity: VisualDensity.compact,
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                  _areAllExpanded ? Icons.unfold_less : Icons.unfold_more,
                  size: 20,
                  color: Colors.blue.shade700,
                ),
                onPressed: _toggleExpandAll,
                tooltip: _areAllExpanded ? 'Collapse All Invoices' : 'Expand All Invoices',
              ),
              IconButton(
                icon: const Icon(Icons.tune, size: 20),
                onPressed: _showFilterBottomSheet,
                tooltip: 'Filter & Sort Options',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInvoiceList(List<Map<String, dynamic>> filteredInvoices) {
    return Expanded(
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : filteredInvoices.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: filteredInvoices.length,
        itemBuilder: (context, index) {
          final invoice = filteredInvoices[index];
          return _buildInvoiceCard(invoice);
        },
      ),
    );
  }

  Widget _buildInvoiceCard(Map<String, dynamic> invoice) {
    final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';
    final isSynced = invoice['syncStatus'] == InvoiceStatus.synced;
    final isExpanded = _expandedInvoices.contains(invoiceId);
    final isLoadingItems = _loadingInvoiceIds.contains(invoiceId);
    final purchases = _expandedPurchasesCache[invoiceId] ?? [];
    final supplierName = _getSupplierName(invoice);
    final supplierInitial = supplierName.isNotEmpty ? supplierName[0].toUpperCase() : '?';
    final totalAmount = _getInvoiceTotal(invoice);
    final isCreditNote = totalAmount < 0;
    final grvRef = invoice['GRV Reference']?.toString() ?? 'N/A';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: InkWell(
        onTap: () => _viewInvoiceDetails(invoice),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.blue.shade100,
                    child: Text(
                      supplierInitial,
                      style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          supplierName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Inv #: ${invoice['Invoice Number'] ?? 'N/A'}',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        ),
                        Text(
                          'GRV: $grvRef',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSynced ? Colors.green.shade50 : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: isSynced ? Colors.green.shade300 : Colors.orange.shade300),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSynced ? Icons.check_circle : Icons.cloud_upload_outlined,
                          size: 12,
                          color: isSynced ? Colors.green.shade800 : Colors.orange.shade800,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isSynced ? 'SYNCED' : 'PENDING',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isSynced ? Colors.green.shade800 : Colors.orange.shade800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.calendar_today_outlined, size: 14, color: Colors.grey.shade600),
                      const SizedBox(width: 4),
                      Text(
                        DateFormat('dd MMM yyyy').format(_parseInvoiceDate(invoice)),
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Text(
                        _formatCurrency(totalAmount),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: isCreditNote ? Colors.green : Colors.red,
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _toggleInvoiceExpansion(invoiceId),
                        child: Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: Icon(
                            isExpanded ? Icons.expand_less : Icons.expand_more,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (isExpanded) ...[
                const SizedBox(height: 10),
                if (isLoadingItems)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (purchases.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No line items recorded',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: purchases.map((item) {
                        // 🔥 FIX: Use Purchases Bottles directly
                        final bottles = _parseDouble(item['Purchases Bottles']);
                        final price = _parseDouble(item['Cost Per Bottle']);

                        // 🔥 Calculate line total correctly
                        final lineTotal = bottles * price;
                        final isLineCredit = lineTotal < 0;

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  item['Purchased Product Name']?.toString() ?? 'Item',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '${bottles.toStringAsFixed(0)} @ ${_formatCurrency(price)} = ${_formatCurrency(lineTotal)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isLineCredit ? Colors.green : Colors.red,
                                  fontWeight: isLineCredit ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _searchQuery.isNotEmpty ? Icons.search_off : Icons.receipt_long_outlined,
            size: 56,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 12),
          Text(
            _searchQuery.isNotEmpty ? 'No matching invoices found' : 'No GRV Invoices Yet',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Text(
            _searchQuery.isNotEmpty
                ? 'Try adjusting your search query or filters'
                : 'Tap "+ New GRV" below to record your first invoice',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingActionButton() {
    return FloatingActionButton.extended(
      onPressed: _navigateToNewGrv,
      icon: const Icon(Icons.add, color: Colors.white),
      label: const Text('New GRV', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      backgroundColor: Colors.blue.shade700,
    );
  }
}