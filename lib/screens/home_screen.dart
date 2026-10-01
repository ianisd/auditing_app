import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../widgets/sync_status.dart';
import '../widgets/store_drawer.dart';
import '../models/sync_model.dart';  // 🔥 ADD THIS
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
import 'package:flutter/foundation.dart';
import 'network_status_screen.dart';
import 'sales_upload_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  // 🔥 FIX: Cache the pending count future
  Future<int>? _pendingCountFuture;
  bool _isPendingCountLoading = false;

  static const List<_NavItem> _navItems = [
    _NavItem(icon: Icons.cloud_upload, label: 'Sync'),
    _NavItem(icon: Icons.upload_file, label: 'Upload GRV'),
    _NavItem(icon: Icons.point_of_sale, label: 'Upload Sales'),
    _NavItem(icon: Icons.receipt, label: 'GRV Invoices'),
    _NavItem(icon: Icons.link, label: 'PLU Mappings'),
    _NavItem(icon: Icons.analytics, label: 'Variance'),
    _NavItem(icon: Icons.inventory_2_outlined, label: 'Inventory'),
    _NavItem(icon: Icons.location_on, label: 'Locations'),
    _NavItem(icon: Icons.store, label: 'Stores'),
    _NavItem(icon: Icons.list_alt, label: 'Counts'),
    _NavItem(icon: Icons.add_circle_outline, label: 'New Count'),
  ];

  static const List<Widget> _screens = [
    SyncScreen(),
    GrvUploadScreen(),
    SalesUploadScreen(),
    GrvListScreen(),
    PluMappingScreen(),
    VarianceReportScreen(),
    InventoryScreen(),
    LocationsScreen(),
    SetupStoreScreen(),
    ViewCountsScreen(),
    CountScreen(),
  ];
  bool get _isDesktop =>
      !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.linux);

  // 🔥 FIX: Listen to storage changes to refresh badge
  @override
  void initState() {
    super.initState();
    _refreshPendingCount();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final storage = context.read<OfflineStorage>();
      storage.addListener(_onStorageChanged);
    });
  }

  void _onStorageChanged() {
    if (mounted) {
      _refreshPendingCount();
    }
  }

  void _refreshPendingCount() {
    if (!mounted || _isPendingCountLoading) return;
    _isPendingCountLoading = true;
    setState(() {
      _pendingCountFuture = context.read<OfflineStorage>().getTotalPendingItemsCount();
    });
    // Reset loading flag after the future completes
    _pendingCountFuture?.then((_) {
      if (mounted) {
        _isPendingCountLoading = false;
      }
    }).catchError((_) {
      if (mounted) {
        _isPendingCountLoading = false;
      }
    });
  }

  @override
  void dispose() {
    try {
      context.read<OfflineStorage>().removeListener(_onStorageChanged);
    } catch (e) {
      // Ignore
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _isDesktop ? _buildDesktopLayout() : _buildMobileLayout();
  }

  // ─── DESKTOP LAYOUT ───────────────────────────────────────────────────────
  Widget _buildDesktopLayout() {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Row(
        children: [
          // Left navigation rail
          SingleChildScrollView(
            child: IntrinsicHeight(
              child: NavigationRail(
                selectedIndex: _selectedIndex,
                onDestinationSelected: (i) => setState(() => _selectedIndex = i),
                labelType: NavigationRailLabelType.all,
                minWidth: 88,
                destinations: _navItems
                    .map((item) => NavigationRailDestination(
                  icon: Icon(item.icon),
                  label: Text(item.label, style: const TextStyle(fontSize: 11)),
                ))
                    .toList(),
                leading: Column(
                  children: [
                    const SizedBox(height: 8),
                    Consumer<StoreManager>(
                      builder: (context, storeManager, _) {
                        final storeName = storeManager.activeStore?['name'] ?? 'No Store';
                        return Tooltip(
                          message: 'Switch Store: $storeName',
                          child: InkWell(
                            onTap: () => _showStoreSwitcher(context),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              width: 72,
                              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.blue.shade100),
                              ),
                              child: Column(
                                children: [
                                  const Icon(Icons.store, color: Colors.blue, size: 22),
                                  const SizedBox(height: 4),
                                  Text(
                                    storeName,
                                    maxLines: 2,
                                    textAlign: TextAlign.center,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.blue,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
                trailing: Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _buildPendingBadge(),
                    ),
                  ),
                ),
              ),
            ),
          ),

          const VerticalDivider(thickness: 1, width: 1),

          // Right content area
          Expanded(
            child: Column(
              children: [
                const SyncStatusWidget(),
                Expanded(child: _screens[_selectedIndex]),
                const NetworkStatusBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── MOBILE LAYOUT ────────────────────────────────────────────────────────
  Widget _buildMobileLayout() {
    return Scaffold(
      drawer: const StoreDrawer(),
      appBar: _buildAppBar(showDrawer: true),
      body: SafeArea(
        child: Column(
          children: [
            const SyncStatusWidget(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: 20,
                        itemBuilder: (context, index) {
                          switch (index) {
                            case 0:
                              return _buildFeatureCard(
                                icon: Icons.cloud_upload,
                                title: 'Sync Data',
                                subtitle: 'Upload counts to server',
                                color: Colors.orange,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const SyncScreen())),
                              );
                            case 1: return const SizedBox(height: 16);
                            case 2:
                              return _buildFeatureCard(
                                icon: Icons.add_circle_outline,
                                title: 'New Count',
                                subtitle: 'Scan and count items',
                                color: Colors.blue,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const CountScreen())),
                              );
                            case 3: return const SizedBox(height: 16);
                            case 4:
                              return _buildFeatureCard(
                                icon: Icons.list_alt,
                                title: 'View Counts',
                                subtitle: 'Browse and edit counts',
                                color: Colors.green,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const ViewCountsScreen())),
                              );
                            case 5: return const SizedBox(height: 16);
                            case 6:
                              return _buildFeatureCard(
                                icon: Icons.upload_file,
                                title: 'Upload GRV CSV',
                                subtitle: 'Auto-extract from CSV file',
                                color: Colors.brown,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const GrvUploadScreen())),
                              );
                            case 7: return const SizedBox(height: 16);
                            case 8:
                              return _buildFeatureCard(
                                icon: Icons.receipt,
                                title: 'GRV Invoices',
                                subtitle: 'View saved GRV invoices',
                                color: Colors.deepOrange,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const GrvListScreen())),
                              );
                            case 9: return const SizedBox(height: 16);
                            case 10:
                              return _buildFeatureCard(
                                icon: Icons.link,
                                title: 'PLU Mappings',
                                subtitle: 'Manage GRV PLU mappings',
                                color: Colors.amber.shade700,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const PluMappingScreen())),
                              );
                            case 11: return const SizedBox(height: 16);
                            case 12:
                              return _buildFeatureCard(
                                icon: Icons.analytics,
                                title: 'Variance Report',
                                subtitle: 'Compare counts vs sales & purchases',
                                color: Colors.purple,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const VarianceReportScreen())),
                              );
                            case 13: return const SizedBox(height: 16);
                            case 14:
                              return _buildFeatureCard(
                                icon: Icons.inventory_2_outlined,
                                title: 'Inventory',
                                subtitle: 'View master product list',
                                color: Colors.indigo,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const InventoryScreen())),
                              );
                            case 15: return const SizedBox(height: 16);
                            case 16:
                              return _buildFeatureCard(
                                icon: Icons.location_on,
                                title: 'Locations',
                                subtitle: 'View and manage locations',
                                color: Colors.teal,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const LocationsScreen())),
                              );
                            case 17: return const SizedBox(height: 16);
                            case 18:
                              return _buildFeatureCard(
                                icon: Icons.store,
                                title: 'Manage Stores',
                                subtitle: 'Add or switch stores',
                                color: Colors.blueGrey,
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) => const SetupStoreScreen())),
                              );
                            case 19: return const SizedBox(height: 16);
                            default: return const SizedBox.shrink();
                          }
                        },
                      ),
                      _buildPendingBadge(),
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

  // ─── SHARED WIDGETS ───────────────────────────────────────────────────────
  PreferredSizeWidget _buildAppBar({bool showDrawer = false}) {
    return AppBar(
      title: const Text('Stock Counter'),
      centerTitle: true,
      automaticallyImplyLeading: showDrawer,
      actions: [
        if (!_isDesktop)
          IconButton(
            icon: const Icon(Icons.storage),
            tooltip: 'Offline Data',
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const OfflineScreen())),
          ),
        // 🔥 FIX: Use cached future for badge
        Consumer<SyncStatus>(
          builder: (context, syncStatus, _) {
            final pendingCount = syncStatus.pendingCount;
            return Stack(
              children: [
                IconButton(
                  icon: const Icon(Icons.sync),
                  onPressed: () {
                    if (_isDesktop) {
                      setState(() => _selectedIndex = 0);
                    } else {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const SyncScreen()));
                    }
                  },
                ),
                if (pendingCount > 0)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        pendingCount > 9 ? '9+' : pendingCount.toString(),
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  void _showStoreSwitcher(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 380,
          height: 520,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: const StoreDrawer(),
          ),
        ),
      ),
    );
  }

  Widget _buildPendingBadge() {
    return Consumer<OfflineStorage>(
      builder: (context, storage, _) {
        final pending = storage.pendingCounts.length;
        if (pending == 0) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.orange[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.shade300),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange[800], size: 16),
              const SizedBox(width: 4),
              Text(
                '$pending pending',
                style: TextStyle(
                    color: Colors.orange[800],
                    fontWeight: FontWeight.bold,
                    fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFeatureCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

// Simple data class for nav items
class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}

// ─── NETWORK STATUS BAR ───────────────────────────────────────────────────
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
                  MaterialPageRoute(builder: (_) => const NetworkStatusScreen()),
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