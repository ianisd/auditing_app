import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';

class LoggerService {
  static const String _boxName = 'app_logs';
  Box? _box;

  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  // Log an info message (e.g., "Saved Count: Whiskey")
  Future<void> info(String message) async {
    await _log('INFO', message);
  }

  // Log an error (e.g., "Sync Failed: 404")
  Future<void> error(String message, [dynamic error]) async {
    final msg = error != null ? '$message | $error' : message;
    await _log('ERROR', msg);
  }

  Future<void> _log(String type, String message) async {
    if (_box == null) await init();

    final timestamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final logEntry = '[$timestamp] $type: $message';

    print(logEntry); // Print to console for development

    // Save to Hive (Auto-incrementing key)
    // We limit logs to last 1000 entries to save space
    if (_box!.length > 1000) {
      await _box!.deleteAt(0);
    }
    await _box!.add(logEntry);
  }

  List<String> getLogs() {
    if (_box == null) return [];
    // Return reversed so newest is at top
    return _box!.values.cast<String>().toList().reversed.toList();
  }

  Future<void> clearLogs() async {
    if (_box != null) await _box!.clear();
  }
}