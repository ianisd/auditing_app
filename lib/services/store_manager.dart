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

  static const String _masterScriptUrl =
      'https://script.google.com/macros/s/AKfycbx262dF2LJDSMrt2OLnDvaKtGD5VDTlByGk0AP9R79jZgkuvmP2-0nXWlGriplx8aI/exec';

  late Box _box;
  bool _initialized = false;
  final LoggerService? _logger;
  final OfflineStorage offlineStorage;

  Map<String, dynamic>? _activeStore;
  List<Map<String, dynamic>> _stores = [];

  SyncService? _syncService;

  static const int _currentStoreVersion = 2;
  static const String _storeVersionKey = 'store_version';

  bool get isInitialized => _initialized;
  Map<String, dynamic>? get activeStore => _activeStore;
  List<Map<String, dynamic>> get stores => _stores;

  bool get isReady {
    return _activeStore != null &&
        _syncService != null &&
        !_syncService!.isDisposed &&
        offlineStorage.isReady;
  }

  SyncService get syncService {
    if (_activeStore == null) {
      throw Exception('No active store selected - cannot create sync service');
    }

    if (_syncService == null || _syncService!.isDisposed) {
      final storeSheetId = _getStoreIdentifier();

      _logger?.info('🔧 Creating SyncService for store: ${_activeStore!['name']}');

      final googleSheets = GoogleSheetsService(
        masterScriptUrl: _masterScriptUrl,
        storeIdentifier: storeSheetId,
        logger: _logger,
      );

      _syncService = SyncService(
        offlineStorage: offlineStorage,
        googleSheets: googleSheets,
        logger: _logger,
      );

      offlineStorage.setGoogleSheetsService(googleSheets, storeSheetId);
    }
    return _syncService!;
  }

  StoreManager({required this.offlineStorage, LoggerService? logger})
      : _logger = logger;

  Future<void> init() async {
    if (_initialized) return;
    _logger?.info('📦 Initializing StoreManager...');

    _box = await Hive.openBox(_globalBoxName);
    _loadStores();
    await _migrateLegacyStores();
    _loadActiveStore();
    _initialized = true;

    _logger?.info('✅ StoreManager initialized. Found ${_stores.length} stores');
    if (_activeStore != null) {
      _logger?.info('📌 Active store: ${_activeStore!['name']}');
    }

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
      try {
        _activeStore = _stores.firstWhere(
              (s) => s['id'] == activeId,
          orElse: () => _stores.isNotEmpty ? _stores.first : <String, dynamic>{},
        );
        if (_activeStore?.isEmpty ?? true) _activeStore = null;
      } catch (e) {
        _logger?.error('Error loading active store', e.toString());
        _activeStore = null;
      }
    }
  }

  String _getStoreIdentifier() {
    if (_activeStore == null) return '';

    String identifier = _activeStore!['sheetId']?.toString() ?? '';

    if (identifier.isEmpty) {
      identifier = _activeStore!['scriptId']?.toString() ?? '';
    }

    if (identifier.isEmpty) {
      identifier = extractSheetIdFromUrl(_activeStore!['url'] ?? '');
    }

    return identifier;
  }

  Future<void> _migrateLegacyStores() async {
    try {
      int version = _box.get(_storeVersionKey, defaultValue: 1);

      if (version >= _currentStoreVersion) return;

      _logger?.info('🔄 Migrating stores from version $version to $_currentStoreVersion');

      for (var store in _stores) {
        if (version < 2) {
          final url = store['url']?.toString() ?? '';
          final extractedId = _extractIdFromUrl(url);

          if (extractedId.startsWith('AKfy')) {
            store['scriptId'] = extractedId;
            store['sheetId'] = '';
          } else if (extractedId.isNotEmpty) {
            store['sheetId'] = extractedId;
            store['scriptId'] = '';
          }

          store['isLegacy'] = true;
          store['needsSheetId'] = store['sheetId']?.isEmpty ?? true;
        }
      }

      await _box.put(_storesKey, _stores);
      await _box.put(_storeVersionKey, _currentStoreVersion);
      _logger?.info('✅ Store migration complete');
    } catch (e) {
      _logger?.error('Migration error', e.toString());
    }
  }

  String _extractIdFromUrl(String url) {
    if (url.isEmpty) return '';

    try {
      final sheetRegex = RegExp(r'/spreadsheets/d/([a-zA-Z0-9-_]+)');
      final sheetMatch = sheetRegex.firstMatch(url);
      if (sheetMatch != null) return sheetMatch.group(1)!;

      final scriptRegex = RegExp(r'/s/([^/]+)/exec');
      final scriptMatch = scriptRegex.firstMatch(url);
      if (scriptMatch != null) return scriptMatch.group(1)!;
    } catch (e) {
      _logger?.error('Error extracting ID from URL', e.toString());
    }

    return '';
  }

  String extractSheetIdFromUrl(String storeUrl) {
    if (storeUrl.isEmpty) return '';
    return _extractIdFromUrl(storeUrl);
  }

  Map<String, dynamic>? getStoreById(String storeId) {
    try {
      return _stores.firstWhere((s) => s['id'] == storeId);
    } catch (e) {
      return null;
    }
  }

  Future<void> addStore(String name, String scriptUrl) async {
    _logger?.info('➕ Adding new store: $name');

    try {
      final trimmedUrl = scriptUrl.trim();
      final extractedId = _extractIdFromUrl(trimmedUrl);
      final isScriptId = extractedId.startsWith('AKfy');

      final newStore = {
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'name': name,
        'url': trimmedUrl,
        'scriptId': isScriptId ? extractedId : '',
        'sheetId': !isScriptId ? extractedId : '',
        'createdAt': DateTime.now().toIso8601String(),
        'storeVersion': _currentStoreVersion,
        'isLegacy': false,
      };

      _stores.add(newStore);
      await _box.put(_storesKey, _stores);

      _logger?.info('✅ Store added with ID: ${newStore['id']}');

      final storeId = newStore['id']?.toString();
      if (storeId != null && storeId.isNotEmpty) {
        await setActiveStore(storeId);
      } else {
        _logger?.error('❌ Failed to get store ID after creation', 'Store ID is null or empty');
      }
    } catch (e) {
      _logger?.error('Error adding store', e.toString());
      rethrow;
    }
  }

  Future<void> setActiveStore(String storeId) async {
    _logger?.info('🔄 StoreManager.setActiveStore() called with storeId: $storeId');

    try {
      if (_syncService != null) {
        _syncService!.dispose();
        _syncService = null;
      }

      final store = _stores.firstWhere((s) => s['id'] == storeId);
      _activeStore = store;
      await _box.put(_activeStoreKey, storeId);

      _logger?.info('  ✅ Active store set to: ${store['name']}');

      String storeIdentifier = store['sheetId']?.toString() ?? '';

      if (storeIdentifier.isEmpty) {
        storeIdentifier = store['scriptId']?.toString() ?? '';
      }

      if (storeIdentifier.isEmpty) {
        storeIdentifier = _extractIdFromUrl(store['url'] ?? '');
        if (storeIdentifier.isNotEmpty) {
          if (storeIdentifier.startsWith('AKfy')) {
            store['scriptId'] = storeIdentifier;
          } else {
            store['sheetId'] = storeIdentifier;
          }
          await _box.put(_storesKey, _stores);
        }
      }

      if (storeIdentifier.isEmpty) {
        _logger?.error('❌ No valid identifier for store', 'Missing identifier');
        notifyListeners();
        return;
      }

      _logger?.info('  🔑 Using store identifier: $storeIdentifier');

      final googleSheetsService = GoogleSheetsService(
        masterScriptUrl: _masterScriptUrl,
        storeIdentifier: storeIdentifier,
        logger: _logger,
      );

      offlineStorage.setGoogleSheetsService(googleSheetsService, storeIdentifier);

      await offlineStorage.switchStore(storeId);

      _logger?.info('✅ Store activation complete');
      notifyListeners();
    } catch (e) {
      _logger?.error('Error setting active store', e.toString());
      rethrow;
    }
  }

  Future<void> updateStoreSheetId(String storeId, String sheetId) async {
    _logger?.info('🔄 Updating sheet ID for store: $storeId to: $sheetId');

    try {
      final index = _stores.indexWhere((s) => s['id'] == storeId);
      if (index == -1) return;

      _stores[index]['sheetId'] = sheetId;
      _stores[index]['isLegacy'] = false;
      _stores[index]['lastUpdated'] = DateTime.now().toIso8601String();

      await _box.put(_storesKey, _stores);

      if (_activeStore?['id'] == storeId) {
        _activeStore = _stores[index];
      }

      notifyListeners();
    } catch (e) {
      _logger?.error('Error updating store sheet ID', e.toString());
      rethrow;
    }
  }

  Future<void> removeStore(String storeId) async {
    _logger?.info('🗑️ Removing store: $storeId');

    try {
      _stores.removeWhere((s) => s['id'] == storeId);
      await _box.put(_storesKey, _stores);

      if (_activeStore?['id'] == storeId) {
        _syncService?.dispose();
        _syncService = null;
        _activeStore = null;
        await _box.delete(_activeStoreKey);

        final emptyService = GoogleSheetsService(
          masterScriptUrl: '',
          storeIdentifier: '',
          logger: _logger,
        );
        offlineStorage.setGoogleSheetsService(emptyService, '');
      }

      notifyListeners();
    } catch (e) {
      _logger?.error('Error removing store', e.toString());
      rethrow;
    }
  }

  Future<void> refreshActiveStore() async {
    if (_activeStore == null) return;
    await setActiveStore(_activeStore!['id']);
  }

  Map<String, dynamic> getStoreStatus(String storeId) {
    final store = getStoreById(storeId);
    if (store == null) return {};

    return {
      'id': storeId,
      'name': store['name'],
      'isLegacy': store['isLegacy'] ?? false,
      'hasSheetId': (store['sheetId']?.toString() ?? '').isNotEmpty,
      'hasScriptId': (store['scriptId']?.toString() ?? '').isNotEmpty,
      'identifier': store['sheetId']?.toString() ?? store['scriptId']?.toString() ?? 'none',
    };
  }

  @override
  void dispose() {
    _syncService?.dispose();
    _box.close();
    super.dispose();
  }
}