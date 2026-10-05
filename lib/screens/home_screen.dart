import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/sync_status.dart';
import '../widgets/store_drawer.dart';
import '../models/sync_model.dart'; // 🔥 ADD THIS
import 'count_screen.dart';
import 'grv_list_screen.dart';
import 'grv_upload_screen.dart';
import 'view_counts_screen.dart';
import 'sync_screen.dart';
import 'locations_screen.dart';
import 'inventory_screen.dart';
import 'offline_screen.dart';
import 'variance_report_screen.dart';
import 'plu_mapping_screen.dart';
import 'setup_store_screen.dart';
import '../services/store_manager.dart';
import 'network_status_screen.dart';
import 'sales_upload_screen.dart';
import 'sales_report_screen.dart';

import 'process_menu_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  // Keep each action beside its destination; no parallel navigation arrays.
  static final List<ProcessMenu> _processes = [
    ProcessMenu(title: 'Data & Sync', description: 'Sync changes and inspect local data',
        icon: Icons.sync, color: Colors.orange, actions: [
          ProcessAction(title: 'Sync Data', description: 'Review and sync pending changes',
              icon: Icons.cloud_upload, builder: (_) => const SyncScreen()),
          ProcessAction(title: 'Offline Data', description: 'Inspect locally stored data',
              icon: Icons.storage, builder: (_) => const OfflineScreen()),
          ProcessAction(title: 'Network Status', description: 'View connection and sync details',
              icon: Icons.wifi, builder: (_) => const NetworkStatusScreen()),
        ]),
    ProcessMenu(title: 'Stock Counting', description: 'Start a count or review saved counts',
        icon: Icons.fact_check_outlined, color: Colors.blue, actions: [
          ProcessAction(title: 'New Count', description: 'Scan and count items',
              icon: Icons.add_circle_outline, builder: (_) => const CountScreen()),
          ProcessAction(title: 'View Counts', description: 'Browse and edit counts',
              icon: Icons.list_alt, builder: (_) => const ViewCountsScreen()),
        ]),
    ProcessMenu(title: 'GRVs & Purchases', description: 'Import and manage supplier invoices',
        icon: Icons.receipt_long, color: Colors.deepOrange, actions: [
          ProcessAction(title: 'Upload GRV CSV', description: 'Auto-extract from a CSV file',
              icon: Icons.upload_file, builder: (_) => const GrvUploadScreen()),
          ProcessAction(title: 'GRV Invoices', description: 'Create, view and edit invoices',
              icon: Icons.receipt, builder: (_) => const GrvListScreen()),
          ProcessAction(title: 'PLU Mappings', description: 'Manage GRV product mappings',
              icon: Icons.link, builder: (_) => const PluMappingScreen()),
        ]),
    ProcessMenu(title: 'Sales', description: 'Import sales and review reports',
        icon: Icons.point_of_sale, color: Colors.green, actions: [
          ProcessAction(title: 'Upload Sales', description: 'Import GAAP sales data',
              icon: Icons.upload_file, builder: (_) => const SalesUploadScreen()),
          ProcessAction(title: 'Sales Report', description: 'Search and review imported sales',
              icon: Icons.assessment_outlined, builder: (_) => const SalesReportScreen()),
        ]),
    ProcessMenu(title: 'Reports', description: 'Compare stock, purchases and sales',
        icon: Icons.analytics_outlined, color: Colors.purple, actions: [
          ProcessAction(title: 'Variance Report', description: 'Compare counts against sales and purchases',
              icon: Icons.analytics, builder: (_) => const VarianceReportScreen()),
        ]),
    ProcessMenu(title: 'Inventory & Locations', description: 'Manage products and stock locations',
        icon: Icons.inventory_2_outlined, color: Colors.indigo, actions: [
          ProcessAction(title: 'Inventory', description: 'View the master product list',
              icon: Icons.inventory_2_outlined, builder: (_) => const InventoryScreen()),
          ProcessAction(title: 'Locations', description: 'View and manage locations',
              icon: Icons.location_on, builder: (_) => const LocationsScreen()),
        ]),
  ];

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const StoreDrawer(),
      appBar: AppBar(
        title: const Text('Stock Counter'),
        actions: [
          IconButton(
            tooltip: 'Manage Stores',
            icon: const Icon(Icons.store_outlined),
            onPressed: () => _open(context, const SetupStoreScreen()),
          ),
          Consumer<SyncStatus>(
            builder: (context, status, _) => Stack(
              children: [
                IconButton(
                  tooltip: 'Sync Data (${status.pendingCount} pending)',
                  icon: const Icon(Icons.sync),
                  onPressed: () => _open(context, const SyncScreen()),
                ),
                if (status.pendingCount > 0)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          status.pendingCount > 99 ? '99+' : '${status.pendingCount}',
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SyncStatusWidget(),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Consumer<StoreManager>(
                        builder: (context, manager, _) => Card(
                          child: Builder(
                            builder: (context) => ListTile(
                              leading: const Icon(Icons.store_outlined),
                              title: Text('${manager.activeStore?['name'] ?? 'No Store'}'),
                              subtitle: const Text('Switch active store'),
                              trailing: const Icon(Icons.swap_horiz),
                              onTap: () => Scaffold.of(context).openDrawer(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text('What would you like to do?',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final scale = MediaQuery.textScalerOf(context).scale(1);
                          final columns = constraints.maxWidth < 300 || scale > 1.5
                              ? 1 : constraints.maxWidth >= 720 ? 3 : 2;
                          return GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _processes.length,
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: 1,
                            ),
                            itemBuilder: (context, index) {
                              final menu = _processes[index];
                              return _ProcessTile(
                                menu: menu,
                                onTap: () => _open(context, ProcessMenuScreen(menu: menu)),
                              );
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const NetworkStatusBar(),
          ],
        ),
      ),
    );
  }
}

class _ProcessTile extends StatelessWidget {
  final ProcessMenu menu;
  final VoidCallback onTap;

  const _ProcessTile({required this.menu, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: menu.description,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(menu.icon, size: 36, color: menu.color),
                const SizedBox(height: 12),
                Flexible(
                  child: Text(menu.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NetworkStatusBar extends StatelessWidget {
  const NetworkStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<StoreManager>(
      builder: (context, storeManager, _) {
        final syncService = storeManager.syncService;
        final isSyncing = syncService.isSyncing;

        return Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.grey[100],
            border: Border(top: BorderSide(color: Colors.grey.shade300)),
          ),
          child: Row(
            children: [
              Icon(
                isSyncing ? Icons.sync : Icons.wifi,
                size: 18,
                color: isSyncing ? Colors.blue : Colors.grey,
              ),
              const SizedBox(width: 8),
              Text(
                isSyncing ? 'Syncing data...' : 'Network ready',
                style: TextStyle(
                  fontSize: 13,
                  color: isSyncing ? Colors.blue : Colors.grey[700],
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const NetworkStatusScreen(),
                  ),
                ),
                icon: const Icon(Icons.info_outline, size: 16),
                label: const Text('Details'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
