import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_service.dart';
import 'fake_offline_storage.dart';
import 'fake_google_sheets_service.dart';
import 'fake_logger_service.dart';

void main() {
  group('SyncService disposal safety', () {
    test('does not crash when disposed during sync', () async {
      final storage = FakeOfflineStorage();
      final sheets = FakeGoogleSheetsService()..syncDelayMs = 200;
      final logger = FakeLoggerService();

      final service = FakeSyncService(
        offlineStorage: storage,
        googleSheets: sheets,
        logger: logger,
      );

      // Start sync then immediately dispose
      final future = service.syncAll();
      await Future.delayed(Duration(milliseconds: 50));
      service.dispose();

      // Should complete without crash
      await future;
      expect(service.isSyncing, isFalse);
    });

    test('throws when used after disposal', () async {
      final service = FakeSyncService(
        offlineStorage: FakeOfflineStorage(),
        googleSheets: FakeGoogleSheetsService(),
        logger: FakeLoggerService(),
      );

      service.dispose();

      expect(() => service.syncAll(), throwsA(isA<Exception>()));
    });
  });
}