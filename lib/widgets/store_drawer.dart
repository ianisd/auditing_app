import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/store_manager.dart';
import '../screens/setup_store_screen.dart';

class StoreDrawer extends StatelessWidget {
  const StoreDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Consumer<StoreManager>(
        builder: (context, storeManager, child) {
          final stores = storeManager.stores;
          final activeId = storeManager.activeStore?['id'];

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
                      return ListTile(
                        leading: Icon(
                          isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          color: isSelected ? Colors.blue : Colors.grey,
                        ),
                        title: Text(
                          store['name'],
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? Colors.blue : null,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Remove Store?'),
                                content: Text('Remove "${store['name']}" from this device? Data will be lost if not synced.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                  TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove', style: TextStyle(color: Colors.red))),
                                ],
                              ),
                            );

                            if (confirm == true) {
                              await storeManager.removeStore(store['id']);
                            }
                          },
                        ),
                        onTap: () {
                          // Switch store
                          storeManager.setActiveStore(store['id']);
                          Navigator.pop(context); // Close drawer
                        },
                      );
                    }),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.add_circle, color: Colors.green),
                title: const Text('Add New Store', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(context); // Close drawer
                  // Navigate to Setup Screen to add a new one
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SetupStoreScreen()),
                  );
                },
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}