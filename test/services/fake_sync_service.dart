// test/services/fake_sync_service.dart
import 'fake_offline_storage.dart';
import 'fake_google_sheets_service.dart';
import 'fake_logger_service.dart';

class FakeSyncService {
  final FakeOfflineStorage offlineStorage;
  final FakeGoogleSheetsService googleSheets;
  final FakeLoggerService logger;

  bool _isDisposed = false;
  bool isSyncing = false;
  String lastSyncTime = '';
  int lastSyncCount = 0;
  bool inventoryLoaded = false;
  String? lastError;

  FakeSyncService({
    required this.offlineStorage,
    required this.googleSheets,
    required this.logger,
  });

  Future<void> syncAll() async {
    if (_isDisposed) throw Exception('Service disposed');
    isSyncing = true;
    await Future.delayed(Duration(milliseconds: 100));
    isSyncing = false;
  }

  void dispose() {
    _isDisposed = true;
  }
}