import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/offline_storage.dart';
import '../services/store_manager.dart';
import '../models/grv_models.dart';
import 'grv_invoice_edit_screen.dart';
import 'grv_invoice_screen.dart';

class GrvListScreen extends StatefulWidget {
  const GrvListScreen({super.key});

  @override
  State<GrvListScreen> createState() => _GrvListScreenState();
}

class _GrvListScreenState extends State<GrvListScreen> {
  List<Map<String, dynamic>> _invoices = [];
  Map<String, List<Map<String, dynamic>>> _purchasesByInvoice = {};
  bool _isLoading = true;
  bool _isLoadingPurchases = false;
  String _selectedFilter = 'All';
  final List<String> _filters = ['All', 'Today', 'This Week', 'This Month'];
  bool _showSynced = true; // Show synced invoices by default

  @override
  void initState() {
    super.initState();
    _loadInvoices();
  }

  Future<void> _loadInvoices() async {
    setState(() => _isLoading = true);
    try {
      final storage = context.read<OfflineStorage>();

      // 🔥 FIXED: Get ALL invoices, not just pending
      final allInvoices = await storage.getAllInvoiceDetails();

      print('📊 _loadInvoices: Found ${allInvoices.length} total invoices');

      setState(() {
        _invoices = allInvoices;
        _isLoading = false;
      });

      // Load purchases for each invoice
      await _loadPurchasesForInvoices(allInvoices);
    } catch (e) {
      setState(() => _isLoading = false);
      print('Error loading invoices: $e');
    }
  }

