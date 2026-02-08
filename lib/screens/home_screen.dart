import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/sync_service.dart';
import '../widgets/sync_status.dart'; // <--- THIS IMPORT IS CRITICAL
import '../widgets/store_drawer.dart';
import 'count_screen.dart';
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SyncStatusWidget(), // This should now work
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    _buildFeatureCard(
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
                    ),
                    const SizedBox(height: 16),
                    _buildFeatureCard(
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
                    ),
                    const SizedBox(height: 16),
                    _buildFeatureCard(
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
                    ),
                    const SizedBox(height: 16),
                    _buildFeatureCard(
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
                    ),
                    const SizedBox(height: 16),
                    _buildFeatureCard(
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
                    ),
                    const SizedBox(height: 16),
                    _buildFeatureCard(
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
                    ),
                  ],
                ),
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