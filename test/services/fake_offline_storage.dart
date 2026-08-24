// test/services/fake_offline_storage.dart
class FakeOfflineStorage {
  bool isReady = true;
  String? currentStoreId;
  List<Map<String, dynamic>> pendingCounts = [];

  Future<void> init() async {}
  Future<void> switchStore(String storeId) async {}
  Future<List<Map<String, dynamic>>> getPendingLocations() async => [];
  Future<List<Map<String, dynamic>>> getPendingNewProducts() async => [];
  Future<void> markLocationsAsSynced(List<String> ids) async {}
  Future<void> markNewProductsAsSynced(List<String> barcodes) async {}
  Future<void> markMultipleAsSynced(List<String> ids) async {}
  Future<Map<String, int>> getDatabaseStats() async => {'pendingSync': 0};
}