import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'sync_service.dart';
import 'google_sheets_service.dart';
import 'logger_service.dart';
import 'offline_storage.dart';

class StoreManager with ChangeNotifier {
  static const String _globalBoxName = 'global_app_config';
  static const String _activeStoreKey = 'active_store_id';
  static const String _storesKey = 'saved_stores';

  late Box _box;
  bool _initialized = false;
  final LoggerService? _logger;
  final OfflineStorage offlineStorage;

  Map<String, dynamic>? _activeStore;
  List<Map<String, dynamic>> _stores = [];

  // Store-scoped sync service with store identifier
  SyncService? _syncService;

  StoreManager({required this.offlineStorage, LoggerService? logger})
      : _logger = logger;

  bool get isInitialized => _initialized;
  Map<String, dynamic>? get activeStore => _activeStore;
  List<Map<String, dynamic>> get stores => _stores;

  // Get store-scoped sync service using store identifier
  SyncService get syncService {
    if (_syncService == null || _syncService!.isDisposed) {
      // Extract store identifier from the original script URL
      final storeId = extractStoreIdFromUrl(_activeStore?['url'] ?? '');

      final googleSheets = GoogleSheetsService(
        masterScriptUrl: 'YOUR_SINGLE_MASTER_SCRIPT_URL', // Same for all stores
        storeIdentifier: storeId, // Extracted from original URL
        logger: _logger,
      );

      _syncService = SyncService(
        offlineStorage: offlineStorage,
        googleSheets: googleSheets,
        logger: _logger,
      );

      // Set for OfflineStorage
      final storeIdForStorage = extractStoreIdFromUrl(_activeStore?['url'] ?? '');
      offlineStorage.setGoogleSheetsService(googleSheets, storeIdForStorage);
    }
    return _syncService!;
  }

  // Extract unique identifier from Google Apps Script URL
  String extractStoreIdFromUrl(String scriptUrl) {
    // Example: https://script.google.com/macros/s/AKfycby8rEkWNyByf-As3UYF4GD74lpRmfzAjT_tYz3OASSDQhSzeZrH48zDMGYjBmVcoPQ/exec
    // Extract: AKfycby8rEkWNyByf-As3UYF4GD74lpRmfzAjT_tYz3OASSDQhSzeZrH48zDMGYjBmVcoPQ
    final regex = RegExp(r'/s/([^/]+)/exec');
    final match = regex.firstMatch(scriptUrl);
    return match?.group(1) ?? DateTime.now().millisecondsSinceEpoch.toString();
  }

  Future<void> init() async {
    if (_initialized) return;
    _box = await Hive.openBox(_globalBoxName);
    _loadStores();
    _loadActiveStore();
    _initialized = true;
    notifyListeners();
  }

  void _loadStores() {
    final rawList = _box.get(_storesKey, defaultValue: []);
    _stores = List<Map<String, dynamic>>.from(
        rawList.map((e) => Map<String, dynamic>.from(e))
    );
  }

  void _loadActiveStore() {
    final activeId = _box.get(_activeStoreKey);
    if (activeId != null && _stores.isNotEmpty) {
      _activeStore = _stores.firstWhere(
              (s) => s['id'] == activeId,
          orElse: () => _stores.first
      );
    }
  }

  Future<void> addStore(String name, String scriptUrl) async {
    // Extract store identifier from the script URL
    final storeId = extractStoreIdFromUrl(scriptUrl);

    final newStore = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'name': name,
      'url': scriptUrl.trim(), // Store the original URL
    };

    _stores.add(newStore);
    await _box.put(_storesKey, _stores);
    await setActiveStore(newStore['id']!);
  }

  Future<void> setActiveStore(String storeId) async {
    print('DEBUG: StoreManager.setActiveStore() called with storeId: $storeId');

    // Dispose old sync service
    _syncService?.dispose();
    _syncService = null;

    final store = _stores.firstWhere((s) => s['id'] == storeId);
    _activeStore = store;
    await _box.put(_activeStoreKey, storeId);

    print('  ✅ Active store set: ${store['name']} (URL: ${store['url']})');

    // Extract store identifier from URL
    final storeIdentifier = extractStoreIdFromUrl(store['url'] ?? '');

    final googleSheetsService = GoogleSheetsService(
      masterScriptUrl: 'https://script.google.com/macros/s/AKfycbzHaJ6Jgn9XFiFw081cUBp0OkEwrz8uTc1TY50ATtcTcQss7rmp10fsyH8FQEcnHIu-/exec', // Same for all stores
      storeIdentifier: storeIdentifier, // Extracted from URL
      logger: _logger,
    );

    print('  ✅ Created GoogleSheetsService for identifier: $storeIdentifier');

    offlineStorage.setGoogleSheetsService(googleSheetsService, storeIdentifier);
    await offlineStorage.switchStore(storeId);

    notifyListeners();
  }

  Future<void> removeStore(String storeId) async {
    _stores.removeWhere((s) => s['id'] == storeId);
    await _box.put(_storesKey, _stores);

    if (_activeStore?['id'] == storeId) {
      _syncService?.dispose();
      _syncService = null;
      _activeStore = null;
      await _box.delete(_activeStoreKey);
    }
    notifyListeners();
  }
}