// lib/models/sync_model.dart
import 'package:flutter/foundation.dart';

// Remove the SyncResult class from here, we'll define it in sync_service.dart
// Or keep it as a base class and extend it

class SyncStatus with ChangeNotifier {
  bool _isSyncing = false;
  String _lastSyncTime = '';
  int _pendingCount = 0;
  String? _lastError;

  bool get isSyncing => _isSyncing;
  String get lastSyncTime => _lastSyncTime;
  int get pendingCount => _pendingCount;
  String? get lastError => _lastError;

  void setSyncing(bool syncing) {
    _isSyncing = syncing;
    if (!syncing) {
      _lastSyncTime = _formatDateTime(DateTime.now());
    }
    notifyListeners();
  }

  void setPendingCount(int count) {
    _pendingCount = count;
    notifyListeners();
  }

  void setError(String? error) {
    _lastError = error;
    notifyListeners();
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')} ${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }
}