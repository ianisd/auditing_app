// test/services/fake_google_sheets_service.dart

// test/services/fake_google_sheets_service.dart
class FakeGoogleSheetsService {
  bool syncSuccess = true;
  int syncDelayMs = 0;

  Future<bool> syncStockCounts(List<Map<String, dynamic>> counts) async {
    if (syncDelayMs > 0) await Future.delayed(Duration(milliseconds: syncDelayMs));
    return syncSuccess;
  }

  Future<bool> syncNewProducts(List<Map<String, dynamic>> products) async => syncSuccess;
  Future<bool> syncNewLocations(List<Map<String, dynamic>> locations) async => syncSuccess;

  Future<List<Map<String, dynamic>>> fetchInventory() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchLocations() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchAudits() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchStockCounts() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchPurchases() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchStoreSalesData() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchItemSales() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchMasterProducts() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchMasterBarcodes() => Future.value([]);
  Future<List<Map<String, dynamic>>> fetchComputedCosts() => Future.value([]);
}