  // 🔴 ADD THE _syncInvoices METHOD HERE 🔴
  Future<void> _syncInvoices() async {
    // Check if there are any pending invoices to sync
    final pendingCount = _invoices.where((i) => i['syncStatus'] == 'pending').length;
    final syncedCount = _invoices.where((i) => i['syncStatus'] == 'synced').length;

    if (pendingCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No pending invoices to sync (${syncedCount} already synced)'),
          backgroundColor: Colors.blue,
        ),
      );
      return;
    }

    // Show confirmation dialog with correct counts
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sync Invoices'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📤 Pending to upload: $pendingCount'),
            Text('✅ Already synced: $syncedCount'),
            const SizedBox(height: 16),
            Text('Upload $pendingCount pending invoice(s) to Google Sheets?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sync Now'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Show loading indicator
    setState(() => _isLoading = true);

    try {
      final storeManager = context.read<StoreManager>();
      final syncService = storeManager.syncService;

      final hasInternet = await syncService.checkConnectivity();
      if (!hasInternet) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No internet connection'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      // Call sync all
      final result = await syncService.syncAll();

      if (mounted) {
        // 🔥 FIXED: Access duplicates directly from result
        if (result.duplicates.isNotEmpty) {
          _showDuplicateInvoicesDialog(context, result.duplicates);
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: result.success ? Colors.green : Colors.red,
          ),
        );

        // Refresh the list
        await _loadInvoices();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showDuplicateInvoicesDialog(BuildContext context, List<Map<String, dynamic>> duplicates) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Duplicate Invoices Detected'),
        content: Container(
          width: double.maxFinite,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The following invoices were not uploaded because they already exist:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.builder(
                  itemCount: duplicates.length,
                  itemBuilder: (context, index) {
                    final dup = duplicates[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: Colors.orange.shade50,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.orange.shade100,
                          child: Text('${index + 1}'),
                        ),
                        title: Text(dup['invoiceNumber'] ?? 'Unknown'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Supplier: ${dup['supplierName'] ?? 'Unknown'}'),
                            Text('Delivery: ${dup['deliveryDate'] ?? 'Unknown'}'),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
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

  Future<void> _loadPurchasesForInvoices(
      List<Map<String, dynamic>> invoices) async {
    setState(() => _isLoadingPurchases = true);
    try {
      final storage = context.read<OfflineStorage>();
      final allPurchases = await storage.getPurchases();

      final Map<String, List<Map<String, dynamic>>> purchasesMap = {};

      for (var invoice in invoices) {
        final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';
        final invoicePurchases = allPurchases.where((p) =>
        p['invoiceDetailsID']?.toString() == invoiceId
        ).toList();

        purchasesMap[invoiceId] = invoicePurchases;
      }

      setState(() {
        _purchasesByInvoice = purchasesMap;
        _isLoadingPurchases = false;
      });
    } catch (e) {
      setState(() => _isLoadingPurchases = false);
      print('Error loading purchases: $e');
    }
  }

  List<Map<String, dynamic>> _getFilteredInvoices() {
    // First apply status filter
    var filtered = _showSynced
        ? _invoices
        : _invoices.where((i) => i['syncStatus'] == 'pending').toList();

    // Then apply date filter
    if (_selectedFilter == 'All') return filtered;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return filtered.where((invoice) {
      final dateStr = invoice['Delivery Date']?.toString() ??
          invoice['Date of Purchase']?.toString() ?? '';
      final date = DateTime.tryParse(dateStr) ?? DateTime.now();
      final invoiceDate = DateTime(date.year, date.month, date.day);

      switch (_selectedFilter) {
        case 'Today':
          return invoiceDate == today;
        case 'This Week':
          final weekStart = today.subtract(Duration(days: today.weekday - 1));
          final weekEnd = weekStart.add(const Duration(days: 7));
          return invoiceDate.isAfter(
              weekStart.subtract(const Duration(days: 1))) &&
              invoiceDate.isBefore(weekEnd);
        case 'This Month':
          return invoiceDate.year == now.year && invoiceDate.month == now.month;
        default:
          return true;
      }
    }).toList();
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return 'Unknown';
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('dd MMM yyyy').format(date);
    } catch (e) {
      return dateStr;
    }
  }

  String _getSupplierName(Map<String, dynamic> invoice) {
    return invoice['Supplier Name']?.toString() ??
        invoice['Supplier']?.toString() ??
        'Unknown Supplier';
  }

  // 🟢 FIXED: Safe number parsing for invoice total
  double _getInvoiceTotal(Map<String, dynamic> invoice) {
    final value = invoice['Total Cost Ex Vat'];

    // Handle null
    if (value == null) return 0.0;

    // If it's already a number
    if (value is num) return value.toDouble();

    // If it's a string, try to parse it
    if (value is String) {
      // Remove any currency symbols or spaces
      final cleanString = value.replaceAll(RegExp(r'[^\d.-]'), '');
      return double.tryParse(cleanString) ?? 0.0;
    }

    // Fallback for any other type
    return 0.0;
  }

  // 🟢 FIXED: Safe number parsing for any currency value
  String _formatCurrency(dynamic value) {
    if (value == null) return 'R0.00';

    double numValue = 0.0;

    if (value is num) {
      numValue = value.toDouble();
    } else if (value is String) {
      final cleanString = value.replaceAll(RegExp(r'[^\d.-]'), '');
      numValue = double.tryParse(cleanString) ?? 0.0;
    }

    return 'R${numValue.toStringAsFixed(2)}';
  }

  // 🟢 FIXED: Safe number parsing for item prices
  double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) {
      final cleanString = value.replaceAll(RegExp(r'[^\d.-]'), '');
      return double.tryParse(cleanString) ?? 0.0;
    }
    return 0.0;
  }

  void _navigateToNewGrv() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const GrvInvoiceScreen(),
      ),
    ).then((_) => _loadInvoices()); // Refresh when returning
  }

  void _viewInvoiceDetails(Map<String, dynamic> invoice) async {
    // 🔥 NEW: Check if invoice has items to determine which view to show
    final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';
    final purchases = _purchasesByInvoice[invoiceId] ?? [];

    if (purchases.isEmpty) {
      // No items - show simple dialog
      _showInvoiceDetailsDialog(invoice);
    } else {
      // Has items - navigate to edit screen
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

      if (result == true) {
        _loadInvoices();
      }
    }
  }

  Future<void> _downloadAllInvoices() async {
    // Check for pending uploads first (same guard as counts screen)
    final storage = context.read<OfflineStorage>();
    final pendingInvoices = await storage.getPendingInvoiceDetails();
    final pendingPurchases = await storage.getPendingPurchases();

    if (pendingInvoices.isNotEmpty || pendingPurchases.isNotEmpty) {
      // Show warning dialog
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('⚠️ Pending Changes Detected'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'You have unsynced changes that will be lost if you download:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              if (pendingInvoices.isNotEmpty)
                Text('• ${pendingInvoices.length} pending invoice(s)'),
              if (pendingPurchases.isNotEmpty)
                Text('• ${pendingPurchases.length} pending purchase(s)'),
              const SizedBox(height: 16),
              const Text(
                'Please sync your changes first (cloud upload) before downloading.',
                style: TextStyle(color: Colors.orange),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
              ),
              child: const Text('Download Anyway'),
            ),
          ],
        ),
      );

      if (proceed != true) return;
    }

    // Show confirmation dialog for download
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Download All Invoices'),
        content: const Text(
            'This will download ALL invoices from Google Sheets, '
                'overwriting any local changes.\n\n'
                'Are you sure?'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
            ),
            child: const Text('Download'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);

    try {
      final storeManager = context.read<StoreManager>();
      final syncService = storeManager.syncService;

      // Check internet
      final hasInternet = await syncService.checkConnectivity();
      if (!hasInternet) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No internet connection'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      // Show progress dialog
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: Card(
            margin: EdgeInsets.all(20),
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Downloading invoices...'),
                ],
              ),
            ),
          ),
        ),
      );

      // 1. Download all invoices from server
      print('📥 Downloading all invoices...');
      final invoices = await syncService.googleSheets.fetchInvoiceDetails();

      // 2. Download all purchases
      print('📥 Downloading all purchases...');
      final purchases = await syncService.googleSheets.fetchPurchases();


      // 🔴 FIX: Mark downloaded invoices as 'synced'
      final syncedInvoices = invoices.map((invoice) {
        invoice['syncStatus'] = 'synced';
        return invoice;
      }).toList();

      // 3. Save to local storage - USE syncedInvoices, not invoices!
      if (syncedInvoices.isNotEmpty) {
        await storage.saveInvoices(syncedInvoices);
        print('✅ Saved ${syncedInvoices.length} invoices');
      }

      if (purchases.isNotEmpty) {
        await storage.savePurchases(purchases);
        print('✅ Saved ${purchases.length} purchases');
      }

      // Close progress dialog
      if (mounted) Navigator.pop(context);

      // Refresh the list
      await _loadInvoices();

      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Downloaded ${invoices.length} invoices and ${purchases.length} purchases',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      // Close progress dialog if open
      if (mounted) {
        try { Navigator.pop(context); } catch (_) {}

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error downloading: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showInvoiceDetailsDialog(Map<String, dynamic> invoice) {
    final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';
    final purchases = _purchasesByInvoice[invoiceId] ?? [];
    final total = _getInvoiceTotal(invoice);

    showDialog(
      context: context,
      builder: (context) =>
          AlertDialog(
            title: Text('Invoice: ${invoice['Invoice Number'] ?? 'Unknown'}'),
            content: Container(
              width: double.maxFinite,
              constraints: BoxConstraints(
                maxHeight: MediaQuery
                    .of(context)
                    .size
                    .height * 0.6,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildInfoRow('Supplier', _getSupplierName(invoice)),
                  _buildInfoRow('Delivery Date',
                      _formatDate(invoice['Delivery Date']?.toString())),
                  _buildInfoRow('Date of Purchase',
                      _formatDate(invoice['Date of Purchase']?.toString())),
                  _buildInfoRow('Total', _formatCurrency(total)),
                  const Divider(height: 24),

                  Expanded(
                    child: purchases.isEmpty
                        ? const Center(
                        child: Text('No items found for this invoice'))
                        : ListView.builder(
                      shrinkWrap: true,
                      itemCount: purchases.length,
                      itemBuilder: (context, index) {
                        final item = purchases[index];
                        final qtyPurchased = _parseDouble(item['Qty Purchased']);
                        final costPerBottle = _parseDouble(item['Cost Per Bottle']);
                        final costOfPurchases = _parseDouble(item['Cost of Purchases']);

                        return ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            radius: 16,
                            backgroundColor: Colors.blue.shade100,
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.blue.shade900),
                            ),
                          ),
                          title: Text(
                            item['Purchased Product Name']?.toString() ??
                                'Unknown',
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            '${qtyPurchased.toStringAsFixed(0)} × Case ${item['Case/Pack Size']} @ ${_formatCurrency(costPerBottle)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text(
                            _formatCurrency(costOfPurchases),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
                '$label:', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredInvoices = _getFilteredInvoices();

    return Scaffold(
      appBar: AppBar(
        title: const Text('GRV Invoices'),
        actions: [
          // Filter dropdown
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButton<String>(
              value: _selectedFilter,
              underline: const SizedBox(),
              icon: const Icon(Icons.filter_list),
              items: _filters.map((filter) {
                return DropdownMenuItem(
                  value: filter,
                  child: Text(filter),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedFilter = value);
                }
              },
            ),
          ),

// Add this after the filter dropdown
          IconButton(
            icon: Icon(_showSynced ? Icons.visibility : Icons.visibility_off),
            tooltip: _showSynced ? 'Hide synced invoices' : 'Show all invoices',
            onPressed: () {
              setState(() {
                _showSynced = !_showSynced;
              });
            },
          ),

          // Cloud Upload - Sync pending invoices
          IconButton(
            icon: const Icon(Icons.cloud_upload),
            tooltip: 'Sync pending invoices',
            onPressed: _syncInvoices,
          ),

          // 🔥 NEW: Cloud Download - Get all historical invoices with guard
          IconButton(
            icon: const Icon(Icons.cloud_download),
            tooltip: 'Download all invoices from server',
            onPressed: _downloadAllInvoices,
          ),

          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadInvoices,
          ),
          IconButton(
            icon: const Icon(Icons.build_circle, color: Colors.red),
            tooltip: 'Force Resync All',
            onPressed: () async {
              // 1. Confirm with user
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Force Resync?'),
                  content: const Text('This will mark ALL invoices as "Pending" and re-upload them to fix the invoice numbers.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Do it')),
                  ],
                ),
              );

              if (confirm == true) {
                // 2. Mark as pending
                final storage = context.read<OfflineStorage>();
                await storage.markAllInvoicesAsPending();

                // 3. Reload list to see them turn orange (Pending)
                _loadInvoices();

                // 4. Trigger the sync
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('All invoices marked pending. Starting upload...'))
                  );
                  _syncInvoices(); // Call your existing sync function
                }
              }
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : filteredInvoices.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text(
              'No GRV Invoices Found',
              style: TextStyle(fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create a new GRV to get started',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _navigateToNewGrv,
              icon: const Icon(Icons.add),
              label: const Text('New GRV Invoice'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: filteredInvoices.length,
        itemBuilder: (context, index) {
          final invoice = filteredInvoices[index];
          final invoiceId = invoice['invoiceDetailsID']?.toString() ?? '';
          final purchases = _purchasesByInvoice[invoiceId] ?? [];
          final itemCount = purchases.length;
          final isLoadingItems = _isLoadingPurchases && itemCount == 0;

          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
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
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                invoice['Invoice Number']?.toString() ??
                                    'Unknown',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _getSupplierName(invoice),
                                style: TextStyle(
                                  color: Colors.grey.shade700,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: invoice['syncStatus'] == 'synced'
                                ? Colors.green.shade100
                                : Colors.orange.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            invoice['syncStatus']?.toString().toUpperCase() ??
                                'PENDING',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: invoice['syncStatus'] == 'synced'
                                  ? Colors.green.shade900
                                  : Colors.orange.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.calendar_today, size: 14, color: Colors.grey
                            .shade600),
                        const SizedBox(width: 4),
                        Text(
                          'Delivery: ${_formatDate(
                              invoice['Delivery Date']?.toString())}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade700),
                        ),
                        const SizedBox(width: 16),
                        Icon(Icons.shopping_cart, size: 14, color: Colors.grey
                            .shade600),
                        const SizedBox(width: 4),
                        isLoadingItems
                            ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                            : Text(
                          '$itemCount items',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Total:',
                          style: TextStyle(
                              fontSize: 14, color: Colors.grey.shade800),
                        ),
                        Text(
                          _formatCurrency(_getInvoiceTotal(invoice)),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToNewGrv,
        icon: const Icon(Icons.add),
        label: const Text('New GRV'),
        backgroundColor: Colors.blue,
      ),
    );
  }
  // Add to the download method or create a new one
  Future<void> _downloadItemsIssuedMap() async {
    setState(() => _isLoading = true);

    try {
      final storage = context.read<OfflineStorage>();
      final syncService = context.read<StoreManager>().syncService;

      final mapData = await syncService.googleSheets.fetchItemsIssuedMap();
      await storage.saveItemsIssuedMap(mapData);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Downloaded ${mapData.length} PLU mappings'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }
}