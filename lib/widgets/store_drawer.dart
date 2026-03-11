import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/store_manager.dart';
import '../screens/setup_store_screen.dart';
import '../screens/migrate_store_screen.dart';

class StoreDrawer extends StatelessWidget {
  const StoreDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Consumer<StoreManager>(
        builder: (context, storeManager, child) {
          final stores = storeManager.stores;
          final activeId = storeManager.activeStore?['id'];

          // Check if there are any legacy stores
          final hasLegacyStores = stores.any((store) => store['isLegacy'] == true);

          return Column(
            children: [
              UserAccountsDrawerHeader(
                decoration: const BoxDecoration(color: Colors.blue),
                accountName: Text(
                  storeManager.activeStore?['name'] ?? 'No Store Selected',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                accountEmail: Text(
                  storeManager.activeStore?['url'] ?? '',
                  style: const TextStyle(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                currentAccountPicture: const CircleAvatar(
                  backgroundColor: Colors.white,
                  child: Icon(Icons.store, size: 32, color: Colors.blue),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text('Switch Store', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                    ),
                    ...stores.map((store) {
                      final isSelected = store['id'] == activeId;
                      final isLegacy = store['isLegacy'] == true;
                      final hasSheetId = (store['sheetId']?.toString() ?? '').isNotEmpty;

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ✅ Legacy badge above store name (only for legacy stores without sheet ID)
                            if (isLegacy && !hasSheetId)
                              Padding(
                                padding: const EdgeInsets.only(left: 56, bottom: 2), // Align with title text
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.orange,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    'LEGACY - NEEDS MIGRATION',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                              ),

                            // Store tile with better spacing
                            Container(
                              decoration: BoxDecoration(
                                color: isSelected ? Colors.blue.shade50 : null,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                leading: Icon(
                                  isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                  color: isSelected ? Colors.blue : Colors.grey,
                                ),
                                title: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Store name with proper truncation
                                    Text(
                                      store['name'],
                                      style: TextStyle(
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        color: isSelected ? Colors.blue : null,
                                        fontSize: 15,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    // URL with truncation
                                    Text(
                                      store['url'] ?? 'No URL',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                                    ),
                                    // ID information
                                    if (hasSheetId)
                                      Text(
                                        'Sheet ID: ${store['sheetId']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 10, color: Colors.green),
                                      ),
                                    if (isLegacy && store['scriptId'] != null)
                                      Text(
                                        'Script ID: ${store['scriptId']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 10, color: Colors.orange),
                                      ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Migrate button for legacy stores
                                    if (isLegacy && !hasSheetId)
                                      IconButton(
                                        icon: const Icon(Icons.sync_problem, color: Colors.orange, size: 20),
                                        onPressed: () => _migrateStore(context, store),
                                        tooltip: 'Migrate Store',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                      ),
                                    const SizedBox(width: 8),
                                    // Delete button
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, size: 20),
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('Remove Store?'),
                                            content: Text('Remove "${store['name']}" from this device? Data will be lost if not synced.'),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(ctx, false),
                                                child: const Text('Cancel'),
                                              ),
                                              TextButton(
                                                onPressed: () => Navigator.pop(ctx, true),
                                                child: const Text('Remove', style: TextStyle(color: Colors.red)),
                                              ),
                                            ],
                                          ),
                                        );

                                        if (confirm == true) {
                                          await storeManager.removeStore(store['id']);
                                        }
                                      },
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  storeManager.setActiveStore(store['id']);
                                  Navigator.pop(context);
                                },
                              ),
                            ),

                            // ✅ Warning banner (only if needed, and below the store)
                            if (isLegacy && !hasSheetId)
                              Container(
                                margin: const EdgeInsets.only(left: 56, right: 12, top: 2, bottom: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: Colors.orange.shade200),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.warning_amber, color: Colors.orange.shade700, size: 14),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Needs migration to work properly',
                                        style: TextStyle(color: Colors.orange.shade700, fontSize: 11),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => _migrateStore(context, store),
                                      style: TextButton.styleFrom(
                                        minimumSize: Size.zero,
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: const Text('Fix Now', style: TextStyle(fontSize: 11)),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      );
                    }),

                    // Migration banner at bottom
                    if (hasLegacyStores)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orange.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.info_outline, color: Colors.orange.shade700, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Legacy Stores Detected',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.orange.shade700,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Some stores need migration to work with the latest version.',
                                style: TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 10),
                              ElevatedButton.icon(
                                onPressed: () => _showMigrationDialog(context, stores),
                                icon: const Icon(Icons.sync, size: 16),
                                label: const Text('View Legacy Stores'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.orange,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(double.infinity, 32),
                                  textStyle: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              const Divider(height: 1),

              // Add New Store Button
              ListTile(
                leading: const Icon(Icons.add_circle, color: Colors.green),
                title: const Text('Add New Store', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SetupStoreScreen()),
                  );
                },
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),

              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }

  void _migrateStore(BuildContext context, Map<String, dynamic> store) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MigrateStoreScreen(store: store),
      ),
    ).then((result) {
      if (result == true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ ${store['name']} migrated successfully'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  void _showMigrationDialog(BuildContext context, List<Map<String, dynamic>> stores) {
    final legacyStores = stores.where((s) => s['isLegacy'] == true).toList();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Migrate Legacy Stores'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Found ${legacyStores.length} legacy store(s) that need migration:'),
              const SizedBox(height: 16),
              ...legacyStores.map((store) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.orange, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            store['name'],
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          if (store['scriptId'] != null)
                            Text(
                              'ID: ${store['scriptId']}',
                              style: const TextStyle(fontSize: 11, color: Colors.grey),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _migrateStore(context, store);
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      ),
                      child: const Text('Migrate'),
                    ),
                  ],
                ),
              )),
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
}