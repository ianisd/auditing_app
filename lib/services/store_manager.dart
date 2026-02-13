import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
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
  final OfflineStorage offlineStorage; // ✅ INJECTED: Passed from main.dart

  Map<String, dynamic>? _activeStore;
  List<Map<String, dynamic>> _stores = [];

  // ✅ NEW: Store-scoped sync service
  SyncService? _syncService;

  // ✅ FIXED: Constructor accepts offlineStorage
  StoreManager({required this.offlineStorage, LoggerService? logger})
      : _logger = logger;

  bool get isInitialized => _initialized;

  Map<String, dynamic>? get activeStore => _activeStore;

  List<Map<String, dynamic>> get stores => _stores;

  // ✅ FIXED: Get store-scoped sync service using injected offlineStorage
  SyncService get syncService {
    if (_syncService == null || _syncService!.isDisposed) {
      final url = _activeStore?['url'] ?? '';
      final googleSheets = GoogleSheetsService(scriptUrl: url, logger: _logger);

      _syncService = SyncService(
        offlineStorage: offlineStorage,
        googleSheets: googleSheets,
        logger: _logger,
      );

      // ✅ CRITICAL: Also set for OfflineStorage (since sync_service uses same instance)
      offlineStorage.setGoogleSheetsService(googleSheets, url);
    }
    return _syncService!;
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

  Future<void> addStore(String name, String url) async {
    final newStore = {
      'id': DateTime
          .now()
          .millisecondsSinceEpoch
          .toString(),
      'name': name,
      'url': url.trim(),
    };

    _stores.add(newStore);
    await _box.put(_storesKey, _stores);
    await setActiveStore(newStore['id']!);
  }

  Future<void> setActiveStore(String storeId) async {
    print('DEBUG: StoreManager.setActiveStore() called with storeId: $storeId');

    // CRITICAL: Dispose old sync service BEFORE changing store
    _syncService?.dispose();
    _syncService = null;

    final store = _stores.firstWhere((s) => s['id'] == storeId);
    _activeStore = store;
    await _box.put(_activeStoreKey, storeId);

    print('  ✅ Active store set: ${store['name']} (${store['url']})');

    // CRITICAL: Create GoogleSheetsService for this store
    final googleSheetsService = GoogleSheetsService(
      scriptUrl: store['url'] ?? '',
      logger: _logger,
    );

    print('  ✅ Created GoogleSheetsService for URL: ${store['url']}');

    // ✅ CRITICAL: Pass service to OfflineStorage BEFORE calling switchStore
    print('  🔄 Calling offlineStorage.setGoogleSheetsService()');
    offlineStorage.setGoogleSheetsService(
        googleSheetsService, store['url'] ?? '');
    print('  ✅ GoogleSheetsService passed to OfflineStorage');

    // ✅ CRITICAL: Now call switchStore to load master data
    print('  🔄 Calling offlineStorage.switchStore($storeId)');
    await offlineStorage.switchStore(storeId);
    print('  ✅ offlineStorage.switchStore() completed');

    notifyListeners();
  }
  Future<void> removeStore(String storeId) async {
    _stores.removeWhere((s) => s['id'] == storeId);
    await _box.put(_storesKey, _stores);

    if (_activeStore?['id'] == storeId) {
      _syncService?.dispose(); // ✅ Dispose sync service when removing active store
      _syncService = null;
      _activeStore = null;
      await _box.delete(_activeStoreKey);
    }
    notifyListeners();
  }
}