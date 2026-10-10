// logger_service.dart
//
// Central logging for the app.
//
// Two independent channels:
//   1. Console  — everything at or above `_printThreshold`.
//   2. Hive     — everything at or above `_persistThreshold` (encrypted).
//
// In release, only warnings and errors reach either channel. In debug,
// `debug()` messages print to the console but are never persisted, so a
// hot loop can log freely without wearing out flash storage.
//
// Logging must never throw. Every disk path is wrapped, and `_init()` is
// single-flight so concurrent callers cannot race `Hive.openBox`.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';

import 'encryption_service.dart';

enum LogLevel { debug, info, warning, error }

class LoggerService {
  static const String _boxName = 'app_logs';

  /// Max entries retained on disk. Every extra row is a Hive write.
  static const int _maxEntries = 1000;

  /// Nothing below this level is written to disk.
  /// Release keeps only warning/error so routine progress doesn't wear flash.
  static final LogLevel _persistThreshold =
  kReleaseMode ? LogLevel.warning : LogLevel.info;

  /// Nothing below this level is printed to the console.
  /// Release: warning+. Debug: debug+.
  static final LogLevel _printThreshold =
  kReleaseMode ? LogLevel.warning : LogLevel.debug;

  /// HH:mm:ss formatter is created once, not per log line.
  static final DateFormat _timeFormat = DateFormat('HH:mm:ss');

  Box? _box;
  Future<void>? _initFuture;

  /// Optional hook for tests, crash reporters, or in-app log viewers.
  /// Called synchronously on the calling isolate. Must not throw.
  void Function(LogLevel level, String line)? onLog;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Opens the encrypted log box. Safe to call multiple times and from
  /// concurrent callers; only the first call performs the open.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      final encryptionKey = await EncryptionService.getEncryptionKey();
      _box = await Hive.openBox(
        _boxName,
        encryptionCipher: HiveAesCipher(encryptionKey),
      );
    } catch (_) {
      // Test environments, corrupted box, or encryption unavailable:
      // fall back to console-only logging instead of failing startup.
      _box = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Routine informational message. Persisted in debug; suppressed in release.
  Future<void> info(String message) => _log(LogLevel.info, message);

  /// Recoverable problem worth keeping around. Persisted in release too.
  Future<void> warning(String message) => _log(LogLevel.warning, message);

  /// Failure. Persisted in release too. `error` is appended to `message`
  /// when supplied.
  Future<void> error(String message, [dynamic error]) {
    final msg = error == null ? message : '$message | $error';
    return _log(LogLevel.error, msg);
  }

  /// Console-only, never persisted. Intended for hot paths, chunk loops,
  /// and diagnostics that would flood the on-disk log. Stripped in release.
  void debug(String tag, String message) {
    if (LogLevel.debug.index < _printThreshold.index) return;
    final line = '[${_time()}] DEBUG $tag: $message';
    debugPrint(line);
    _emit(LogLevel.debug, line);
  }

  /// Newest first. Empty list when the box is unavailable.
  List<String> getLogs() {
    final box = _box;
    if (box == null) return const <String>[];
    return box.values.cast<String>().toList().reversed.toList(growable: false);
  }

  Future<void> clearLogs() async {
    try {
      await _box?.clear();
    } catch (_) {
      // Clearing is best-effort.
    }
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<void> _log(LogLevel level, String message) async {
    if (level.index < _printThreshold.index) return;

    final line = '[${_time()}] ${level.name.toUpperCase()}: $message';
    debugPrint(line);
    _emit(level, line);

    if (level.index < _persistThreshold.index) return;

    try {
      if (_box == null) await init();
      final box = _box;
      if (box == null) return; // init failed; console-only.

      await box.add(line);

      final overflow = box.length - _maxEntries;
      if (overflow > 0) {
        // Trim in one batch using real Hive keys. `deleteAt(0)` would assume
        // key 0 is oldest, which is not guaranteed after clear()/reuse.
        final oldest = box.keys.take(overflow).toList(growable: false);
        if (oldest.isNotEmpty) {
          await box.deleteAll(oldest);
        }
      }
    } catch (_) {
      // Logging must never crash the app.
    }
  }

  void _emit(LogLevel level, String line) {
    final hook = onLog;
    if (hook == null) return;
    try {
      hook(level, line);
    } catch (_) {
      // A misbehaving hook must not break logging.
    }
  }

  String _time() => _timeFormat.format(DateTime.now());
}