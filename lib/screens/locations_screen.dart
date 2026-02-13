import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../services/sync_service.dart';
import '../services/store_manager.dart';
import 'location_history_screen.dart';

class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key});

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _filteredLocations = [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadLocations();
    _searchController.addListener(_filterLocations);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLocations() async {
    // Safety check before starting
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final storage = context.read<OfflineStorage>();
      final locations = await storage.getLocations();

      // --- CRITICAL FIX: Check mounted after async gap ---
      if (!mounted) return;

      setState(() {
        _locations = locations;
        // Re-apply filter if text exists
        if (_searchController.text.isNotEmpty) {
          _filterLocations();
        } else {
          _filteredLocations = locations;
        }
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterLocations() {
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) {
      setState(() => _filteredLocations = _locations);
      return;
    }
    setState(() {
      _filteredLocations = _locations.where((loc) {
        final name = loc['Location']?.toString().toLowerCase() ?? '';
        return name.contains(query);
      }).toList();
    });
  }

  Future<void> _refreshLocations() async {
    setState(() => _isRefreshing = true);
    try {
      final syncService = context.read<StoreManager>().syncService;
      await syncService.refreshMasterData();

      if (!mounted) return;
      await _loadLocations();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Locations refreshed from server'), backgroundColor: Colors.green));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  // --- CRUD OPERATIONS ---

  Future<void> _showAddEditDialog([Map<String, dynamic>? existingLocation]) async {
    final nameController = TextEditingController(text: existingLocation?['Location']);
    final isEditing = existingLocation != null;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEditing ? 'Edit Location' : 'Add Location'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: 'Location Name', border: OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) return;

              final storage = context.read<OfflineStorage>();
              final locData = {
                'locationID': isEditing ? existingLocation['locationID'] : DateTime.now().millisecondsSinceEpoch.toString(),
                'Location': nameController.text.trim(),
                'Image': isEditing ? existingLocation['Image'] : '',
              };

              await storage.saveLocation(locData);
              if (!context.mounted) return; // Safety check
              Navigator.pop(ctx);
              _loadLocations();

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isEditing ? 'Updated' : 'Added')));
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteLocation(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Location?'),
        content: const Text('This will delete the location from your device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm == true) {
      if (!mounted) return;
      await context.read<OfflineStorage>().deleteLocation(id);
      _loadLocations();
    }
  }

  // --- HELPERS ---

  Widget _buildLocationImage(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) return const CircleAvatar(child: Icon(Icons.location_on));
    bool isValidUrl = imageUrl.startsWith('http');
    if (!isValidUrl) return const CircleAvatar(backgroundColor: Colors.grey, child: Icon(Icons.broken_image, color: Colors.white));
    return CircleAvatar(backgroundImage: NetworkImage(imageUrl), onBackgroundImageError: (_, __) {}, radius: 20);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Locations'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _isRefreshing ? null : _refreshLocations),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search locations...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddEditDialog(),
        child: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _filteredLocations.isEmpty
          ? const Center(child: Text('No locations found'))
          : ListView.builder(
        itemCount: _filteredLocations.length,
        itemBuilder: (context, index) {
          final loc = _filteredLocations[index];
          final name = loc['Location']?.toString() ?? 'Unknown';
          final id = loc['locationID']?.toString() ?? '';
          final image = loc['Image']?.toString();

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: ListTile(
              leading: _buildLocationImage(image),
              title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),

              // Drill Down on Tap
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => LocationHistoryScreen(locationName: name),
                  ),
                );
              },

              // Edit/Delete Menu
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _showAddEditDialog(loc);
                  if (value == 'delete') _deleteLocation(id);
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit, color: Colors.blue), SizedBox(width: 8), Text('Edit')])),
                  const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete, color: Colors.red), SizedBox(width: 8), Text('Delete')])),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}