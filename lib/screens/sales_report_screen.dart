import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/offline_storage.dart';

enum SalesSortBy { plu, menuItem, quantity, sales }

class SalesReportScreen extends StatefulWidget {
  const SalesReportScreen({super.key});

  @override
  State<SalesReportScreen> createState() => _SalesReportScreenState();
}

class _SalesReportScreenState extends State<SalesReportScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounceTimer;

  List<Map<String, dynamic>> _allRows = [];
  List<Map<String, dynamic>> _saleLines = [];
  bool _isLoading = true;
  String? _error;

  String _searchQuery = '';
  DateTime? _selectedAuditDate;
  SalesSortBy _sortBy = SalesSortBy.sales;
  bool _sortAscending = false;

  final NumberFormat _currency =
  NumberFormat.currency(locale: 'en_ZA', symbol: 'R', decimalDigits: 2);
  final NumberFormat _quantity = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadSales();
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
      if (!mounted) return;
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  Future<void> _loadSales() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final storage = context.read<OfflineStorage>();
      final rows = await storage.getStoreSalesData();

      final saleLines = rows.where(_isSaleLine).toList();
      final dates = _availableAuditDatesFrom(saleLines);

      if (!mounted) return;

      setState(() {
        _allRows = rows;
        _saleLines = saleLines;

        // Keep the user's selected audit when it still exists.
        // On first load, default to the newest audit date.
        if (_selectedAuditDate == null ||
            !dates.any((date) => _sameDate(date, _selectedAuditDate!))) {
          _selectedAuditDate = dates.isEmpty ? null : dates.first;
        }

        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  bool _isSaleLine(Map<String, dynamic> row) {
    final plu = _clean(row['No.']);
    if (plu.isEmpty) return false;

    // GAAP headings/subtotals may have text in the No. column.
    // Real sales rows use a numeric PLU.
    return num.tryParse(plu.replaceAll(',', '')) != null;
  }

  List<DateTime> _availableAuditDatesFrom(
      List<Map<String, dynamic>> rows,
      ) {
    final unique = <String, DateTime>{};

    for (final row in rows) {
      final date = _parseDate(row['Date']);
      if (date == null) continue;

      final day = DateTime(date.year, date.month, date.day);
      unique[_dateKey(day)] = day;
    }

    final result = unique.values.toList()
      ..sort((a, b) => b.compareTo(a));
    return result;
  }

  List<DateTime> get _availableAuditDates =>
      _availableAuditDatesFrom(_saleLines);

  List<Map<String, dynamic>> get _visibleRows {
    var rows = _saleLines.where((row) {
      if (_selectedAuditDate != null) {
        final rowDate = _parseDate(row['Date']);
        if (rowDate == null || !_sameDate(rowDate, _selectedAuditDate!)) {
          return false;
        }
      }

      if (_searchQuery.isEmpty) return true;

      final searchable = [
        row['No.'],
        row['MenuItem'],
        row['Item'],
        row['salesID'],
      ].map(_clean).join(' ').toLowerCase();

      return searchable.contains(_searchQuery);
    }).toList();

    rows.sort((a, b) {
      int comparison;

      switch (_sortBy) {
        case SalesSortBy.plu:
          comparison = _comparePlu(a['No.'], b['No.']);
          break;
        case SalesSortBy.menuItem:
          comparison = _displayName(a)
              .toLowerCase()
              .compareTo(_displayName(b).toLowerCase());
          break;
        case SalesSortBy.quantity:
          comparison = _number(a['Qty']).compareTo(_number(b['Qty']));
          break;
        case SalesSortBy.sales:
          comparison = _number(a['Sales']).compareTo(_number(b['Sales']));
          break;
      }

      return _sortAscending ? comparison : -comparison;
    });

    return rows;
  }

  double _sum(List<Map<String, dynamic>> rows, String key) {
    return rows.fold<double>(
      0,
          (total, row) => total + _number(row[key]),
    );
  }

  int _comparePlu(dynamic a, dynamic b) {
    final aText = _clean(a);
    final bText = _clean(b);
    final aNumber = num.tryParse(aText.replaceAll(',', ''));
    final bNumber = num.tryParse(bText.replaceAll(',', ''));

    if (aNumber != null && bNumber != null) {
      return aNumber.compareTo(bNumber);
    }
    return aText.toLowerCase().compareTo(bText.toLowerCase());
  }

  String _displayName(Map<String, dynamic> row) {
    final menuItem = _clean(row['MenuItem']);
    if (menuItem.isNotEmpty) return menuItem;

    final item = _clean(row['Item']);
    return item.isEmpty ? 'Unnamed item' : item;
  }

  String _secondaryName(Map<String, dynamic> row) {
    final menuItem = _clean(row['MenuItem']);
    final item = _clean(row['Item']);

    if (menuItem.isNotEmpty &&
        item.isNotEmpty &&
        menuItem.toLowerCase() != item.toLowerCase()) {
      return item;
    }

    return '';
  }

  String _clean(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  double _number(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();

    var text = value.toString().trim();
    if (text.isEmpty) return 0;

    var negative = false;
    if (text.startsWith('(') && text.endsWith(')')) {
      negative = true;
      text = text.substring(1, text.length - 1);
    }

    text = text
        .replaceAll('R', '')
        .replaceAll('r', '')
        .replaceAll('%', '')
        .replaceAll(',', '')
        .replaceAll(' ', '');

    final parsed = double.tryParse(text) ?? 0;
    return negative ? -parsed : parsed;
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;

    final text = value.toString().trim();
    if (text.isEmpty) return null;

    final iso = DateTime.tryParse(text);
    if (iso != null) return iso;

    for (final format in [
      'dd/MM/yyyy',
      'd/M/yyyy',
      'dd-MM-yyyy',
      'd-M-yyyy',
      'yyyy/MM/dd',
    ]) {
      try {
        return DateFormat(format).parseStrict(text);
      } catch (_) {
        // Try the next known format.
      }
    }

    return null;
  }

  bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';

  String _formatDate(DateTime date) =>
      DateFormat('dd MMM yyyy').format(date);

  String _formatQuantity(double value) => _quantity.format(value);

  String _formatCurrency(double value) => _currency.format(value);

  void _clearSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
  }

  void _setSort(SalesSortBy sortBy) {
    setState(() {
      if (_sortBy == sortBy) {
        _sortAscending = !_sortAscending;
      } else {
        _sortBy = sortBy;
        _sortAscending =
            sortBy == SalesSortBy.plu || sortBy == SalesSortBy.menuItem;
      }
    });
  }

  Future<void> _showFilterSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void selectDate(DateTime? value) {
              setState(() => _selectedAuditDate = value);
              setSheetState(() {});
            }

            void selectSort(SalesSortBy value) {
              _setSort(value);
              setSheetState(() {});
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Filter & Sort Sales',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(sheetContext),
                          ),
                        ],
                      ),
                      const Divider(),
                      const SizedBox(height: 8),
                      const Text(
                        'Audit Date',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('All Audits'),
                            selected: _selectedAuditDate == null,
                            onSelected: (_) => selectDate(null),
                          ),
                          ..._availableAuditDates.map(
                                (date) => ChoiceChip(
                              label: Text(_formatDate(date)),
                              selected: _selectedAuditDate != null &&
                                  _sameDate(date, _selectedAuditDate!),
                              onSelected: (_) => selectDate(date),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Sort By',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _sortChip(
                            'Sales',
                            SalesSortBy.sales,
                            onSelected: selectSort,
                          ),
                          _sortChip(
                            'Quantity',
                            SalesSortBy.quantity,
                            onSelected: selectSort,
                          ),
                          _sortChip(
                            'PLU',
                            SalesSortBy.plu,
                            onSelected: selectSort,
                          ),
                          _sortChip(
                            'Menu Item',
                            SalesSortBy.menuItem,
                            onSelected: selectSort,
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text(
                            'Apply Filters',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sortChip(
      String label,
      SalesSortBy value, {
        required void Function(SalesSortBy) onSelected,
      }) {
    final selected = _sortBy == value;

    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (selected) ...[
            const SizedBox(width: 4),
            Icon(
              _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
            ),
          ],
        ],
      ),
      selected: selected,
      onSelected: (_) => onSelected(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleRows;
    final totalSales = _sum(visible, 'Sales');
    final totalQuantity = _sum(visible, 'Qty');

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text(
          'Sales Report',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh local sales',
            onPressed: _isLoading ? null : _loadSales,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _buildKpis(
            totalSales: totalSales,
            totalQuantity: totalQuantity,
            lineCount: visible.length,
          ),
          _buildSearchAndFilters(),
          const Divider(height: 1),
          Expanded(child: _buildBody(visible)),
        ],
      ),
    );
  }

  Widget _buildKpis({
    required double totalSales,
    required double totalQuantity,
    required int lineCount,
  }) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _buildKpiCard(
              title: 'TOTAL SALES',
              value: _formatCurrency(totalSales),
              icon: Icons.payments_outlined,
              color: Colors.green,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              title: 'QTY SOLD',
              value: _formatQuantity(totalQuantity),
              icon: Icons.shopping_cart_outlined,
              color: Colors.blue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              title: 'SALES LINES',
              value: '$lineCount',
              icon: Icons.receipt_long_outlined,
              color: Colors.deepOrange,
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
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.20)),
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
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade900,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    final auditLabel = _selectedAuditDate == null
        ? 'All Audits'
        : _formatDate(_selectedAuditDate!);

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
                      hintText: 'Search PLU, menu item, or description...',
                      hintStyle: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 13,
                      ),
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
              Flexible(
                child: FilterChip(
                  avatar: const Icon(Icons.event_outlined, size: 16),
                  label: Text(
                    auditLabel,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: _selectedAuditDate != null,
                  onSelected: (_) => _showFilterSheet(),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_visibleRows.length} lines',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.tune, size: 20),
                onPressed: _showFilterSheet,
                tooltip: 'Filter & Sort Options',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody(List<Map<String, dynamic>> visible) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _buildMessageState(
        icon: Icons.error_outline,
        title: 'Could not load sales',
        message: _error!,
        actionLabel: 'Try Again',
        onAction: _loadSales,
      );
    }

    if (_allRows.isEmpty) {
      return _buildMessageState(
        icon: Icons.point_of_sale_outlined,
        title: 'No Sales Data Yet',
        message: 'Upload sales or refresh your store data to populate this report.',
      );
    }

    if (_saleLines.isEmpty) {
      return _buildMessageState(
        icon: Icons.receipt_long_outlined,
        title: 'No Sales Lines Found',
        message:
        'StoreSalesData exists, but no rows contain a numeric PLU in the No. column.',
      );
    }

    if (visible.isEmpty) {
      return _buildMessageState(
        icon: Icons.search_off,
        title: 'No Matching Sales',
        message: 'Try another audit date, search term, or filter.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 850) {
          return _buildDesktopTable(visible);
        }
        return _buildMobileList(visible);
      },
    );
  }

  Widget _buildDesktopTable(List<Map<String, dynamic>> rows) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: Card(
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade300),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              sortColumnIndex: _sortColumnIndex,
              sortAscending: _sortAscending,
              columns: [
                DataColumn(
                  label: const Text('PLU'),
                  onSort: (_, __) => _setSort(SalesSortBy.plu),
                ),
                DataColumn(
                  label: const Text('Menu Item'),
                  onSort: (_, __) => _setSort(SalesSortBy.menuItem),
                ),
                DataColumn(
                  numeric: true,
                  label: const Text('Qty'),
                  onSort: (_, __) => _setSort(SalesSortBy.quantity),
                ),
                DataColumn(
                  numeric: true,
                  label: const Text('Sales'),
                  onSort: (_, __) => _setSort(SalesSortBy.sales),
                ),
              ],
              rows: rows.map((row) {
                return DataRow(
                  cells: [
                    DataCell(Text(_clean(row['No.']))),
                    DataCell(
                      SizedBox(
                        width: 360,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _displayName(row),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_secondaryName(row).isNotEmpty)
                              Text(
                                _secondaryName(row),
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 11,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ),
                    DataCell(
                      Text(_formatQuantity(_number(row['Qty']))),
                    ),
                    DataCell(
                      Text(
                        _formatCurrency(_number(row['Sales'])),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  int get _sortColumnIndex {
    switch (_sortBy) {
      case SalesSortBy.plu:
        return 0;
      case SalesSortBy.menuItem:
        return 1;
      case SalesSortBy.quantity:
        return 2;
      case SalesSortBy.sales:
        return 3;
    }
  }

  Widget _buildMobileList(List<Map<String, dynamic>> rows) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final secondary = _secondaryName(row);

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade300),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.blue.shade50,
                  child: Text(
                    _clean(row['No.']),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.blue.shade800,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayName(row),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (secondary.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          secondary,
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        'Qty ${_formatQuantity(_number(row['Qty']))}',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _formatCurrency(_number(row['Sales'])),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessageState({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onAction,
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
