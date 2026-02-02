import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

class StoreManager with ChangeNotifier {
  static const String _globalBoxName = 'global_app_config';
  static const String _activeStoreKey = 'active_store_id';
  static const String _storesKey = 'saved_stores';

  late Box _box;
  bool _initialized = false;

  Map<String, dynamic>? _activeStore;
  List<Map<String, dynamic>> _stores = [];

  bool get isInitialized => _initialized;
  Map<String, dynamic>? get activeStore => _activeStore;
  List<Map<String, dynamic>> get stores => _stores;

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
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'name': name,
      'url': url.trim(),
    };

    _stores.add(newStore);
    await _box.put(_storesKey, _stores);

    // FIX IS HERE: Add the '!'
    await setActiveStore(newStore['id']!);
  }

  Future<void> setActiveStore(String storeId) async {
    final store = _stores.firstWhere((s) => s['id'] == storeId);
    _activeStore = store;
    await _box.put(_activeStoreKey, storeId);
    notifyListeners();
  }

  Future<void> removeStore(String storeId) async {
    _stores.removeWhere((s) => s['id'] == storeId);
    await _box.put(_storesKey, _stores);

    if (_activeStore?['id'] == storeId) {
      _activeStore = null;
      await _box.delete(_activeStoreKey);
    }
    notifyListeners();
  }
}