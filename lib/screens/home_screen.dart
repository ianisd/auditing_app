import 'package:counting_app/screens/plu_mapping_screen.dart';
import 'package:counting_app/screens/setup_store_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../widgets/sync_status.dart';
import '../widgets/store_drawer.dart';
import 'count_screen.dart';
import 'grv_list_screen.dart';
import 'grv_upload_screen.dart';
import 'view_counts_screen.dart';
import 'sync_screen.dart';
import 'locations_screen.dart';
import 'inventory_screen.dart';
import 'offline_screen.dart';
import 'variance_report_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const StoreDrawer(),
      appBar: AppBar(
        title: const Text('Stock Counter'),
        actions: [
          IconButton(
            icon: const Icon(Icons.storage),
            tooltip: 'Offline Data',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const OfflineScreen(),
                ),
              );
            },
          ),
          Consumer<OfflineStorage>(
            builder: (context, storage, child) {
              final pendingCount = storage.pendingCounts.length;
              return Stack(
                children: [
                  IconButton(
                    icon: const Icon(Icons.sync),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SyncScreen(),
                        ),
                      );
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
                        constraints: const BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        child: Text(
                          pendingCount > 9 ? '9+' : pendingCount.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SyncStatusWidget(),
                const SizedBox(height: 16),

                // ✅ FIXED: Correct indexing - 14 total items (0-13)
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 20, // ✅ UPDATED: 20 items total (added PLU Mappings)
                  itemBuilder: (context, index) {
                    switch (index) {
                      case 0:
                        return _buildFeatureCard(
                          icon: Icons.cloud_upload,
                          title: 'Sync Data',
                          subtitle: 'Upload counts to server',
                          color: Colors.orange,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const SyncScreen(),
                            ),
                          ),
                        );
                      case 1:
                        return const SizedBox(height: 16);
                      case 2:
                        return _buildFeatureCard(
                          icon: Icons.add_circle_outline,
                          title: 'New Count',
                          subtitle: 'Scan and count items',
                          color: Colors.blue,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const CountScreen(),
                            ),
                          ),
                        );
                      case 3:
                        return const SizedBox(height: 16);
                      case 4:
                        return _buildFeatureCard(
                          icon: Icons.list_alt,
                          title: 'View Counts',
                          subtitle: 'Browse and edit counts',
                          color: Colors.green,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const ViewCountsScreen(),
                            ),
                          ),
                        );
                      case 5:
                        return const SizedBox(height: 16);
                      case 6:
                        return _buildFeatureCard(
                          icon: Icons.upload_file,
                          title: 'Upload GRV CSV',
                          subtitle: 'Auto-extract from CSV file',
                          color: Colors.brown,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const GrvUploadScreen(),
                            ),
                          ),
                        );
                      case 7:
                        return const SizedBox(height: 16);
                      case 8:
                        return _buildFeatureCard(
                          icon: Icons.receipt,
                          title: 'GRV Invoices',
                          subtitle: 'View saved GRV invoices',
                          color: Colors.deepOrange,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const GrvListScreen(),
                            ),
                          ),
                        );
                      case 9:
                        return const SizedBox(height: 16);
                      case 10: // ✅ PLU MAPPINGS (NEW)
                        return _buildFeatureCard(
                          icon: Icons.link,
                          title: 'PLU Mappings',
                          subtitle: 'Manage GRV PLU mappings',
                          color: Colors.amber.shade700, // Choose a distinct color
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const PluMappingScreen()),
                            );
                          },
                        );
                      case 11:
                        return const SizedBox(height: 16);
                      case 12: // ✅ VARIANCE REPORT
                        return _buildFeatureCard(
                          icon: Icons.analytics,
                          title: 'Variance Report',
                          subtitle: 'Compare counts vs sales & purchases',
                          color: Colors.purple,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const VarianceReportScreen(),
                            ),
                          ),
                        );
                      case 13:
                        return const SizedBox(height: 16);
                      case 14: // ✅ INVENTORY
                        return _buildFeatureCard(
                          icon: Icons.inventory_2_outlined,
                          title: 'Inventory',
                          subtitle: 'View master product list',
                          color: Colors.indigo,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const InventoryScreen(),
                            ),
                          ),
                        );
                      case 15:
                        return const SizedBox(height: 16);
                      case 16: // ✅ LOCATIONS
                        return _buildFeatureCard(
                          icon: Icons.location_on,
                          title: 'Locations',
                          subtitle: 'View and manage locations',
                          color: Colors.teal,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const LocationsScreen(),
                            ),
                          ),
                        );
                      case 17:
                        return const SizedBox(height: 16);
                      case 18: // ✅ ADD STORE
                        return _buildFeatureCard(
                          icon: Icons.store,
                          title: 'Manage Stores',
                          subtitle: 'Add or switch stores',
                          color: Colors.blueGrey,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const SetupStoreScreen(),
                            ),
                          ),
                        );
                      case 19:
                        return const SizedBox(height: 16);
                      default:
                        return const SizedBox.shrink();
                    }
                  },
                ),
                Consumer<OfflineStorage>(
                  builder: (context, storage, child) {
                    final pending = storage.pendingCounts.length;
                    if (pending > 0) {
                      return Card(
                        margin: const EdgeInsets.only(top: 16),
                        color: Colors.orange[50],
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  color: Colors.orange[800]),
                              const SizedBox(width: 8),
                              Text(
                                '$pending counts pending sync',
                                style: TextStyle(
                                  color: Colors.orange[800],
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
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
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
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