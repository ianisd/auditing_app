// test/services/fake_logger_service.dart

/// Fake logger that does nothing (avoids Hive/path_provider entirely)
// test/services/fake_logger_service.dart
class FakeLoggerService {
  Future<void> init() async {}
  Future<void> info(String message) async {}
  Future<void> error(String message, [dynamic error]) async {}
  List<String> getLogs() => [];
  Future<void> clearLogs() async {}
  void dispose() {}
}