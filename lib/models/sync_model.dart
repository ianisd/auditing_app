import 'package:flutter/foundation.dart';

/// 🔥 Single source of truth for sync status
/// Any screen can watch this instead of recomputing pending counts
class SyncStatus extends ChangeNotifier {
  int _pendingCount = 0;
  Map<String, int> _pendingBreakdown = const {
    'invoices': 0,
    'purchases': 0,
    'pluMappings': 0,
    'stockCounts': 0,
    'total': 0,
  };
  bool _isSyncing = false;
  String _lastSyncTime = '';
  int _lastSyncCount = 0;

  int get pendingCount => _pendingCount;
  Map<String, int> get pendingBreakdown => _pendingBreakdown;
  bool get isSyncing => _isSyncing;
  String get lastSyncTime => _lastSyncTime;
  int get lastSyncCount => _lastSyncCount;

  /// 🔥 Set pending counts from detailed breakdown
  void setPendingCounts(Map<String, int> breakdown) {
    final total = breakdown['total'] ?? 0;
    if (_pendingCount != total || !_mapEquals(_pendingBreakdown, breakdown)) {
      _pendingCount = total;
      _pendingBreakdown = Map.unmodifiable(breakdown);
      notifyListeners();
    }
  }

  void setSyncing(bool syncing) {
    if (_isSyncing != syncing) {
      _isSyncing = syncing;
      if (!syncing) {
        _lastSyncTime = _formatDateTime(DateTime.now());
      }
      notifyListeners();
    }
  }

  void setLastSync(String time, int count) {
    _lastSyncTime = time;
    _lastSyncCount = count;
    notifyListeners();
  }

  void setError(String? error) {
    // Add error handling if needed
    notifyListeners();
  }

  void reset() {
    _pendingCount = 0;
    _pendingBreakdown = const {
      'invoices': 0,
      'purchases': 0,
      'pluMappings': 0,
      'stockCounts': 0,
      'total': 0,
    };
    _isSyncing = false;
    _lastSyncTime = '';
    _lastSyncCount = 0;
    notifyListeners();
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')} ${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }

  bool _mapEquals(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (var key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}
