import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import '../services/store_manager.dart';
import 'grv_invoice_edit_screen.dart';
import 'grv_invoice_screen.dart';

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

  // Search & Filters
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  String _statusFilter = 'All'; // 'All', 'Pending', 'Synced'
  String _dateFilter = 'All';   // 'All', 'Today', 'This Week', 'This Month', 'Custom'
  DateTimeRange? _customDateRange;

  String _sortBy = 'deliveryDate'; // 'deliveryDate', 'supplier', 'total'
  bool _sortAscending = false;

  // UI State
  final Set<String> _expandedInvoices = {};
  final Set<String> _loadingInvoiceIds = {};

  @override
  void initState() {
    super.initState();
    _loadInvoices();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase().trim();
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
    FocusScope.of(context).unfocus();
  }

  Future<void> _loadInvoices() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final storage = context.read<OfflineStorage>();
      final allInvoices = await storage.getAllInvoiceDetails();

      if (mounted) {
        setState(() {
          _invoices = allInvoices;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar('Error loading invoices: $e', isError: true);
      }
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
    });

    if (isExpanding && !_expandedPurchasesCache.containsKey(invoiceId)) {
      setState(() => _loadingInvoiceIds.add(invoiceId));
      try {
        final storage = context.read<OfflineStorage>();
        final purchases = await storage.getPurchasesByInvoiceId(invoiceId);

        if (mounted) {
          setState(() {
            _expandedPurchasesCache[invoiceId] = purchases;
            _loadingInvoiceIds.remove(invoiceId);
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() => _loadingInvoiceIds.remove(invoiceId));
        }
      }
    }
  }

  List<Map<String, dynamic>> _getFilteredAndSortedInvoices() {
    var filtered = List<Map<String, dynamic>>.from(_invoices);

    // Status Filter
    if (_statusFilter == 'Pending') {
      filtered = filtered.where((i) => i['syncStatus'] == 'pending').toList();
    } else if (_statusFilter == 'Synced') {
      filtered = filtered.where((i) => i['syncStatus'] == 'synced').toList();
    }

    // Date Filter
    if (_dateFilter != 'All') {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      filtered = filtered.where((invoice) {
        final dateStr = invoice['Delivery Date']?.toString() ?? invoice['Date of Purchase']?.toString() ?? '';
        final date = DateTime.tryParse(dateStr) ?? DateTime.now();
        final invoiceDate = DateTime(date.year, date.month, date.day);

        switch (_dateFilter) {
          case 'Today':
            return invoiceDate == today;
          case 'This Week':
            final weekStart = today.subtract(Duration(days: today.weekday - 1));
            final weekEnd = weekStart.add(const Duration(days: 7));
            return invoiceDate.isAfter(weekStart.subtract(const Duration(days: 1))) && invoiceDate.isBefore(weekEnd);
          case 'This Month':
            return invoiceDate.year == now.year && invoiceDate.month == now.month;
          case 'Custom':
            if (_customDateRange == null) return true;
            final start = DateTime(_customDateRange!.start.year, _customDateRange!.start.month, _customDateRange!.start.day);
            final end = DateTime(_customDateRange!.end.year, _customDateRange!.end.month, _customDateRange!.end.day, 23, 59, 59);
            return invoiceDate.isAfter(start.subtract(const Duration(seconds: 1))) && invoiceDate.isBefore(end.add(const Duration(seconds: 1)));
          default:
            return true;
        }
      }).toList();
    }

    // Search Query
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((invoice) {
        final number = invoice['Invoice Number']?.toString().toLowerCase() ?? '';
        final supplier = (invoice['Supplier Name'] ?? invoice['Supplier'])?.toString().toLowerCase() ?? '';
        final deliveryDate = invoice['Delivery Date']?.toString().toLowerCase() ?? '';
        return number.contains(_searchQuery) || supplier.contains(_searchQuery) || deliveryDate.contains(_searchQuery);
      }).toList();
    }

    // Sorting
    filtered.sort((a, b) {
      int comp = 0;
      switch (_sortBy) {
        case 'deliveryDate':
          comp = _getInvoiceDate(a).compareTo(_getInvoiceDate(b));
          break;
        case 'supplier':
          comp = _getSupplierName(a).toLowerCase().compareTo(_getSupplierName(b).toLowerCase());
          break;
        case 'total':
          comp = _getInvoiceTotal(a).compareTo(_getInvoiceTotal(b));
          break;
      }
      return _sortAscending ? comp : -comp;
    });

    return filtered;
  }

  DateTime _getInvoiceDate(Map<String, dynamic> invoice) {
    final str = invoice['Delivery Date']?.toString() ?? invoice['Date of Purchase']?.toString() ?? '';
    return DateTime.tryParse(str) ?? DateTime.now();
  }

  String _getSupplierName(Map<String, dynamic> invoice) {
    return invoice['Supplier Name']?.toString() ?? invoice['Supplier']?.toString() ?? 'Unknown Supplier';
  }

  double _getInvoiceTotal(Map<String, dynamic> invoice) {
    final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';
    final purchases = _expandedPurchasesCache[invoiceId] ?? [];

    double val = 0.0;
    final rawVal = invoice['Total Cost Ex Vat'];
    if (rawVal is num) {
      val = rawVal.toDouble();
    } else if (rawVal is String) {
      val = double.tryParse(rawVal.replaceAll(RegExp(r'[^\d.-]'), '')) ?? 0.0;
    }

    // Auto-detect Credit Note: Force total to be negative if any purchase line item is negative
    final hasNegativePurchases = purchases.any((p) => _parseDouble(p['Qty Purchased']) < 0);
    if (hasNegativePurchases && val > 0) {
      val = -val;
    }

    return val;
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
        backgroundColor: isError ? Colors.red : Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _syncInvoices() async {
    final pendingCount = _invoices.where((i) => i['syncStatus'] == 'pending').length;

    if (pendingCount == 0) {
      _showSnackBar('All invoices are up to date!', isError: false);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync Pending Invoices'),
        content: Text('Upload $pendingCount pending invoice(s) to Google Sheets?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            child: const Text('Sync Now'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);

    try {
      final syncService = context.read<StoreManager>().syncService;
      final result = await syncService.syncAll();

      if (mounted) {
        _showSnackBar(result.message, isError: !result.success);
        await _loadInvoices();
      }
    } catch (e) {
      if (mounted) _showSnackBar('Sync error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _downloadAllInvoices() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download Server Invoices'),
        content: const Text('This will fetch all invoices from Google Sheets and refresh your local cache.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

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
        _dateFilter = 'Custom';
      });
      setState(() {
        _customDateRange = picked;
        _dateFilter = 'Custom';
      });
    }
  }

  void _showFilterBottomSheet() {
    showModalBottomSheet(
      context: context,
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
                      ...['All', 'Today', 'This Week', 'This Month'].map((d) {
                        return ChoiceChip(
                          label: Text(d),
                          selected: _dateFilter == d,
                          onSelected: (val) {
                            setSheetState(() => _dateFilter = d);
                            setState(() => _dateFilter = d);
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
                        selected: _dateFilter == 'Custom',
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
                        selected: _sortBy == 'deliveryDate',
                        onSelected: (_) {
                          setSheetState(() {
                            if (_sortBy == 'deliveryDate') {
                              _sortAscending = !_sortAscending;
                            } else {
                              _sortBy = 'deliveryDate';
                              _sortAscending = false;
                            }
                          });
                          setState(() {});
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Supplier'),
                        selected: _sortBy == 'supplier',
                        onSelected: (_) {
                          setSheetState(() => _sortBy = 'supplier');
                          setState(() => _sortBy = 'supplier');
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Amount'),
                        selected: _sortBy == 'total',
                        onSelected: (_) {
                          setSheetState(() => _sortBy = 'total');
                          setState(() => _sortBy = 'total');
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, padding: const EdgeInsets.symmetric(vertical: 14)),
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
    final pendingCount = _invoices.where((i) => i['syncStatus'] == 'pending').length;
    final totalValueSum = filteredInvoices.fold(0.0, (sum, inv) => sum + _getInvoiceTotal(inv));

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text('GRV Invoices', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: false,
        actions: [
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
      ),
      body: Column(
        children: [
          // 📊 TOP KPI DASHBOARD CARD
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: _buildKpiCard(
                    title: 'TOTAL VALUE',
                    value: _formatCurrency(totalValueSum),
                    icon: Icons.account_balance_wallet,
                    // 🔥 ACCOUNTING CONVENTION: Red = Purchases (Money Out), Green = Refunds/Credits (Money Back)
                    color: totalValueSum < 0 ? Colors.green : Colors.red,
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
          ),

          // 🔍 SEARCH & QUICK STATUS FILTER ROW
          Container(
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
                            hintText: 'Search invoice #, supplier, or date...',
                            hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                            border: InputBorder.none,
                            isDense: true,
                          ),
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
                      selected: _statusFilter == 'All',
                      onSelected: (_) => setState(() => _statusFilter = 'All'),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: Text('Pending ($pendingCount)'),
                      selected: _statusFilter == 'Pending',
                      selectedColor: Colors.orange.shade100,
                      onSelected: (_) => setState(() => _statusFilter = 'Pending'),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                    FilterChip(
                      label: const Text('Synced'),
                      selected: _statusFilter == 'Synced',
                      selectedColor: Colors.green.shade100,
                      onSelected: (_) => setState(() => _statusFilter = 'Synced'),
                      visualDensity: VisualDensity.compact,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.tune, size: 20),
                      onPressed: _showFilterBottomSheet,
                      tooltip: 'Filter & Sort Options',
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // 📇 INVOICE LIST
          Expanded(
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
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToNewGrv,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('New GRV', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.blue.shade700,
      ),
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
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

  Widget _buildInvoiceCard(Map<String, dynamic> invoice) {
    final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';
    final isSynced = invoice['syncStatus'] == 'synced';
    final isExpanded = _expandedInvoices.contains(invoiceId);
    final isLoadingItems = _loadingInvoiceIds.contains(invoiceId);
    final purchases = _expandedPurchasesCache[invoiceId] ?? [];
    final supplierName = _getSupplierName(invoice);
    final supplierInitial = supplierName.isNotEmpty ? supplierName[0].toUpperCase() : '?';
    final totalAmount = _getInvoiceTotal(invoice);
    final isCreditNote = totalAmount < 0;

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
                    child: Text(supplierInitial, style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.bold)),
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
                        DateFormat('dd MMM yyyy').format(_getInvoiceDate(invoice)),
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      // 🔥 ACCOUNTING CONVENTION: Red = Purchases (Money Out), Green = Credits (Money Back)
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
                    child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                  )
                else if (purchases.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('No line items recorded', style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontStyle: FontStyle.italic)),
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
                        final qty = _parseDouble(item['Qty Purchased']);
                        final price = _parseDouble(item['Cost Per Bottle']);
                        final packSize = _extractPackSize(item['Case/Pack Size']);

                        final rawLineTotal = item['Cost of Purchases'];
                        double lineTotal = (rawLineTotal != null && _parseDouble(rawCostToNum(rawLineTotal)) != 0.0)
                            ? _parseDouble(rawCostToNum(rawLineTotal)).abs()
                            : (qty.abs() * packSize * price);

                        if (qty < 0) {
                          lineTotal = -lineTotal.abs();
                        }

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
                                '${qty.toStringAsFixed(0)} pk @ ${_formatCurrency(price)} = ${_formatCurrency(lineTotal)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  // 🔥 ACCOUNTING CONVENTION: Green for Credit Lines (-), Red for Purchase Lines (+)
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

  dynamic rawCostToNum(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val;
    return double.tryParse(val.toString().replaceAll(RegExp(r'[^\d.-]'), '')) ?? 0.0;
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
            _searchQuery.isNotEmpty ? 'Try adjusting your search query or filters' : 'Tap "+ New GRV" below to record your first invoice',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}