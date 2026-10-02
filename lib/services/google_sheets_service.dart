import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'logger_service.dart';

// ============================================================================
// UTILITY: Safe Date Handling
// ============================================================================

class SafeDateUtils {
  /// Safe date parsing from various formats (ISO-8601, dd/MM/yyyy, timestamps)
  static DateTime? parseDate(dynamic value) {
    if (value == null) return null;

    if (value is DateTime) {
      return value;
    }

    if (value is String) {
      final clean = value.trim();
      if (clean.isEmpty) return null;

      try {
        return DateTime.parse(clean);
      } catch (_) {
        // Fallback: parse dd/MM/yyyy, dd-MM-yyyy, or yyyy-MM-dd
        final parts = clean.split(RegExp(r'[/.\s-]+'));
        if (parts.length >= 3) {
          final p1 = int.tryParse(parts[0]);
          final p2 = int.tryParse(parts[1]);
          final p3 = int.tryParse(parts[2]);
          if (p1 != null && p2 != null && p3 != null) {
            if (p3 > 1000) {
              // Format: DD/MM/YYYY or DD-MM-YYYY
              return DateTime.utc(p3, p2, p1);
            } else if (p1 > 1000) {
              // Format: YYYY/MM/DD or YYYY-MM-DD
              return DateTime.utc(p1, p2, p3);
            }
          }
        }
        return null;
      }
    }

    if (value is int) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  /// Safely sort a list by date field
  static void sortByDate<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter,
  ) {
    items.sort((a, b) {
      final dateA = dateGetter(a);
      final dateB = dateGetter(b);

      if (dateA == null && dateB == null) return 0;
      if (dateA == null) return 1; // nulls last
      if (dateB == null) return -1; // nulls last

      return dateA.compareTo(dateB);
    });
  }

  /// Get valid dates (non-null) from a list
  static List<DateTime> getValidDates<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter,
  ) {
    return items
        .map(dateGetter)
        .where((d) => d != null)
        .cast<DateTime>()
        .toList();
  }

  /// Get the earliest valid date
  static DateTime? getEarliestDate<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter,
  ) {
    final dates = getValidDates(items, dateGetter);
    if (dates.isEmpty) return null;
    return dates.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  /// Get the latest valid date
  static DateTime? getLatestDate<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter,
  ) {
    final dates = getValidDates(items, dateGetter);
    if (dates.isEmpty) return null;
    return dates.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  /// Get date range as string
  static String getDateRangeString<T>(
    List<T> items,
    DateTime? Function(T item) dateGetter, {
    String format = 'yyyy-MM-dd',
    String fallback = 'No dates available',
  }) {
    final dates = getValidDates(items, dateGetter);
    if (dates.isEmpty) return fallback;

    dates.sort();
    final first = dates.first;
    final last = dates.last;

    if (first == last) {
      return _formatDate(first, format);
    }
    return '${_formatDate(first, format)} - ${_formatDate(last, format)}';
  }

  static String _formatDate(DateTime date, String format) {
    switch (format) {
      case 'yyyy-MM-dd':
        return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      case 'dd/MM/yyyy':
        return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
      case 'MM/dd/yyyy':
        return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}';
      default:
        return date.toIso8601String().split('T').first;
    }
  }
}

// ============================================================================
// Top-level functions for compute() isolate
// ============================================================================

List<Map<String, dynamic>> _parseBatchData(List<dynamic> data) {
  return data.map((item) => Map<String, dynamic>.from(item)).toList();
}

class _Semaphore {
  int _available;
  final _waiters = <Completer<void>>[];

  _Semaphore(this._available);

  Future<void> acquire() async {
    if (_available > 0) {
      _available--;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _available++;
    }
  }
}

// ============================================================================
// GoogleSheetsService
// ============================================================================

class GoogleSheetsService {
  final String masterScriptUrl;
  final String storeIdentifier;
  final LoggerService? logger;
  final http.Client Function()? _clientFactory;
  List<Map<String, dynamic>>? _cachedMasterSuppliers;

  final Map<String, _VerifiedDownload> _verifiedDownloads = {};
  final Map<String, _PendingDownload> _refreshCandidates = {};
  final Map<String, _PendingDownload> _pendingVerification = {};
  final Map<String, List<Map<String, dynamic>>> _salesBlocks = {};
  Map<String, String> _refreshVersions = {},
      _refreshRowHashes = {},
      _knownMissingTables = {};
  _SalesBlockPlan? _salesPlan;
  bool _versionedRefreshActive = false;
  bool _forceVersionedDownload = false;
  final Set<String> _reusedRefreshTables = {};

  Set<String> get reusedRefreshTables => Set.unmodifiable(_reusedRefreshTables);
  final Map<String, String> _bundleErrors = {};

  Map<String, String> get bundleErrors => Map.unmodifiable(_bundleErrors);

  List<Map<String, dynamic>> _copyDownload(List<Map<String, dynamic>> rows) =>
      (json.decode(json.encode(rows)) as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();

  bool _isReadTransportFailure(Object e) =>
      e is SocketException ||
      e is http.ClientException ||
      e is TimeoutException ||
      e is _RedirectFailure ||
      (e is _HttpReadFailure &&
          (e.status == 404 ||
              e.status == 408 ||
              e.status == 429 ||
              e.status >= 500));

  Future<_RefreshManifest> _fetchRefreshManifest(
    List<String> tables, {
    bool retry = false,
  }) async {
    final generation = _cancelGeneration, watch = Stopwatch()..start();
    final attempts = retry ? 2 : 1;
    for (int attempt = 1; attempt <= attempts; attempt++) {
      _checkFetchActive(generation);
      final remaining = 60 - (watch.elapsedMilliseconds / 1000).ceil();
      if (remaining < 1)
        throw TimeoutException('Manifest verification budget exhausted');
      try {
        var uri = _tableUri('_manifest', 0, 1, attempt > 1);
        uri = uri.replace(
          queryParameters: {...uri.queryParameters, 'tables': tables.join(',')},
        );
        final response = await _getWithBoundedRedirects(
          uri,
          timeoutSeconds: remaining,
        );
        _checkFetchActive(generation);
        final decoded = _decodeGetResponse(response);
        if (decoded is! Map ||
            decoded['protocol'] != 1 ||
            decoded['versions'] is! Map) {
          throw const FormatException('Version manifest is unavailable');
        }
        final versions = <String, String>{},
            rowHashes = <String, String>{},
            missing = <String, String>{};
        final raw = decoded['versions'] as Map, errors = decoded['errors'];
        final codes = decoded['errorCodes'];
        final rawHashes = decoded['hashProtocol'] == 'hola-rows-v1'
            ? decoded['rowHashes']
            : null;
        for (final table in tables) {
          if (errors is Map && errors.containsKey(table)) {
            if (codes is Map && codes[table] == 'TABLE_NOT_FOUND')
              missing[table] = errors[table].toString();
            continue;
          }
          final value = raw[table];
          if (value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value))
            versions[table] = value;
          final hash = rawHashes is Map ? rawHashes[table] : null;
          if (hash is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))
            rowHashes[table] = hash;
        }
        final rawBlocks = decoded['blocks'];
        final sales = versions.containsKey('StoreSalesData') && rawBlocks is Map
            ? _SalesBlockPlan.parse(
                rawBlocks['StoreSalesData'],
                rowHashes['StoreSalesData'],
              )
            : null;
        logger?.info(
          'Refresh manifest: ${versions.length}/${tables.length} tables; server_ms=${decoded['serverMs']}; table_ms=${decoded['tableMs']}',
        );
        return _RefreshManifest(versions, rowHashes, missing, sales);
      } catch (e) {
        _checkFetchActive(generation);
        if (attempt == attempts ||
            !_isReadTransportFailure(e) ||
            watch.elapsedMilliseconds >= 58000)
          rethrow;
        logger?.info(
          'Retrying verification metadata only; downloaded rows retained: $e',
        );
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    throw StateError('No manifest response');
  }

  Future<void> beginVersionedRefresh(
    List<String> tables, {
    bool forceFullDownload = false,
  }) async {
    if (_versionedRefreshActive)
      throw StateError('A versioned refresh is already active');
    final generation = _cancelGeneration;
    _checkFetchActive(generation);
    _versionedRefreshActive = true;
    _forceVersionedDownload = forceFullDownload;
    _refreshCandidates.clear();
    _refreshVersions.clear();
    _refreshRowHashes.clear();
    _knownMissingTables.clear();
    _salesPlan = null;
    _reusedRefreshTables.clear();
    _cache.clear();
    try {
      final manifest = await _fetchRefreshManifest(tables);
      _checkFetchActive(generation);
      _refreshVersions = manifest.versions;
      _refreshRowHashes = manifest.rowHashes;
      _knownMissingTables = manifest.missing;
      _salesPlan = manifest.sales;
      // Recovery requires an actual hash of the retained rows matching current
      // server rows. A before/after source-version match alone is insufficient.
      for (final table in tables) {
        final pending = _pendingVerification[table],
            version = _refreshVersions[table];
        if (pending != null &&
            version != null &&
            _refreshRowHashes[table] == pending.rowHash) {
          _verifiedDownloads[table] = _VerifiedDownload(
            version,
            pending.rows,
            pending.rowHash,
          );
          _pendingVerification.remove(table);
          logger?.info(
            'Refresh $table recovered verification: retained rows match current server content',
          );
        }
      }
    } catch (e) {
      _checkFetchActive(generation);
      // Keep old rows as candidates, but no current manifest means no reuse.
      logger?.info('Version check unavailable; downloading normally: $e');
    }
  }

  void _checkKnownMissing(String table) {
    if (_versionedRefreshActive && _knownMissingTables.containsKey(table)) {
      throw _GasReadError(_knownMissingTables[table]!, 'TABLE_NOT_FOUND');
    }
  }

  String _hashLabel(String? value) =>
      value == null ? 'none' : value.substring(0, math.min(12, value.length));

  List<Map<String, dynamic>>? _reuseVerifiedDownload(String table) {
    if (!_versionedRefreshActive) return null;
    final entry = _verifiedDownloads[table];
    final version = _refreshVersions[table], hash = _refreshRowHashes[table];
    String? reason;
    if (_forceVersionedDownload)
      reason = 'forced download';
    else if (version == null)
      reason = 'no current server version';
    else if (entry == null)
      reason = 'no verified raw snapshot';
    else if (entry.version != version)
      reason = 'server version changed';
    else if (hash != null && entry.rowHash != hash)
      reason = 'content checksum differs';
    if (reason != null) {
      logger?.info(
        'Refresh $table cache miss: $reason; cached_rows=${entry?.rows.length ?? 0}; '
        'version=${_hashLabel(entry?.version)} -> ${_hashLabel(version)}; '
        'content=${_hashLabel(entry?.rowHash ?? _pendingVerification[table]?.rowHash)} -> ${_hashLabel(hash)}',
      );
      return null;
    }
    _reusedRefreshTables.add(table);
    logger?.info(
      'Refresh $table unchanged: reusing ${entry!.rows.length} verified downloaded rows',
    );
    return _copyDownload(entry!.rows);
  }

  Future<void> _rememberRefreshDownload(
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    if (!_versionedRefreshActive || !_refreshVersions.containsKey(table))
      return;
    final generation = _cancelGeneration;
    final copy = _copyDownload(rows);
    final hashes = await compute(_downloadHashes, copy);
    _checkFetchActive(generation);
    final pending = _PendingDownload(copy, hashes);
    if (_refreshRowHashes[table] == pending.rowHash) {
      _verifiedDownloads[table] = _VerifiedDownload(
        _refreshVersions[table]!,
        copy,
        pending.rowHash,
      );
      _pendingVerification.remove(table);
      _refreshCandidates.remove(table);
    } else {
      logger?.info(
        'Refresh $table content verification pending: rows=${rows.length}; '
        'received=${_hashLabel(pending.rowHash)}; manifest=${_hashLabel(_refreshRowHashes[table])}',
      );
      _refreshCandidates[table] = pending;
      _pendingVerification[table] = pending;
    }
  }

  Future<void> finishVersionedRefresh() async {
    final generation = _cancelGeneration;
    try {
      _checkFetchActive(generation);
      if (!_versionedRefreshActive || _refreshCandidates.isEmpty) return;
      final after = await _fetchRefreshManifest(
        _refreshCandidates.keys.toList(),
        retry: true,
      );
      _checkFetchActive(generation);
      for (final entry in _refreshCandidates.entries) {
        final version = after.versions[entry.key],
            actualHash = after.rowHashes[entry.key];
        final matches = actualHash != null
            ? actualHash == entry.value.rowHash
            : version != null &&
                  version ==
                      _refreshVersions[entry
                          .key]; // Older GAS compatibility only.
        if (version != null && matches) {
          _verifiedDownloads[entry.key] = _VerifiedDownload(
            version,
            entry.value.rows,
            entry.value.rowHash,
          );
          _pendingVerification.remove(entry.key);
        } else {
          logger?.info(
            'Refresh ${entry.key}: retained completed rows for a later content check; not marked verified',
          );
        }
      }
    } catch (e) {
      _checkFetchActive(generation);
      logger?.info(
        'Downloads saved; verification unavailable. Completed rows retained for a later content check: $e',
      );
    } finally {
      abortVersionedRefresh();
    }
  }

  void abortVersionedRefresh() {
    _versionedRefreshActive = false;
    _refreshCandidates.clear();
    _refreshVersions.clear();
    _refreshRowHashes.clear();
    _knownMissingTables.clear();
    _salesPlan = null;
  }

  Future<List<Map<String, dynamic>>> _downloadSalesBlocks(
    _SalesBlockPlan plan,
    int timeoutSeconds,
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  ) async {
    final generation = _cancelGeneration;
    final wanted = plan.hashes.toSet();
    _salesBlocks.removeWhere((hash, _) => !wanted.contains(hash));
    // Seed from the prior whole download when upgrading from full pagination.
    for (final source in [
      _verifiedDownloads['StoreSalesData']?.rows,
      _pendingVerification['StoreSalesData']?.rows,
    ]) {
      if (source == null) continue;
      final hashes = await compute(_downloadHashes, source);
      _checkFetchActive(generation);
      for (int index = 0; index < hashes.length; index++) {
        if (wanted.contains(hashes[index]) &&
            !_salesBlocks.containsKey(hashes[index])) {
          _salesBlocks[hashes[index]] = _copyDownload(
            source.sublist(
              index * 1500,
              math.min((index + 1) * 1500, source.length),
            ),
          );
        }
      }
    }
    final rows = <Map<String, dynamic>>[];
    int reused = 0, downloaded = 0;
    for (int index = 0; index < plan.hashes.length; index++) {
      _checkFetchActive(generation);
      final hash = plan.hashes[index];
      final expectedLength = math.min(1500, plan.total - index * 1500);
      List<Map<String, dynamic>>? block = _forceVersionedDownload
          ? null
          : _salesBlocks[hash];
      if (block != null &&
          (block.length != expectedLength ||
              _downloadBlockHash(block) != hash)) {
        _salesBlocks.remove(hash);
        block = null;
      }
      if (block != null) {
        reused++;
      } else {
        onStatus?.call(
          'Downloading changed sales block ${index + 1}/${plan.hashes.length}',
        );
        for (int attempt = 1; attempt <= 3; attempt++) {
          _checkFetchActive(generation);
          try {
            if (_circuitBreakerOpen) {
              await Future.delayed(resetTimeout);
              _checkFetchActive(generation);
              _resetCircuitBreaker();
            }
            final candidate = await _fetchVerifiedSalesBlock(
              plan,
              index,
              attempt,
              timeoutSeconds,
            );
            _checkFetchActive(generation);
            block = candidate;
            _salesBlocks[hash] = _copyDownload(candidate);
            downloaded++;
            break;
          } catch (e) {
            _checkFetchActive(generation);
            if (!_isReadTransportFailure(e)) rethrow;
            _recordFailure();
            if (attempt == 3) rethrow;
            logger?.info(
              'Sales block $index retry $attempt/3 at offset ${index * 1500}; '
              'verified blocks retained; trying ordinary page at the same offset: $e',
            );
            await Future.delayed(Duration(seconds: attempt * 2));
          }
        }
      }
      if (block == null) throw StateError('Sales block was not received');
      rows.addAll(_copyDownload(block));
      onProgress?.call(rows.length, plan.total);
    }
    if (rows.length != plan.total)
      throw const FormatException('Incomplete sales reconstruction');
    await _rememberRefreshDownload('StoreSalesData', rows);
    _checkFetchActive(generation);
    if (_downloadTableHash(rows.length, await compute(_downloadHashes, rows)) !=
        plan.tableHash) {
      throw const FormatException('Sales table checksum mismatch');
    }
    _checkFetchActive(generation);
    logger?.info(
      'Sales blocks: reused=$reused downloaded=$downloaded total=${plan.hashes.length}; assembled ${rows.length} rows',
    );
    _salesBlocks
        .clear(); // Complete raw snapshot is now the donor for the next refresh.
    _salesBlocks.clear(); // Completed raw snapshot now supplies future blocks.
    return rows;
  }

  /// Both endpoints must return the exact block described by this refresh's manifest.
  /// A transport fallback changes only the endpoint, never the offset or checksum.
  Future<List<Map<String, dynamic>>> _fetchVerifiedSalesBlock(
    _SalesBlockPlan plan,
    int index,
    int attempt,
    int timeoutSeconds,
  ) async {
    final generation = _cancelGeneration;
    final offset = index * 1500;
    final expectedLength = math.min(1500, plan.total - offset);
    final hash = plan.hashes[index];
    List<Map<String, dynamic>> candidate;
    logger?.info(
      'Sales block $index/$attempt: offset=$offset route=${attempt == 1 ? "block" : "page"} expected_total=${plan.total}',
    );
    if (attempt == 1) {
      var uri = _tableUri('_salesBlock', offset, 1500, false);
      uri = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'index': '$index',
          'expectedHash': hash,
          'expectedTotal': '${plan.total}',
        },
      );
      final response = await _getWithBoundedRedirects(
        uri,
        timeoutSeconds: timeoutSeconds,
      );
      _checkFetchActive(generation);
      final decoded = _decodeGetResponse(response);
      if (decoded is! Map ||
          decoded['protocol'] != 1 ||
          decoded['index'] != index ||
          decoded['total'] != plan.total ||
          decoded['hash'] != hash ||
          decoded['data'] is! List) {
        throw const FormatException(
          'Invalid sales block response; completed blocks retained',
        );
      }
      candidate = await _parseSmart(decoded['data'] as List);
    } else {
      final page = await _fetchBatchPage(
        'StoreSalesData',
        offset: offset,
        limit: 1500,
        timeoutSeconds: timeoutSeconds,
        useAlternativeUrl: true,
        attempt: attempt,
      );
      _checkFetchActive(generation);
      if (page.total != plan.total) {
        throw _GasReadError(
          'Sales total changed at offset $offset: manifest_total=${plan.total}, '
              'received_total=${page.total}; refresh again to rebuild the block plan',
          'SOURCE_CHANGED',
        );
      }
      candidate = page.rows;
    }
    _checkFetchActive(generation);
    final hashes = await compute(_downloadHashes, candidate);
    _checkFetchActive(generation);
    if (candidate.length != expectedLength ||
        hashes.length != 1 ||
        hashes.single != hash) {
      throw _GasReadError(
        'Sales checksum/length mismatch at offset $offset: expected_rows=$expectedLength, '
            'received_rows=${candidate.length}; refresh again to check source changes',
        'SOURCE_CHANGED',
      );
    }
    return candidate;
  }

  String exportDownloadSnapshot() => json.encode({
    'protocol': 2,
    'store': storeIdentifier,
    'salesBlocks': _salesBlocks,
    'tables': {
      for (final e in _verifiedDownloads.entries) e.key: e.value.rows,
      for (final e in _pendingVerification.entries) e.key: e.value.rows,
    },
  });

  Future<void> restoreDownloadSnapshot(
    String? snapshot, {
    Map<String, List<Map<String, dynamic>>>? legacyRows,
  }) async {
    if (_versionedRefreshActive)
      throw StateError('Cannot restore during refresh');
    final generation = _cancelGeneration;
    Map tables = legacyRows ?? {};
    if (snapshot != null) {
      try {
        final decoded = json.decode(snapshot);
        if (decoded is Map &&
            decoded['protocol'] == 2 &&
            decoded['store'] == storeIdentifier &&
            decoded['tables'] is Map) {
          tables = decoded['tables'] as Map;
          final blocks = decoded['salesBlocks'];
          if (blocks is Map) {
            for (final entry in blocks.entries) {
              _checkFetchActive(generation);
              try {
                if (entry.key is! String ||
                    !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key as String) ||
                    entry.value is! List)
                  continue;
                final rows = _copyDownload(
                  (entry.value as List)
                      .map((v) => Map<String, dynamic>.from(v as Map))
                      .toList(),
                );
                if (rows.isEmpty || rows.length > 1500) continue;
                final hashes = await compute(_downloadHashes, rows);
                _checkFetchActive(generation);
                if (hashes.single == entry.key)
                  _salesBlocks.putIfAbsent(entry.key as String, () => rows);
              } catch (e) {
                _checkFetchActive(generation);
              }
            }
          }
        }
      } catch (_) {
        _checkFetchActive(generation);
        /* A damaged optimization cache is a cache miss. */
      }
    }
    for (final entry in tables.entries) {
      _checkFetchActive(generation);
      if (entry.key is! String ||
          entry.value is! List ||
          _verifiedDownloads.containsKey(entry.key) ||
          _pendingVerification.containsKey(entry.key))
        continue;
      try {
        final rows = _copyDownload(
          (entry.value as List)
              .map((v) => Map<String, dynamic>.from(v as Map))
              .toList(),
        );
        final hashes = await compute(_downloadHashes, rows);
        _checkFetchActive(generation);
        _pendingVerification[entry.key as String] = _PendingDownload(
          rows,
          hashes,
        );
      } catch (e) {
        _checkFetchActive(generation);
        logger?.info(
          'Ignoring unusable download cache for ${entry.key}: ${e.runtimeType}',
        );
      }
    }
  }

  // Cache for frequently accessed data
  final Map<String, _CacheEntry> _cache = {};
  static const Duration cacheDuration = Duration(minutes: 5);

  // Cancellation support
  int _cancelGeneration = 0;

  // 🔥 Circuit breaker for failure tracking
  int _consecutiveFailures = 0;
  DateTime? _lastFailureTime;
  static const int failureThreshold = 5;
  static const Duration resetTimeout = Duration(minutes: 1);

  // Pool of warm, idle clients for Keep-Alive reuse
  final List<http.Client> _clientPool = [];

  // Set of actively leased clients currently in flight
  final Set<http.Client> _leasedClients = {};
  bool _isDisposed = false;

  // 🔥 Redirect tracking
  static const int maxRedirects = 3;

  // Constants
  static const int defaultBatchSize = 1000;
  static const int largeBatchSize = 2500;
  static const int defaultTimeoutSeconds = 180;

  // Mutations must fail fast into pending state instead of occupying the transport for minutes.
  static const int postTimeoutSeconds = 30;
  static const int largeTableTimeoutSeconds = 300;
  static const int countTimeoutSeconds = 45;
  static const int maxFetchRetries = 6;
  static const int maxSyncRetries = 3;
  static const int chunkSize = 500;
  static const int computeThreshold = 500;

  // Reads and writes must never block each other. Keep each lane serialized,
  // but isolate a slow download from mutation traffic.
  static final _Semaphore _getRequestGate = _Semaphore(1);
  static final _Semaphore _postRequestGate = _Semaphore(1);

  GoogleSheetsService({
    required this.masterScriptUrl,
    required this.storeIdentifier,
    this.logger,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory;

  http.Client _createClient() {
    return _clientFactory?.call() ?? http.Client();
  }

  void _closeClient(http.Client client) {
    try {
      client.close();
    } catch (_) {}
  }

  /// Leases an idle warm client or instantiates a new one
  http.Client _leaseClient() {
    if (_clientPool.isNotEmpty) {
      final client = _clientPool.removeLast();
      _leasedClients.add(client);
      return client;
    }
    final client = _createClient();
    _leasedClients.add(client);
    return client;
  }

  /// Returns client to pool for reuse, or terminates it if broken/timed-out
  void _returnClient(http.Client client, {required bool discard}) {
    _leasedClients.remove(client);
    if (discard || _isDisposed) {
      _closeClient(client);
    } else {
      _clientPool.add(client);
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _verifiedDownloads.clear();
    _pendingVerification.clear();
    _salesBlocks.clear();
    abortVersionedRefresh();

    _cache.clear();

    for (final client in _clientPool) {
      _closeClient(client);
    }
    _clientPool.clear();

    for (final client in _leasedClients) {
      _closeClient(client);
    }
    _leasedClients.clear();
  }

  // ---------------------------------------------------------------------------
  // Circuit Breaker Methods
  // ---------------------------------------------------------------------------

  bool get _circuitBreakerOpen {
    if (_consecutiveFailures >= failureThreshold) {
      if (_lastFailureTime != null &&
          DateTime.now().difference(_lastFailureTime!) > resetTimeout) {
        _resetCircuitBreaker();
        return false;
      }
      return true;
    }
    return false;
  }

  void _recordFailure() {
    _consecutiveFailures++;
    _lastFailureTime = DateTime.now();
    if (_consecutiveFailures >= failureThreshold) {
      print('⛔ Circuit breaker OPEN - too many failures');
    }
  }

  void _recordSuccess() {
    if (_consecutiveFailures > 0) {
      _consecutiveFailures = 0;
      _lastFailureTime = null;
      print('✅ Circuit breaker RESET - success recorded');
    }
  }

  void _resetCircuitBreaker() {
    _consecutiveFailures = 0;
    _lastFailureTime = null;
    print('🔄 Circuit breaker manually RESET');
  }

  // ---------------------------------------------------------------------------
  // Adaptive Parse - Uses compute() only for large payloads
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _parseSmart(List<dynamic> data) async {
    if (data.length > computeThreshold) {
      return compute(_parseBatchData, data);
    }
    return _parseBatchData(data);
  }

  // ---------------------------------------------------------------------------
  // CORE: POST Request with Redirect Handling & Circuit Breaker
  // ---------------------------------------------------------------------------

  /// True when a nominally successful POST response is actually the GET
  /// table endpoint. This can happen if Google's redirected result URL sends a
  /// request back to /exec after POST has already been converted to GET.
  bool _isMisroutedPostResponse(Map<String, dynamic> result) {
    final raw = result['raw'];
    if (raw is! Map) return false;
    final error = raw['error']?.toString().trim().toLowerCase();
    return error == 'empty table name';
  }

  Future<Map<String, dynamic>> _sendPostRequest(
    String tag,
    Map<String, dynamic> jsonData,
  ) async {
    final endpoint = (jsonData['endpoint'] ?? tag).toString();
    final transactionId = (jsonData['transactionId'] ?? _generateUuid())
        .toString();
    late final String body;
    try {
      body = json.encode({
        'data': jsonData['data'],
        'storeIdentifier': storeIdentifier,
        'endpoint': endpoint,
        'table': jsonData['table'] ?? '',
        'transactionId': transactionId,
        'chunkIndex': jsonData['chunkIndex'] ?? 0,
        'chunkTotal': jsonData['chunkTotal'] ?? 1,
        'retry': 0,
      });
    } catch (e) {
      return {'success': false, 'code': 'INVALID_PAYLOAD', 'message': '$e'};
    }

    // A transport timeout has an UNKNOWN write outcome. Do not multiply/replay it.
    // Stable transaction IDs remain available for an explicit later retry. The only
    // automatic retry is LOCK_TIMEOUT, which is a definitive pre-commit rejection.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_isDisposed) {
        return {
          'success': false,
          'code': 'DISPOSED',
          'transactionId': transactionId,
          'message': 'Service disposed; unconfirmed work remains pending.',
        };
      }
      try {
        final response = await _postWithBoundedRedirects(
          Uri.parse(masterScriptUrl),
          timeoutSeconds: endpoint == 'syncPurchases'
              ? 120
              : postTimeoutSeconds,
          body: body,
          label: endpoint,
        );
        if (response.statusCode != 200) {
          return {
            'success': false,
            'code': 'HTTP_ERROR',
            'transactionId': transactionId,
            'message':
                'HTTP ${response.statusCode}; write outcome may be unknown.',
          };
        }
        final result = _parseSyncResponse(response.body.trim());
        if (_isMisroutedPostResponse(result)) {
          return {
            'success': false,
            'code': 'POST_ROUTE_MISMATCH',
            'transactionId': transactionId,
            'message':
                'Apps Script returned a GET response for a POST; write remains pending.',
          };
        }
        if (result['code'] == 'LOCK_TIMEOUT' && attempt == 0) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (result['success'] == true) {
          _invalidateCachesAfterMutation(endpoint);
        }
        return {
          ...result,
          'transactionId': result['transactionId'] ?? transactionId,
        };
      } on TimeoutException catch (e) {
        return {
          'success': false,
          'code': 'OUTCOME_UNKNOWN',
          'transactionId': transactionId,
          'message': '$e; write remains pending.',
        };
      } on SocketException catch (e) {
        return {
          'success': false,
          'code': 'OUTCOME_UNKNOWN',
          'transactionId': transactionId,
          'message': '$e; write remains pending.',
        };
      } on http.ClientException catch (e) {
        return {
          'success': false,
          'code': 'OUTCOME_UNKNOWN',
          'transactionId': transactionId,
          'message': '$e; write remains pending.',
        };
      } on _RedirectFailure catch (e) {
        return {
          'success': false,
          'code': 'OUTCOME_UNKNOWN',
          'transactionId': transactionId,
          'message': '$e; write remains pending.',
        };
      } catch (e) {
        return {
          'success': false,
          'code': 'POST_FAILED',
          'transactionId': transactionId,
          'message': '$e',
        };
      }
    }
    return {
      'success': false,
      'code': 'LOCK_TIMEOUT',
      'transactionId': transactionId,
      'message': 'Server busy; write remains pending.',
    };
  }

  void _invalidateCachesAfterMutation(String endpoint) {
    switch (endpoint) {
      // Invoice mutations can change both InvoiceDetails and the
      // purchase rows derived/associated with invoices.
      case 'syncInvoiceDetails':
      case 'updateInvoice':
      case 'deleteInvoice':
        _cache.remove('InvoiceDetails');
        _cache.remove('Purchases');
        break;

      // Purchase mutations affect Purchases only.
      case 'syncPurchases':
      case 'updatePurchase':
      case 'deletePurchase':
      case 'deletePurchases':
        _cache.remove('Purchases');
        break;

      default:
        // Other mutations retain their existing cache behaviour.
        break;
    }
  }

  Map<String, dynamic> _parseSyncResponse(String responseBody) {
    int number(dynamic value) {
      final parsed = value is num ? value : num.tryParse('$value');
      return parsed != null && parsed.isFinite ? parsed.toInt() : 0;
    }

    try {
      final decoded = json.decode(responseBody);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object');
      }
      final result = decoded;
      // Preserve the version-2 receipt and its per-record acknowledgements.
      if (result['receiptVersion'] == 2) {
        return <String, dynamic>{
          ...result,
          'success': result['success'] == true && result['status'] == 'success',
        };
      }
      final rawDuplicates = result['duplicates'];
      final duplicates = rawDuplicates is List
          ? rawDuplicates
                .whereType<Map>()
                .map((v) => Map<String, dynamic>.from(v))
                .toList()
          : <Map<String, dynamic>>[];
      final duplicateCount = number(
        result['duplicateCount'] ??
            (rawDuplicates is List ? rawDuplicates.length : rawDuplicates),
      );
      final rawErrors = result['errors'];
      final errorCount = num.tryParse('${result['errorCount'] ?? 0}');
      final hasReportedErrors =
          (errorCount != null && errorCount > 0) ||
          (rawErrors is List && rawErrors.isNotEmpty) ||
          (rawErrors is Map && rawErrors.isNotEmpty) ||
          (rawErrors is String && rawErrors.trim().isNotEmpty);
      final failed =
          result['error'] != null ||
          result['status'] == 'error' ||
          result['success'] == false ||
          hasReportedErrors;
      // A partial result must not tell callers that the whole upload succeeded.
      final success =
          !failed &&
          result['status'] != 'partial_success' &&
          (result['status'] == 'success' ||
              result['status'] == 'duplicate' ||
              result['success'] == true);
      final count = number(
        result['count'] ?? result['newCount'] ?? result['added'],
      );
      final updated = number(result['updated'] ?? result['updatedCount']);
      return <String, dynamic>{
        ...result,
        'success': success,
        'newCount': count,
        'count': count,
        'added': number(result['added'] ?? count),
        'storeAdded': number(result['storeAdded']),
        'updatedCount': updated,
        'updated': updated,
        'deleted': number(result['deleted']),
        'duplicateCount': duplicateCount,
        'duplicates': duplicates,
        'message':
            result['message']?.toString() ??
            result['error']?.toString() ??
            (success ? 'Sync completed' : 'Sync was not fully confirmed'),
        'raw': result,
      };
    } catch (e) {
      logger?.error('Error parsing sync response', e);
      return <String, dynamic>{
        'success': false,
        'status': 'error',
        'message': 'Invalid server response format: $e',
        'newCount': 0,
        'count': 0,
        'added': 0,
        'storeAdded': 0,
        'updatedCount': 0,
        'updated': 0,
        'deleted': 0,
        'duplicateCount': 0,
        'duplicates': <Map<String, dynamic>>[],
      };
    }
  }

  void _checkFetchActive(int generation) {
    if (_isDisposed) throw StateError('Service is disposed');
    if (generation != _cancelGeneration) throw StateError('Download cancelled');
  }

  int _nonNegativeInteger(dynamic raw, String name) {
    final value = raw is num ? raw : num.tryParse('$raw');
    if (value == null || !value.isFinite || value != value.truncate()) {
      throw FormatException('Invalid $name: expected an integer');
    }
    // Safely clamp negative values (e.g. blank sheet returning -1) to 0
    return math.max(0, value.toInt());
  }

  dynamic _decodeGetResponse(http.Response response) {
    if (response.statusCode != 200) {
      throw _HttpReadFailure(response.statusCode);
    }
    if (response.body.trim().startsWith('<')) {
      throw const FormatException('GAS returned HTML instead of JSON');
    }
    final decoded = json.decode(response.body);
    _recordSuccess();
    if (decoded is Map &&
        (decoded['error'] != null ||
            decoded['status'] == 'error' ||
            decoded['status'] == 'partial_success' ||
            decoded['success'] == false ||
            decoded['warning'] != null)) {
      final msg =
          (decoded['error'] ??
                  decoded['message'] ??
                  decoded['warning'] ??
                  decoded['status'])
              .toString();
      final code =
          decoded['code']?.toString() ??
          (msg.toLowerCase().contains('not found') ? 'TABLE_NOT_FOUND' : null);
      throw _GasReadError(msg, code);
    }
    return decoded;
  }

  /// Shared queue and timeout for GET downloads and POST uploads.
  /// Uses a leased client pool to preserve HTTP Keep-Alive while ensuring
  /// socket termination on timeout.
  Future<http.Response> _executeWithBoundedRedirects(
    String method,
    Uri uri, {
    required int timeoutSeconds,
    Map<String, String>? headers,
    String? body,
    required String label,
  }) async {
    if (timeoutSeconds < 1) throw ArgumentError('Timeout must be positive');
    final generation = _cancelGeneration;
    final isDownload = method.toUpperCase() == 'GET';
    void checkActive() {
      if (_isDisposed) throw StateError('Service is disposed');
      if (isDownload) _checkFetchActive(generation);
    }

    final queueWatch = Stopwatch()..start();
    final requestGate = isDownload ? _getRequestGate : _postRequestGate;
    await requestGate.acquire();
    queueWatch.stop();

    // Outer try/finally strictly guarantees semaphore release
    try {
      checkActive();
      final client = _leaseClient();
      var discardClient = false;
      final networkWatch = Stopwatch()..start();
      final trace = <String>[];
      String outcome = 'failed';

      // Inner try/finally guarantees client return to pool
      try {
        var current = uri;
        var hop = 0;
        var currentMethod = method;
        final watch = Stopwatch()..start();
        final budget = Duration(seconds: timeoutSeconds);

        for (;;) {
          checkActive();
          final remaining = budget - watch.elapsed;
          if (remaining <= Duration.zero) {
            throw TimeoutException('$currentMethod timed out');
          }

          final request = http.Request(currentMethod, current)
            ..followRedirects = false;
          if (headers != null) request.headers.addAll(headers);
          if (currentMethod == 'POST' && body != null) {
            request.headers['Content-Type'] = 'application/json';
            request.body = body;
          }

          final response = await (() async {
            final streamed = await client.send(request);
            return http.Response.fromStream(streamed);
          })().timeout(remaining);

          checkActive();

          if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
            outcome = 'HTTP ${response.statusCode}';
            return response;
          }

          hop++;
          trace.add('${response.statusCode} from ${current.host}');
          if (hop > maxRedirects) {
            throw _RedirectFailure(
              'Redirect limit exceeded ($maxRedirects hops)',
              trace,
            );
          }

          final location = response.headers['location'];
          if (location == null || location.trim().isEmpty) {
            throw _RedirectFailure('Redirect has no Location header', trace);
          }

          final next = current.resolve(location);
          if (next.scheme != 'https' && next.scheme != 'http') {
            throw const FormatException('Unsupported redirect scheme');
          }

          trace.add('to ${next.host}');

          // Apps Script POSTs normally redirect once to googleusercontent.com,
          // where the result is retrieved with GET. If that redirected GET is
          // sent back to script.google.com, following it would hit doGet()
          // without a table parameter and can yield {error: "Empty table name"}.
          // Abort with an unknown outcome. Purchase sync verifies the stored
          // rows before acknowledgement; it does not blindly replay this POST.
          final originalWasPost = method.toUpperCase() == 'POST';
          final redirectedPostResult =
              originalWasPost && currentMethod == 'GET';
          final returnedToAppsScript =
              redirectedPostResult && next.host == 'script.google.com';
          if (returnedToAppsScript) {
            throw _RedirectFailure(
              'POST result redirect returned to Apps Script; write outcome unknown',
              trace,
            );
          }

          // Follow immediately; transient failures use the existing retry policy.
          current = next;

          if ((response.statusCode == 303 && currentMethod != 'HEAD') ||
              ((response.statusCode == 301 || response.statusCode == 302) &&
                  currentMethod == 'POST')) {
            currentMethod = 'GET';
          }
        }
      } on TableNotFoundException {
        // Missing tables are application schema gaps, not network drops
        outcome = 'TableNotFound';
        rethrow;
      } on TimeoutException {
        discardClient = true;
        outcome = 'TimeoutException';
        rethrow;
      } on SocketException {
        discardClient = true;
        outcome = 'SocketException';
        rethrow;
      } on http.ClientException {
        discardClient = true;
        outcome = 'ClientException';
        rethrow;
      } catch (e) {
        outcome = '${e.runtimeType}';
        rethrow;
      } finally {
        if (kDebugMode) {
          print(
            '$method $label queue_ms=${queueWatch.elapsedMilliseconds} '
            'network_ms=${networkWatch.elapsedMilliseconds} outcome=$outcome '
            'redirects=[${trace.join("; ")}]',
          );
        }
        _returnClient(client, discard: discardClient);
      }
    } finally {
      requestGate.release();
    }
  }

  /// GET pagination — unchanged public behavior, now delegating to the shared core.
  Future<http.Response> _getWithBoundedRedirects(
    Uri uri, {
    required int timeoutSeconds,
  }) async {
    final table =
        uri.queryParameters['targetTable'] ??
        uri.queryParameters['table'] ??
        'GET';
    final label = '$table offset=${uri.queryParameters['offset'] ?? "count"}';
    return _executeWithBoundedRedirects(
      'GET',
      uri,
      timeoutSeconds: timeoutSeconds,
      headers: const {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      },
      label: label,
    );
  }

  /// POST sync uploads — same gating, bounded redirects, and logging as GET.
  Future<http.Response> _postWithBoundedRedirects(
    Uri uri, {
    required int timeoutSeconds,
    required String body,
    required String label,
  }) async {
    return _executeWithBoundedRedirects(
      'POST',
      uri,
      timeoutSeconds: timeoutSeconds,
      headers: const {'Accept': 'application/json'},
      body: body,
      label: label,
    );
  }

  Uri _tableUri(String tableName, int offset, int limit, bool alternative) {
    var base = Uri.parse(masterScriptUrl);
    if (alternative) {
      // Preserve the tested canonical URL fallback, with encoded parameters.
      final segments = base.pathSegments;
      final marker = segments.lastIndexOf('s');
      if (base.host == 'script.google.com' &&
          marker >= 0 &&
          marker + 1 < segments.length) {
        base = Uri.https(
          'script.google.com',
          '/macros/s/${segments[marker + 1]}/exec',
        );
      }
    }
    return base.replace(
      queryParameters: {
        ...Uri.parse(masterScriptUrl).queryParameters,
        'table': tableName,
        'storeIdentifier': storeIdentifier,
        'offset': '$offset',
        'limit': '$limit',
        '_t': '${DateTime.now().microsecondsSinceEpoch}',
      },
    );
  }

  Future<_BatchResult> _processBatchResponse(
    http.Response response,
    String tableName,
    int offset,
    int attempt,
  ) async {
    final decoded = _decodeGetResponse(response);
    dynamic data;
    int? total;
    bool? hasMore;
    if (decoded is Map) {
      if (decoded.containsKey('total')) {
        total = _nonNegativeInteger(decoded['total'], 'page total');
      }
      if (decoded.containsKey('hasMore')) {
        if (decoded['hasMore'] is! bool)
          throw const FormatException('Invalid hasMore');
        hasMore = decoded['hasMore'] as bool;
      }
      if (decoded.containsKey('offset') &&
          _nonNegativeInteger(decoded['offset'], 'page offset') != offset) {
        throw const FormatException('Server returned the wrong page offset');
      }
      data = decoded['data'];
      // Existing GAS returns {total: 0} for a header-only empty sheet.
      if (!decoded.containsKey('data') &&
          total == 0 &&
          offset == 0 &&
          hasMore != true) {
        data = <dynamic>[];
        hasMore = false;
      }
    } else {
      data = decoded;
    }
    if (data is! List || data.any((item) => item is! Map)) {
      throw FormatException('Invalid rows for $tableName at offset $offset');
    }
    final rows = await _parseSmart(data);
    return _BatchResult(rows: rows, total: total, hasMore: hasMore);
  }

  Future<_BatchResult> _fetchBatchPage(
    String tableName, {
    int offset = 0,
    int limit = defaultBatchSize,
    int timeoutSeconds = defaultTimeoutSeconds,
    bool useAlternativeUrl = false,
    int attempt = 1,
  }) async {
    if (offset < 0 || limit < 1)
      throw ArgumentError('Invalid pagination arguments');
    final response = await _getWithBoundedRedirects(
      _tableUri(tableName, offset, limit, useAlternativeUrl),
      timeoutSeconds: timeoutSeconds,
    );
    return _processBatchResponse(response, tableName, offset, attempt);
  }

  /// Existing public list-returning API. One bounded alternative-URL retry.
  Future<List<Map<String, dynamic>>> fetchBatchWithPagination(
    String tableName, {
    int offset = 0,
    int limit = defaultBatchSize,
    int timeoutSeconds = defaultTimeoutSeconds,
    bool useAlternativeUrl = false,
    int attempt = 1,
  }) async {
    final generation = _cancelGeneration;
    var alternative = useAlternativeUrl;
    for (int pass = 0; pass < 2; pass++) {
      _checkFetchActive(generation);
      try {
        final page = await _fetchBatchPage(
          tableName,
          offset: offset,
          limit: limit,
          timeoutSeconds: timeoutSeconds,
          useAlternativeUrl: alternative,
          attempt: attempt + pass,
        );
        _checkFetchActive(generation);
        return page.rows;
      } catch (e) {
        _checkFetchActive(generation);
        if (alternative ||
            pass == 1 ||
            !(e is TimeoutException ||
                e.toString().contains('HTTP 404') ||
                e is _RedirectFailure))
          rethrow;
        alternative = true;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    throw StateError('No page returned');
  }

  Future<int> getTableRowCount(String tableName) async {
    final generation = _cancelGeneration;
    final base = Uri.parse(masterScriptUrl);
    final uri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        'table': '_count',
        'targetTable': tableName,
        'storeIdentifier': storeIdentifier,
      },
    );
    for (int attempt = 1; attempt <= 3; attempt++) {
      _checkFetchActive(generation);
      try {
        final response = await _getWithBoundedRedirects(
          uri,
          timeoutSeconds: countTimeoutSeconds,
        );
        final decoded = _decodeGetResponse(response);
        if (decoded is! Map)
          throw const FormatException('Invalid count response');
        final count = _nonNegativeInteger(decoded['count'], 'row count');
        _checkFetchActive(generation);
        _recordSuccess();
        return count;
      } catch (e) {
        _checkFetchActive(generation);
        if (!_isReadTransportFailure(e)) rethrow;
        _recordFailure();
        if (attempt == 3) rethrow;
        logger?.error('Count for $tableName failed (attempt $attempt)', e);
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    throw StateError('No count returned');
  }

  Future<List<Map<String, dynamic>>> fetchTableWithPagination(
    String tableName, {
    int batchSize = defaultBatchSize,
    int timeoutSeconds = defaultTimeoutSeconds,
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async {
    if (batchSize < 1 || timeoutSeconds < 1) {
      throw ArgumentError('Invalid fetch arguments');
    }

    final generation = _cancelGeneration;
    _checkFetchActive(generation);
    _checkKnownMissing(tableName);

    // Reuse a previously verified download when available.
    final verified = _reuseVerifiedDownload(tableName);

    if (verified != null) {
      onProgress?.call(verified.length, verified.length);
      return verified;
    }

    // StoreSalesData has its own versioned/block download path.
    if (tableName == 'StoreSalesData' &&
        _versionedRefreshActive &&
        _salesPlan != null) {
      try {
        return await _downloadSalesBlocks(
          _salesPlan!,
          timeoutSeconds,
          onProgress,
          onStatus,
        );
      } catch (e) {
        _checkFetchActive(generation);

        logger?.info(
          'Sales download paused: ${_salesBlocks.length} verified blocks '
          'retained; no restart from offset zero. Refresh again to resume '
          'against a fresh manifest. $e',
        );

        rethrow;
      }
    }

    // Normal short-lived table cache.
    final cached = _cache[tableName];

    if (cached != null &&
        DateTime.now().difference(cached.timestamp) < cacheDuration) {
      return cached.data;
    }

    int? pageTotal;
    final rows = <Map<String, dynamic>>[];

    // Finite guard for a broken endpoint that never declares completion.
    for (int pageNumber = 1; pageNumber <= 10000; pageNumber++) {
      _checkFetchActive(generation);

      _BatchResult? page;
      final offset = rows.length;

      // Retry the current page without permanently locking ourselves
      // onto one URL after a transient redirect/404/timeout.
      for (int attempt = 1; attempt <= maxFetchRetries; attempt++) {
        _checkFetchActive(generation);

        // Attempt 1 = primary
        // Attempt 2 = alternative
        // Attempt 3 = primary
        // Attempt 4 = alternative
        // ...
        final useAlternative = attempt.isEven;

        try {
          if (_circuitBreakerOpen) {
            onStatus?.call('Waiting for server recovery...');

            await Future.delayed(resetTimeout);

            _checkFetchActive(generation);
            _resetCircuitBreaker();
          }

          onStatus?.call(
            'Fetching $tableName: '
            'offset $offset, '
            'limit $batchSize, '
            'attempt $attempt',
          );

          if (kDebugMode) {
            print(
              'Fetch $tableName '
              'offset=$offset '
              'limit=$batchSize '
              'route=${useAlternative ? "alternative" : "primary"} '
              'attempt=$attempt',
            );
          }

          page = await _fetchBatchPage(
            tableName,
            offset: offset,
            limit: batchSize,
            timeoutSeconds: timeoutSeconds,
            useAlternativeUrl: useAlternative,
            attempt: attempt,
          );

          _checkFetchActive(generation);

          _recordSuccess();

          // Current page succeeded. Leave retry loop.
          break;
        } catch (e) {
          _checkFetchActive(generation);

          final errStr = e.toString().toLowerCase();

          // A genuine missing table is not a transient transport problem.
          if (errStr.contains('not found') ||
              errStr.contains('table not found')) {
            logger?.error(
              'Table $tableName does not exist on server; '
              'skipping retries.',
            );

            rethrow;
          }

          final isTransportFailure = _isReadTransportFailure(e);

          if (isTransportFailure) {
            _recordFailure();
          }

          logger?.error(
            'Fetch $tableName offset $offset '
            'attempt $attempt/$maxFetchRetries failed',
            e,
          );

          // Validation/parsing/application errors should not be blindly
          // replayed as though they were network failures.
          if (!isTransportFailure) {
            rethrow;
          }

          if (attempt == maxFetchRetries) {
            throw Exception(
              'Fetch $tableName offset $offset failed after '
              '$maxFetchRetries attempts: $e',
            );
          }

          // Backoff before trying the other route.
          await Future.delayed(
            Duration(milliseconds: attempt * 2000 + math.Random().nextInt(500)),
          );
        }
      }

      if (page == null) {
        throw StateError('No page returned for $tableName');
      }

      _checkFetchActive(generation);

      if (page.rows.length > batchSize) {
        throw const FormatException('Page exceeds requested limit');
      }

      // Establish total directly from page response.
      // This avoids a redundant count request.
      if (page.total != null) {
        if (pageTotal != null && pageTotal != page.total) {
          throw FormatException(
            '$tableName changed during pagination at offset $offset: '
            'previous_total=$pageTotal, '
            'received_total=${page.total}; '
            'retry against a fresh manifest',
          );
        }

        pageTotal = page.total;
      }

      final expected = pageTotal;

      rows.addAll(page.rows);

      if (expected != null && rows.length > expected) {
        throw FormatException(
          '$tableName returned more rows than its reported total',
        );
      }

      bool complete;

      if (page.hasMore != null) {
        complete = !page.hasMore!;

        if (!complete && page.rows.isEmpty) {
          throw const FormatException('Empty page with hasMore=true');
        }

        if (!complete && pageTotal != null && rows.length >= pageTotal) {
          throw const FormatException('hasMore contradicts page total');
        }
      } else {
        if (expected == null) {
          throw const FormatException(
            'Cannot verify completion: no total or hasMore',
          );
        }

        complete = rows.length == expected;

        if (!complete && page.rows.length < batchSize) {
          throw FormatException(
            'Incomplete $tableName download: '
            '${rows.length} of $expected rows',
          );
        }
      }

      onProgress?.call(rows.length, expected);

      _checkFetchActive(generation);

      if (complete) {
        if (expected != null && rows.length != expected) {
          throw FormatException(
            'Incomplete $tableName download: '
            '${rows.length} of $expected rows',
          );
        }

        _checkFetchActive(generation);

        if (kDebugMode) {
          print('Completed $tableName: ${rows.length} rows');
        }

        await _rememberRefreshDownload(tableName, rows);

        _cache[tableName] = _CacheEntry(data: rows, timestamp: DateTime.now());

        return rows;
      }

      // Brief pause to let GAS settle between chunks.
      await Future.delayed(
        Duration(milliseconds: tableName == 'StoreSalesData' ? 800 : 300),
      );
    }

    throw StateError('Page limit exceeded for $tableName; no data cached');
  }

  // ---------------------------------------------------------------------------
  // 🔥 CONVENIENCE: fetchLargeTableInBatches (Backward Compatible)
  // ---------------------------------------------------------------------------

  /// Kept for backward compatibility with existing code
  Future<List<Map<String, dynamic>>> fetchLargeTableInBatches(
    String tableName, {
    int batchSize = defaultBatchSize,
    int timeoutSeconds = defaultTimeoutSeconds,
    Function(int received, int total)? onProgress,
  }) async {
    return fetchTableWithPagination(
      tableName,
      batchSize: batchSize,
      timeoutSeconds: timeoutSeconds,
      onProgress: (received, total) {
        if (onProgress != null && total != null) {
          onProgress(received, total);
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 🔥 CONVENIENCE: fetchTableBatch (Backward Compatible)
  // ---------------------------------------------------------------------------

  /// Kept for backward compatibility with existing code
  Future<List<Map<String, dynamic>>> fetchTableBatch(
    String tableName, {
    int offset = 0,
    int limit = defaultBatchSize,
    int timeoutSeconds = defaultTimeoutSeconds,
  }) async {
    return fetchBatchWithPagination(
      tableName,
      offset: offset,
      limit: limit,
      timeoutSeconds: timeoutSeconds,
    );
  }

  // ---------------------------------------------------------------------------
  // Get Total Row Count with Retry
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Health Check
  // ---------------------------------------------------------------------------

  Future<bool> checkGASHealth() async {
    try {
      print('🏥 Checking GAS health...');
      final url = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': 'Locations',
          'storeIdentifier': storeIdentifier,
          'limit': '1',
        },
      );

      final response = await _getWithBoundedRedirects(url, timeoutSeconds: 10);

      if (response.statusCode == 200 && !response.body.trim().startsWith('<')) {
        print('✅ GAS is healthy');
        _recordSuccess();
        return true;
      } else {
        print('⚠️ GAS returned ${response.statusCode}');
        _recordFailure();
        return false;
      }
    } catch (e) {
      print('⚠️ GAS health check failed: $e');
      _recordFailure();
      return false;
    }
  }

  static Future<Map<String, dynamic>> validateStoreLink(
    String masterScriptUrl,
    String sheetId, {
    String? userEmail,
    LoggerService? logger,
  }) async {
    try {
      final url = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': 'validateStore',
          'sheetId': sheetId,
          if (userEmail != null && userEmail.isNotEmpty) 'userEmail': userEmail,
        },
      );

      var response = await http.get(url).timeout(const Duration(seconds: 30));

      if (response.statusCode == 302 || response.statusCode == 303) {
        final location = response.headers['location'];
        if (location != null) {
          await Future.delayed(const Duration(milliseconds: 500));
          response = await http
              .get(Uri.parse(location), headers: {'Accept': 'application/json'})
              .timeout(const Duration(seconds: 30));
        }
      }

      if (response.statusCode != 200) {
        return {
          'found': false,
          'message': 'Server error (${response.statusCode})',
        };
      }

      final body = response.body.trim();
      if (body.toUpperCase().startsWith('<HTML')) {
        return {'found': false, 'message': 'Unexpected server response'};
      }

      return json.decode(body) as Map<String, dynamic>;
    } catch (e) {
      logger?.error('validateStoreLink failed', e.toString());
      return {'found': false, 'message': e.toString()};
    }
  }

  // ---------------------------------------------------------------------------
  // Cancellation & Cache Management
  // ---------------------------------------------------------------------------

  void cancelFetch() {
    _cancelGeneration++;
    print('🛑 Cancellation requested');
  }

  void clearCache({String? tableName}) {
    if (tableName == null) {
      _verifiedDownloads.clear();
      _pendingVerification.clear();
      _salesBlocks.clear();
      _refreshCandidates.clear();
    } else {
      _verifiedDownloads.remove(tableName);
      _pendingVerification.remove(tableName);
      if (tableName == 'StoreSalesData') _salesBlocks.clear();
      _refreshCandidates.remove(tableName);
    }
    if (tableName != null) {
      _cache.remove(tableName);
      print('🗑️ Cleared cache for $tableName');
    } else {
      _cache.clear();
      print('🗑️ Cleared all cache');
    }
  }

  void resetCircuitBreaker() {
    _resetCircuitBreaker();
  }

  /// Fetches multiple small tables in a single HTTP request, eliminating round-trips.
  /// Returns only complete tables. Failures are exposed separately, never as [].
  Future<Map<String, List<Map<String, dynamic>>>> fetchBundledTables(
    List<String> tableNames, {
    int timeoutSeconds = defaultTimeoutSeconds,
  }) async {
    final generation = _cancelGeneration;
    _checkFetchActive(generation);
    _bundleErrors.clear();
    final result = <String, List<Map<String, dynamic>>>{};
    final missing = <String>[];
    for (final table in tableNames.toSet()) {
      if (_versionedRefreshActive && _knownMissingTables.containsKey(table)) {
        _bundleErrors[table] = _knownMissingTables[table]!;
        continue;
      }
      final reused = _reuseVerifiedDownload(table);
      if (reused == null) {
        missing.add(table);
      } else {
        result[table] = reused;
      }
    }
    if (missing.isEmpty) return result;
    Map? data;
    Map? errors;
    try {
      final base = Uri.parse(masterScriptUrl);
      final uri = base.replace(
        queryParameters: {
          ...base.queryParameters,
          'table': '_bundle',
          'tables': missing.join(','),
          'storeIdentifier': storeIdentifier,
          '_t': '${DateTime.now().microsecondsSinceEpoch}',
        },
      );
      final response = await _getWithBoundedRedirects(
        uri,
        timeoutSeconds: timeoutSeconds,
      );
      _checkFetchActive(generation);
      final decoded = _decodeGetResponse(response);
      if (decoded is! Map ||
          decoded['protocol'] != 1 ||
          decoded['data'] is! Map ||
          decoded['errors'] is! Map) {
        throw const FormatException('Safe bundle protocol unavailable');
      }
      data = decoded['data'] as Map;
      errors = decoded['errors'] as Map;
    } catch (e) {
      _checkFetchActive(generation);
      logger?.info(
        'Bundle unavailable; falling back to individual downloads: $e',
      );
    }
    for (final table in missing) {
      _checkFetchActive(generation);
      try {
        final raw = data?[table];
        if (errors?.containsKey(table) != true &&
            raw is List &&
            raw.every((row) => row is Map)) {
          result[table] = await _parseSmart(raw);
          await _rememberRefreshDownload(table, result[table]!);
        } else {
          // Oversized, missing, malformed, or old-server bundles use the normal
          // paginated read, which has retries and preserves genuine errors.
          final tableErr = errors?[table]?.toString() ?? '';
          if (tableErr.contains('not found') ||
              tableErr.contains('Not found')) {
            throw FormatException("Table '$table' not found on server");
          }
          result[table] = await fetchTableWithPagination(table, batchSize: 500);
        }
        _checkFetchActive(generation);
      } catch (e) {
        _checkFetchActive(generation);
        _bundleErrors[table] = e.toString();
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  /// Fetch one CRUD record without downloading an entire table.
  /// This is intentionally limited server-side to StockCounts, Purchases and
  /// InvoiceDetails.
  Future<Map<String, dynamic>?> fetchRecordById(String table, String id) async {
    final cleanId = id.trim();
    if (cleanId.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Record ID cannot be empty');
    }

    Object? lastError;

    // A real "record not found" response from our Apps Script is HTTP 200
    // with found:false. A transport-level HTTP 404 here is therefore safe
    // to retry as a read.
    for (var attempt = 1; attempt <= 3; attempt++) {
      final base = Uri.parse(masterScriptUrl);
      final uri = base.replace(
        queryParameters: {
          ...base.queryParameters,
          'table': table,
          'storeIdentifier': storeIdentifier,
          'id': cleanId,
          '_t': '${DateTime.now().microsecondsSinceEpoch}',
        },
      );

      try {
        final response = await _getWithBoundedRedirects(
          uri,
          timeoutSeconds: countTimeoutSeconds,
        );

        if (response.statusCode == 404) {
          throw Exception('HTTP 404 from Apps Script transport');
        }
        if (response.statusCode != 200) {
          throw Exception('$table lookup failed: HTTP ${response.statusCode}');
        }

        final decoded = _decodeGetResponse(response);
        if (decoded is! Map) {
          throw const FormatException('Record lookup returned invalid JSON');
        }

        final result = Map<String, dynamic>.from(decoded);
        if (result['success'] != true) {
          throw Exception(
            result['message'] ??
                result['error'] ??
                result['code'] ??
                '$table lookup failed',
          );
        }

        if (result['found'] != true) return null;

        final rawRow = result['row'];
        if (rawRow is! Map) {
          throw const FormatException('Record lookup returned an invalid row');
        }

        return Map<String, dynamic>.from(rawRow);
      } catch (e) {
        lastError = e;
        final text = e.toString().toLowerCase();
        final retryable =
            e is TimeoutException ||
            e is SocketException ||
            e is http.ClientException ||
            e is _RedirectFailure ||
            text.contains('http 404');

        if (!retryable || attempt == 3) rethrow;

        if (kDebugMode) {
          print(
            'Targeted lookup $table id=$cleanId '
            'attempt=$attempt/3 failed; retrying: $e',
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    throw Exception('$table lookup failed: $lastError');
  }

  Future<Map<String, dynamic>?> fetchStockCountById(String id) async {
    final row = await fetchRecordById('StockCounts', id);
    if (row == null) return null;

    final normalized = Map<String, dynamic>.from(row);
    final stockId =
        (normalized['stockTake_ID'] ??
                normalized['stock_id'] ??
                normalized['id'] ??
                '')
            .toString()
            .trim();
    if (stockId.isNotEmpty) {
      normalized['id'] = stockId;
      normalized['stock_id'] = stockId;
    }
    return normalized;
  }

  Future<Map<String, dynamic>?> fetchPurchaseById(String id) =>
      fetchRecordById('Purchases', id);

  Future<Map<String, dynamic>?> fetchInvoiceById(String id) =>
      fetchRecordById('InvoiceDetails', id);

  /// Read-only existence check for Purchases linked to an invoice.
  /// Used only to reconcile an ambiguous deleteInvoice outcome.
  Future<bool> hasPurchasesForInvoice(String invoiceId) async {
    final cleanId = invoiceId.trim();
    if (cleanId.isEmpty) {
      throw ArgumentError.value(
        invoiceId,
        'invoiceId',
        'Invoice ID cannot be empty',
      );
    }

    Object? lastError;

    // Reads are safe to retry. A genuine "no linked purchases" result is
    // HTTP 200 with success:true, found:false.
    for (var attempt = 1; attempt <= 3; attempt++) {
      final base = Uri.parse(masterScriptUrl);
      final uri = base.replace(
        queryParameters: {
          ...base.queryParameters,
          'table': 'Purchases',
          'storeIdentifier': storeIdentifier,
          'invoiceDetailsId': cleanId,
          '_t': '${DateTime.now().microsecondsSinceEpoch}',
        },
      );

      try {
        final response = await _getWithBoundedRedirects(
          uri,
          timeoutSeconds: countTimeoutSeconds,
        );

        if (response.statusCode == 404) {
          throw Exception('HTTP 404 from Apps Script transport');
        }
        if (response.statusCode != 200) {
          throw Exception(
            'Purchases invoice lookup failed: HTTP ${response.statusCode}',
          );
        }

        final decoded = _decodeGetResponse(response);
        if (decoded is! Map) {
          throw const FormatException(
            'Purchases invoice lookup returned invalid JSON',
          );
        }

        final result = Map<String, dynamic>.from(decoded);
        if (result['success'] != true) {
          throw Exception(
            result['message'] ??
                result['error'] ??
                result['code'] ??
                'Purchases invoice lookup failed',
          );
        }

        return result['found'] == true;
      } catch (e) {
        lastError = e;
        final text = e.toString().toLowerCase();
        final retryable =
            e is TimeoutException ||
            e is SocketException ||
            e is http.ClientException ||
            e is _RedirectFailure ||
            text.contains('http 404');

        if (!retryable || attempt == 3) rethrow;

        if (kDebugMode) {
          print(
            'Targeted Purchases invoice lookup id=$cleanId '
            'attempt=$attempt/3 failed; retrying: $e',
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    throw Exception('Purchases invoice lookup failed: $lastError');
  }

  // Table Fetch Methods - ALL use the generic pagination system
  // ---------------------------------------------------------------------------

  // Small tables
  Future<List<Map<String, dynamic>>> fetchLocations() async =>
      fetchTableWithPagination('Locations', batchSize: 100);

  Future<List<Map<String, dynamic>>> fetchInventory() async =>
      fetchTableWithPagination('Inventory', batchSize: 500);

  Future<List<Map<String, dynamic>>> fetchAudits() async =>
      fetchTableWithPagination('AuditCalendar', batchSize: 100);

  // Large tables
  Future<List<Map<String, dynamic>>> fetchPurchases({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async => fetchTableWithPagination(
    'Purchases',
    batchSize: 1000,
    timeoutSeconds: largeTableTimeoutSeconds,
    onProgress: onProgress,
    onStatus: onStatus,
  );

  Future<List<Map<String, dynamic>>> fetchStoreSalesData({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) => fetchTableWithPagination(
    'StoreSalesData',
    batchSize: 1500,
    timeoutSeconds: largeTableTimeoutSeconds,
    onProgress: onProgress,
    onStatus: onStatus,
  );

  Future<List<Map<String, dynamic>>> fetchItemSales({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async => fetchTableWithPagination(
    'ItemSales',
    onProgress: onProgress,
    onStatus: onStatus,
  );

  Future<List<Map<String, dynamic>>> fetchItemsIssued({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async => fetchTableWithPagination(
    'ItemsIssued',
    onProgress: onProgress,
    onStatus: onStatus,
  );

  Future<List<Map<String, dynamic>>> fetchInvoices({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async => fetchTableWithPagination(
    'InvoiceDetails',
    onProgress: onProgress,
    onStatus: onStatus,
  );

  Future<List<Map<String, dynamic>>> fetchStockCounts({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async {
    final rows = await fetchTableWithPagination(
      'StockCounts',
      onProgress: onProgress,
      onStatus: onStatus,
    );

    // Normalize sheet header 'stockTake_ID' to standard 'id' and 'stock_id'
    return rows.map((r) {
      final map = Map<String, dynamic>.from(r);
      final id =
          (map['id'] ??
                  map['stock_id'] ??
                  map['stockTake_ID'] ??
                  map['stockId'] ??
                  '')
              .toString()
              .trim();
      if (id.isNotEmpty) {
        map['id'] = id;
        map['stock_id'] = id;
      }
      return map;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> fetchPluMappings({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async => fetchTableWithPagination(
    'PluMappings',
    onProgress: onProgress,
    onStatus: onStatus,
  );

  // Master tables
  Future<List<Map<String, dynamic>>> fetchMasterProducts() async =>
      fetchTableWithPagination('MasterProducts', batchSize: 500);

  Future<List<Map<String, dynamic>>> fetchMasterBarcodes() async =>
      fetchTableWithPagination('MasterBarcodes', batchSize: 500);

  /// 🔥 FIXED: Fetch computed costs directly (bypasses pagination)
  /// MasterCostsComputed is a computed table, not a physical sheet
  Future<List<Map<String, dynamic>>> fetchComputedCosts({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) => fetchTableWithPagination(
    'MasterCostsComputed',
    onProgress: onProgress,
    onStatus: onStatus,
  );

  Future<List<Map<String, dynamic>>> fetchMasterSuppliers({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _cachedMasterSuppliers != null &&
        _cachedMasterSuppliers!.isNotEmpty) {
      return _cachedMasterSuppliers!;
    }

    final suppliers = await fetchTableWithPagination(
      'MasterSuppliers',
      batchSize: 2000,
    );

    _cachedMasterSuppliers = suppliers;
    print('✅ Fetched ${suppliers.length} suppliers');
    return suppliers;
  }

  Future<List<Map<String, dynamic>>> fetchStockIssues() async =>
      fetchTableWithPagination('StockIssues', batchSize: 500);

  Future<List<Map<String, dynamic>>> fetchItemsIssuedMap() async =>
      fetchTableWithPagination('ItemsIssuedMap', batchSize: 500);

  // Invoice methods
  Future<List<Map<String, dynamic>>> fetchInvoiceDetails({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async => fetchTableWithPagination(
    'InvoiceDetails',
    onProgress: onProgress,
    onStatus: onStatus,
  );

  Future<List<Map<String, dynamic>>> fetchAllInvoices({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async => fetchTableWithPagination(
    'InvoiceDetails',
    onProgress: onProgress,
    onStatus: onStatus,
  );

  // ---------------------------------------------------------------------------
  // Sync Operations (with chunking for large datasets)
  // ---------------------------------------------------------------------------

  Future<bool> syncStockCounts(List<Map<String, dynamic>> counts) async {
    // Always go through the chunking implementation, even for small
    // batches — it correctly checks GAS's actual response shape
    // (status: 'success'/'partial_success') and tracks confirmed IDs.
    // The old direct-post branch here checked result['success'], a
    // field the backend never sends for stock counts, so small batches
    // could never be confirmed through this path.
    final result = await syncStockCountsWithChunking(counts);
    return result['success'] == true;
  }

  Future<bool> syncNewProducts(List<Map<String, dynamic>> products) async {
    // Always use the chunking path so small real-device batches get the same
    // unknown-outcome reconciliation as larger batches.
    final result = await syncNewProductsWithChunking(products);
    return result['success'] == true;
  }

  Future<bool> syncNewLocations(List<Map<String, dynamic>> locations) async {
    // 🔥 FIXED: Use the chunking method
    if (locations.length > chunkSize) {
      final result = await syncNewLocationsWithChunking(locations);
      return result['success'] == true;
    }

    final payload = locations.map(_mapCommonFieldsForSheet).toList();

    final result = await _sendPostRequest('syncNewLocations', {
      'data': payload,
      'endpoint': 'syncNewLocations',
    });
    return result['success'] == true;
  }

  Future<Map<String, dynamic>> syncInvoiceDetailsWithResult(
    List<Map<String, dynamic>> invoices,
  ) async {
    final mappedInvoices = invoices.map(_mapInvoiceFields).toList();

    // 🔥 Force syncStatus to 'synced' before uploading
    final syncedInvoices = mappedInvoices.map((inv) {
      final modified = Map<String, dynamic>.from(inv);
      modified['syncStatus'] = 'synced';
      return modified;
    }).toList();

    // 🔥 FIXED: Always use the chunking path so small batches get the same
    // unknown-outcome reconciliation as larger batches.
    return syncInvoiceDetailsWithChunking(syncedInvoices);
  }

  Future<bool> syncInvoiceDetails(List<Map<String, dynamic>> invoices) async {
    final result = await syncInvoiceDetailsWithResult(invoices);
    return result['success'] == true;
  }

  Future<Map<String, dynamic>> syncPurchasesWithResult(
    List<Map<String, dynamic>> purchases,
  ) async {
    // Always use the chunking path, even for a single purchase, so real-device
    // batches get the same unknown-outcome reconciliation as larger batches.
    return syncPurchasesWithChunking(purchases);
  }

  Future<bool> syncPurchases(List<Map<String, dynamic>> purchases) async {
    final result = await syncPurchasesWithResult(purchases);
    return result['success'] == true;
  }

  Future<bool> syncPluMappings(List<Map<String, dynamic>> mappings) async {
    // 🔥 FIXED: Use the chunking method
    if (mappings.length > chunkSize) {
      final result = await syncPluMappingsWithChunking(mappings);
      return result['success'] == true;
    }

    final result = await _sendPostRequest('syncPluMappings', {
      'endpoint': 'syncPluMappings',
      'data': mappings,
    });
    return result['success'] == true;
  }

  // ============================================================================
  // 🔥 CHUNKED SYNC METHODS WITH RETRY AND PROGRESS
  // ============================================================================

  /// Sync invoices with chunking, retry, and progress reporting

  Future<Map<String, dynamic>> syncInvoiceDetailsWithChunking(
    List<Map<String, dynamic>> records, {
    Function(int processed, int total)? onProgress,
    int chunkSize = 25,
  }) async {
    if (chunkSize < 1 || chunkSize > 500) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be 1 to 500');
    }
    final snapshots = records
        .map(_mapInvoiceFields)
        .map((r) => {...r, 'syncStatus': 'synced'})
        .toList();
    final transactionId = _generateUuid();
    var added = 0, updated = 0, duplicateCount = 0, processed = 0;
    final duplicates = <Map<String, dynamic>>[];

    for (var offset = 0; offset < snapshots.length; offset += chunkSize) {
      final end = math.min(offset + chunkSize, snapshots.length);
      final chunk = snapshots.sublist(offset, end);

      final result = await _sendPostRequest('syncInvoiceDetails', {
        'endpoint': 'syncInvoiceDetails',
        'table': 'InvoiceDetails',
        'data': chunk,
        'transactionId': transactionId,
        'chunkIndex': offset ~/ chunkSize,
        'chunkTotal': (snapshots.length / chunkSize).ceil(),
      });

      if (result['success'] != true) {
        // 🔥 NEW: Localized read-after-unknown reconciliation for Invoices
        final code = result['code']?.toString() ?? '';
        final unknownOutcome = {
          'OUTCOME_UNKNOWN',
          'HTTP_ERROR',
          'POST_ROUTE_MISMATCH',
        }.contains(code);

        if (unknownOutcome) {
          print(
            '🔎 Invoice chunk has an unknown POST outcome ($code); verifying before leaving pending.',
          );
          await Future.delayed(const Duration(seconds: 2));

          var allConfirmed = true;
          for (final inv in chunk) {
            final invId = inv['invoiceDetailsID']?.toString();
            if (invId != null) {
              final remote = await fetchInvoiceById(invId);
              if (remote == null) {
                allConfirmed = false;
                break;
              }
              // 🔥 NEW: Verify key fields match to ensure the creation actually applied
              final expInvNum = inv['Invoice Number']?.toString().trim();
              final remInvNum = remote['Invoice Number']?.toString().trim();
              if (expInvNum != null &&
                  remInvNum != null &&
                  expInvNum != remInvNum) {
                print(
                  '⚠️ Invoice verification failed: Invoice Number mismatch for $invId',
                );
                allConfirmed = false;
                break;
              }
            }
          }

          if (allConfirmed) {
            print(
              '✅ Invoice chunk confirmed after unknown POST outcome; POST was not replayed.',
            );
            // Proceed to acknowledge as if it succeeded
          } else {
            print(
              '⚠️ Invoice chunk verification failed; leaving records pending.',
            );
            return {
              'success': false,
              'newCount': added,
              'updatedCount': updated,
              'duplicateCount': duplicateCount,
              'duplicates': duplicates,
              'processed': processed,
              'message':
                  result['message'] ??
                  'Chunk unconfirmed and verification failed',
              'code': result['code'],
            };
          }
        } else {
          // Definitive failure (e.g., INVALID_INPUT)
          return {
            'success': false,
            'newCount': added,
            'updatedCount': updated,
            'duplicateCount': duplicateCount,
            'duplicates': duplicates,
            'processed': processed,
            'message': result['message'] ?? 'Chunk unconfirmed',
            'code': result['code'],
          };
        }
      }

      added += (result['newCount'] as num? ?? 0).toInt();
      updated += (result['updatedCount'] as num? ?? 0).toInt();
      duplicateCount += (result['duplicateCount'] as num? ?? 0).toInt();
      final remoteDuplicates = result['duplicates'];
      if (remoteDuplicates is List) {
        duplicates.addAll(
          remoteDuplicates.whereType<Map>().map(
            (r) => Map<String, dynamic>.from(r),
          ),
        );
      }
      processed += end - offset;
      onProgress?.call(processed, snapshots.length);
    }

    return {
      'success': true,
      'newCount': added,
      'updatedCount': updated,
      'duplicateCount': duplicateCount,
      'duplicates': duplicates,
      'processed': processed,
      'message': 'Confirmed $processed records.',
    };
  }

  /// Sync purchases with chunking, retry, and progress reporting

  Future<Map<String, dynamic>> syncPurchasesWithChunking(
    List<Map<String, dynamic>> records, {
    Function(int processed, int total)? onProgress,
    int chunkSize = 50,
  }) async {
    if (chunkSize < 1 || chunkSize > 500) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be 1 to 500');
    }
    if (records.isEmpty) {
      return {
        'success': true,
        'newCount': 0,
        'updatedCount': 0,
        'duplicateCount': 0,
        'duplicates': <Map<String, dynamic>>[],
        'processed': 0,
        'confirmedIds': <String>[],
        'message': 'No purchases to sync.',
      };
    }

    final snapshots = records
        .map(_mapPurchaseFields)
        .map((r) => {...r, 'syncStatus': 'synced'})
        .toList();

    final allIds = snapshots
        .map((r) => (r['purchases_ID'] ?? '').toString().trim())
        .toList();
    if (allIds.any((id) => id.isEmpty) ||
        allIds.toSet().length != allIds.length) {
      return {
        'success': false,
        'newCount': 0,
        'updatedCount': 0,
        'duplicateCount': 0,
        'duplicates': <Map<String, dynamic>>[],
        'processed': 0,
        'confirmedIds': <String>[],
        'failedIds': allIds,
        'message': 'Missing or repeated purchase IDs in submitted batch.',
      };
    }

    final confirmedIds = <String>{};
    var added = 0, updated = 0, duplicateCount = 0, processed = 0;
    final duplicates = <Map<String, dynamic>>[];
    String lastError = '';

    for (var offset = 0; offset < snapshots.length; offset += chunkSize) {
      if (_isDisposed) {
        lastError = 'Service disposed during purchase sync.';
        break;
      }

      final end = math.min(offset + chunkSize, snapshots.length);
      final chunk = snapshots.sublist(offset, end);
      final chunkIds = allIds.sublist(offset, end);

      // One logical transaction identity for this chunk. We do not blindly
      // replay an ambiguous mutation response.
      final transactionId = _generateUuid();

      final result = await _sendPostRequest('syncPurchases', {
        'endpoint': 'syncPurchases',
        'table': 'Purchases',
        'data': chunk,
        'transactionId': transactionId,
        'chunkIndex': offset ~/ chunkSize,
        'chunkTotal': (snapshots.length / chunkSize).ceil(),
      });

      final acknowledged = result['confirmedIds'];
      var chunkConfirmed =
          result['success'] == true &&
          (acknowledged is List
              ? chunkIds.every((id) => acknowledged.contains(id))
              : result['processedCount'] == chunk.length);
      var reconciled = false;
      final code = result['code']?.toString() ?? '';
      final unknownOutcome = {
        'OUTCOME_UNKNOWN',
        'HTTP_ERROR',
        'POST_ROUTE_MISMATCH',
      }.contains(code);

      if (!chunkConfirmed && unknownOutcome) {
        print(
          '🔎 Purchases chunk ${(offset ~/ chunkSize) + 1} has an unknown '
          'POST outcome; verifying ${chunk.length} purchase ID(s) before '
          'leaving them pending.',
        );

        // Apps Script may still be finishing after the client loses the POST
        // response. Reads are safe to retry; the mutation is never replayed
        // inside this reconciliation path.
        for (var attempt = 1; attempt <= 2 && !chunkConfirmed; attempt++) {
          await Future<void>.delayed(Duration(seconds: attempt == 1 ? 2 : 4));

          try {
            var allMatch = true;
            for (var i = 0; i < chunk.length; i++) {
              final remote = await fetchPurchaseById(chunkIds[i]);
              if (remote == null ||
                  !_purchaseSnapshotMatchesRemote(chunk[i], remote)) {
                allMatch = false;
                break;
              }
            }

            if (allMatch) {
              chunkConfirmed = true;
              reconciled = true;
              print(
                '✅ Purchases chunk ${(offset ~/ chunkSize) + 1} confirmed '
                'after unknown POST outcome. POST was not replayed.',
              );
            }
          } catch (e) {
            lastError =
                'Purchase reconciliation attempt $attempt/2 was inconclusive: $e';
            print('⚠️ $lastError');
          }
        }
      }

      if (!chunkConfirmed) {
        lastError =
            result['message']?.toString() ??
            (lastError.isNotEmpty ? lastError : 'Purchase chunk unconfirmed.');
        return {
          'success': false,
          'newCount': added,
          'updatedCount': updated,
          'duplicateCount': duplicateCount,
          'duplicates': duplicates,
          'processed': processed,
          'confirmedIds': confirmedIds.toList(),
          'failedIds': allIds
              .where((id) => !confirmedIds.contains(id))
              .toList(),
          'message': lastError,
          'code': result['code'],
          'lastError': lastError,
        };
      }

      _invalidateCachesAfterMutation('syncPurchases');
      confirmedIds.addAll(chunkIds);

      // When reconciliation proves the rows exist, the original POST response
      // was intentionally unavailable, so aggregate insert/update counters are
      // unknown. Confirmation, not those counters, is what permits local ACK.
      if (!reconciled) {
        added += (result['newCount'] as num? ?? 0).toInt();
        updated += (result['updatedCount'] as num? ?? 0).toInt();
        duplicateCount += (result['duplicateCount'] as num? ?? 0).toInt();
        final remoteDuplicates = result['duplicates'];
        if (remoteDuplicates is List) {
          duplicates.addAll(
            remoteDuplicates.whereType<Map>().map(
              (r) => Map<String, dynamic>.from(r),
            ),
          );
        }
      }

      processed += chunk.length;
      onProgress?.call(processed, snapshots.length);
    }

    final failed = allIds.where((id) => !confirmedIds.contains(id)).toList();
    final success = failed.isEmpty;
    return {
      'success': success,
      'newCount': added,
      'updatedCount': updated,
      'duplicateCount': duplicateCount,
      'duplicates': duplicates,
      'processed': processed,
      'confirmedIds': confirmedIds.toList(),
      'failedIds': failed,
      'message': success ? 'Confirmed $processed purchase records.' : lastError,
      'lastError': lastError,
    };
  }

  bool _purchaseSnapshotMatchesRemote(
    Map<String, dynamic> expected,
    Map<String, dynamic> remote,
  ) {
    String text(dynamic value) => (value ?? '').toString().trim();

    bool numberEqual(dynamic a, dynamic b) {
      num? parse(dynamic value) {
        if (value is num) return value;
        final cleaned = text(value).replaceAll(RegExp(r'[^0-9.+-]'), '');
        return num.tryParse(cleaned);
      }

      final left = parse(a);
      final right = parse(b);
      if (left == null || right == null) return text(a) == text(b);
      return (left.toDouble() - right.toDouble()).abs() <= 0.0001;
    }

    const stringFields = <String>[
      'purchases_ID',
      'invoiceDetailsID',
      'GRV Reference',
      'supplierID',
      'Supplier',
      'Barcode',
      'Purchased Product Name',
      'purSupplierBottleID',
      'Main Category',
      'Category',
      'UoM',
      'Case/Pack Size',
    ];

    for (final field in stringFields) {
      final expVal = text(expected[field]);
      final remVal = text(remote[field]);
      if (expVal != remVal) {
        // 🔥 NEW: Fallback to numeric comparison if both parse successfully
        final expNum = double.tryParse(expVal);
        final remNum = double.tryParse(remVal);
        if (expNum == null || remNum == null || expNum != remNum) {
          print(
            '⚠️ Purchase mismatch on string field "$field": expected="$expVal", remote="$remVal"',
          );
          return false;
        }
      }
    }

    const numericFields = <String>[
      'Single Unit Volume',
      'Cost Per Bottle',
      'Qty Purchased',
      'Purchases Bottles',
      'Purchase Units',
    ];

    for (final field in numericFields) {
      if (!numberEqual(expected[field], remote[field])) {
        print(
          '⚠️ Purchase mismatch on numeric field "$field": expected="${expected[field]}", remote="${remote[field]}"',
        );
        return false;
      }
    }

    return true;
  }

  // ---------------------------------------------------------------------------
  // Store Sales Data
  // ---------------------------------------------------------------------------

  /// Sync raw StoreSalesData rows.
  ///
  /// Each record must contain:
  /// {
  ///   'salesID': 'unique-row-id',
  ///   'values': [14 positional values from columns A:N]
  /// }
  ///
  /// The positional representation is intentional because StoreSalesData
  /// contains two columns both named "Discounts".
  Future<Map<String, dynamic>> syncStoreSalesData(
    List<Map<String, dynamic>> rows, {
    void Function(int completed, int total)? onProgress,
  }) async {
    if (rows.isEmpty) {
      return {
        'success': true,
        'syncedIds': <String>[],
        'processedCount': 0,
        'totalReceived': 0,
        'inserted': 0,
        'updated': 0,
      };
    }

    const chunkSize = 400;

    final syncedIds = <String>[];
    var totalInserted = 0;
    var totalUpdated = 0;
    var processed = 0;

    for (var start = 0; start < rows.length; start += chunkSize) {
      final end = math.min(start + chunkSize, rows.length);
      final chunk = rows.sublist(start, end);

      final result = await _sendPostRequest('syncStoreSalesData', {
        'endpoint': 'syncStoreSalesData',
        'data': chunk,
      });

      var confirmed = result['success'] == true;

      final code = result['code']?.toString() ?? '';

      final unknownOutcome = {
        'OUTCOME_UNKNOWN',
        'HTTP_ERROR',
        'POST_ROUTE_MISMATCH',
      }.contains(code);

      // ------------------------------------------------------------
      // Ambiguous POST:
      // NEVER blindly replay it here.
      // Verify each salesID against authoritative server state.
      // ------------------------------------------------------------

      if (!confirmed && unknownOutcome) {
        print(
          '🔎 StoreSalesData chunk has an unknown POST outcome; '
          'verifying salesIDs before failing.',
        );

        for (var attempt = 1; attempt <= 2 && !confirmed; attempt++) {
          await Future.delayed(Duration(seconds: attempt == 1 ? 2 : 4));

          try {
            var allPresent = true;

            for (final record in chunk) {
              final salesId = (record['salesID'] ?? '').toString().trim();

              if (salesId.isEmpty) {
                allPresent = false;
                break;
              }

              final remote = await fetchStoreSaleById(salesId);

              if (remote == null) {
                allPresent = false;
                break;
              }
            }

            if (allPresent) {
              confirmed = true;

              print(
                '✅ StoreSalesData chunk confirmed from server '
                'after unknown POST outcome.',
              );
            }
          } catch (e) {
            print(
              '⚠️ Could not reconcile StoreSalesData '
              'attempt $attempt/2: $e',
            );
          }
        }
      }

      if (!confirmed) {
        return {
          'success': false,
          'syncedIds': syncedIds,
          'processedCount': processed,
          'totalReceived': rows.length,
          'inserted': totalInserted,
          'updated': totalUpdated,
          'code': result['code'],
          'message':
              result['message'] ??
              'StoreSalesData upload could not be confirmed.',
        };
      }

      final responseIds = result['syncedIds'];

      if (responseIds is List) {
        syncedIds.addAll(responseIds.map((e) => e.toString()));
      } else {
        // Reconciled response may not contain the original POST receipt.
        syncedIds.addAll(chunk.map((row) => row['salesID'].toString()));
      }

      totalInserted += int.tryParse('${result['inserted'] ?? 0}') ?? 0;

      totalUpdated += int.tryParse('${result['updated'] ?? 0}') ?? 0;

      processed += chunk.length;

      onProgress?.call(processed, rows.length);
    }

    return {
      'success': true,
      'syncedIds': syncedIds,
      'processedCount': processed,
      'totalReceived': rows.length,
      'inserted': totalInserted,
      'updated': totalUpdated,
      'message': 'Confirmed $processed StoreSalesData rows.',
    };
  }

  /// Fetch one StoreSalesData row using its stable salesID.
  Future<Map<String, dynamic>?> fetchStoreSaleById(String salesId) async {
    final cleanId = salesId.trim();

    if (cleanId.isEmpty) {
      return null;
    }

    return fetchRecordById('StoreSalesData', cleanId);
  }

  /// Sync stock counts with chunking, retry, and progress reporting
  Future<Map<String, dynamic>> syncStockCountsWithChunking(
    List<Map<String, dynamic>> counts, {
    Function(int processed, int total)? onProgress,
    int chunkSize = 200,
  }) async {
    if (chunkSize < 1 || chunkSize > 500) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be 1 to 500');
    }
    final snapshots = counts.map((c) => Map<String, dynamic>.from(c)).toList();
    final allIds = snapshots
        .map(
          (c) => (c['id'] ?? c['stock_id'] ?? c['stockId'] ?? '')
              .toString()
              .trim(),
        )
        .toList();
    if (allIds.any((id) => id.isEmpty) ||
        allIds.toSet().length != allIds.length) {
      logger?.error(
        '❌ Stock sync rejected before POST: missing or repeated stock IDs. '
        'records=${snapshots.length}',
      );
      return {
        'success': false,
        'syncedIds': <String>[],
        'failedIds': allIds,
        'message': 'Missing or repeated stock IDs in the submitted batch.',
      };
    }
    final confirmed = <String>{};
    final outcomes = <String, String>{};
    String lastError = '';
    final chunkTotal = (snapshots.length / chunkSize).ceil();

    for (int offset = 0; offset < snapshots.length; offset += chunkSize) {
      if (_isDisposed) {
        lastError = 'Service disposed during stock sync.';
        break;
      }
      final end = math.min(offset + chunkSize, snapshots.length);
      final chunk = snapshots
          .sublist(offset, end)
          .map(_mapStockCountForSheet)
          .toList();
      final expected = allIds.sublist(offset, end).toSet();
      final chunkIndex = offset ~/ chunkSize;

      // One logical transaction per chunk. Retries of THIS chunk reuse this
      // transaction ID, but a later edit/replay invocation gets a fresh ID.
      // stockTake_ID remains the stable row identity; transactionId is only
      // the request/receipt identity.
      final transaction = _generateUuid();

      logger?.info(
        '📦 Stock sync chunk ${chunkIndex + 1}/$chunkTotal: '
        'records=${chunk.length}, transactionId=$transaction',
      );

      for (int attempt = 0; attempt < 3; attempt++) {
        if (_isDisposed) {
          lastError = 'Service disposed during stock sync.';
          break;
        }
        if (attempt > 0) await Future.delayed(Duration(seconds: attempt * 2));

        logger?.info(
          '➡️ Stock POST chunk ${chunkIndex + 1}/$chunkTotal '
          'attempt ${attempt + 1}/3: transactionId=$transaction',
        );

        try {
          final result = await _sendPostRequest('syncStockCounts', {
            'endpoint': 'syncStockCounts',
            'data': chunk,
            'transactionId': transaction,
            'chunkIndex': chunkIndex,
            'chunkTotal': chunkTotal,
            'retry': attempt,
          });

          final receiptVersion = result['receiptVersion'];
          final code = result['code']?.toString() ?? '';
          final message = result['message']?.toString() ?? '';
          final syncedCount = result['syncedIds'] is List
              ? (result['syncedIds'] as List).length
              : 0;
          final failedCount = result['failedIds'] is List
              ? (result['failedIds'] as List).length
              : 0;
          final outcomeCount = result['outcomes'] is Map
              ? (result['outcomes'] as Map).length
              : 0;

          logger?.info(
            '⬅️ Stock POST result chunk ${chunkIndex + 1}/$chunkTotal '
            'attempt ${attempt + 1}/3: success=${result['success'] == true}, '
            'code=${code.isEmpty ? 'none' : code}, '
            'receiptVersion=${receiptVersion ?? 'none'}, '
            'syncedIds=$syncedCount, failedIds=$failedCount, '
            'outcomes=$outcomeCount, replayed=${result['replayed'] == true}, '
            'transactionId=$transaction',
          );

          if (receiptVersion != 2 &&
              [
                'OUTCOME_UNKNOWN',
                'HTTP_ERROR',
                'LOCK_TIMEOUT',
              ].contains(code)) {
            lastError = message.isNotEmpty
                ? message
                : 'Stock request unconfirmed';
            logger?.info(
              '⏳ Stock chunk ${chunkIndex + 1}/$chunkTotal remains '
              'unconfirmed after attempt ${attempt + 1}/3; '
              'retrying same transactionId if attempts remain. '
              'code=${code.isEmpty ? 'none' : code}',
            );
            continue;
          }
          if (receiptVersion != 2 || result['syncedIds'] is! List) {
            lastError =
                'Server did not return version-2 stock acknowledgements. Deploy the GAS patch first.';
            logger?.error(
              '❌ Stock chunk ${chunkIndex + 1}/$chunkTotal cannot be '
              'acknowledged: receiptVersion=${receiptVersion ?? 'none'}, '
              'syncedIdsType=${result['syncedIds'].runtimeType}, '
              'code=${code.isEmpty ? 'none' : code}, '
              'transactionId=$transaction',
            );
            break; // Never infer acknowledgement from status or aggregate counts.
          }
          final ids = (result['syncedIds'] as List)
              .map((v) => v.toString())
              .toSet();
          if (!expected.containsAll(ids)) {
            lastError = 'Server returned IDs that were not in this chunk.';
            logger?.error(
              '❌ Stock receipt contained unexpected IDs: '
              'expected=${expected.length}, returned=${ids.length}, '
              'transactionId=$transaction',
            );
            break;
          }
          final remoteOutcomes = result['outcomes'];
          for (final id in ids) {
            if (confirmed.add(id) && remoteOutcomes is Map) {
              outcomes[id] = remoteOutcomes[id]?.toString() ?? 'confirmed';
            }
          }

          final chunkConfirmed = expected.where(confirmed.contains).length;
          logger?.info(
            '✅ Stock receipt processed chunk ${chunkIndex + 1}/$chunkTotal: '
            'confirmed=$chunkConfirmed/${expected.length}, '
            'transactionId=$transaction',
          );

          if (confirmed.containsAll(expected)) break;
          lastError = message.isNotEmpty
              ? message
              : 'Some stock records were not confirmed.';
          if (code == 'INVALID_INPUT' ||
              code == 'INVALID_STORE' ||
              code == 'TRANSACTION_CONFLICT') {
            logger?.error(
              '❌ Stock chunk ${chunkIndex + 1}/$chunkTotal stopped on '
              'non-retryable code=$code, transactionId=$transaction',
            );
            break;
          }
        } catch (e) {
          lastError = e.toString();
          logger?.error(
            '❌ Stock POST exception chunk ${chunkIndex + 1}/$chunkTotal '
            'attempt ${attempt + 1}/3, transactionId=$transaction: $e',
          );
        }
      }

      final chunkUnconfirmed = expected
          .where((id) => !confirmed.contains(id))
          .toList();
      if (chunkUnconfirmed.isNotEmpty) {
        final preview = chunkUnconfirmed.take(5).join(', ');
        logger?.info(
          '⚠️ Stock chunk ${chunkIndex + 1}/$chunkTotal finished with '
          '${chunkUnconfirmed.length}/${expected.length} unconfirmed. '
          'first=${preview.isEmpty ? 'none' : preview}',
        );
      }
      onProgress?.call(confirmed.length, snapshots.length);
    }
    final failed = allIds.where((id) => !confirmed.contains(id)).toList();
    final success = failed.isEmpty;

    logger?.info(
      '🏁 Stock sync acknowledgement summary: confirmed=${confirmed.length}/'
      '${snapshots.length}, failed=${failed.length}, success=$success'
      '${lastError.isEmpty ? '' : ', lastError=$lastError'}',
    );

    return {
      'success': success,
      'count': outcomes.values.where((v) => v == 'inserted').length,
      'updated': outcomes.values.where((v) => v == 'updated').length,
      'deleted': outcomes.values.where((v) => v == 'deleted').length,
      'syncedIds': confirmed.toList(),
      'failedIds': failed,
      'totalAttempted': snapshots.length,
      'totalConfirmed': confirmed.length,
      'message': success
          ? 'Confirmed ${confirmed.length} stock records.'
          : lastError,
    };
  }

  /// Sync PLU mappings with chunking
  Future<Map<String, dynamic>> syncPluMappingsWithChunking(
    List<Map<String, dynamic>> mappings, {
    Function(int processed, int total)? onProgress,
    int chunkSize = 50,
  }) async {
    if (mappings.isEmpty) {
      return {
        'success': true,
        'newCount': 0,
        'updatedCount': 0,
        'message': 'No mappings to sync',
      };
    }

    print('🔗 Syncing ${mappings.length} PLU mappings in chunks of $chunkSize');

    int totalNew = 0;
    int totalUpdated = 0;
    bool allSuccessful = true;
    String lastError = '';
    int processedCount = 0;

    for (var i = 0; i < mappings.length; i += chunkSize) {
      if (_isDisposed) {
        return {
          'success': false,
          'newCount': totalNew,
          'updatedCount': totalUpdated,
          'message': 'Service disposed during sync',
        };
      }

      final end = (i + chunkSize).clamp(0, mappings.length);
      final chunk = mappings.sublist(i, end);
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (mappings.length / chunkSize).ceil();

      print(
        '🔗 Syncing PLU chunk $chunkNumber/$totalChunks (${chunk.length} records)',
      );

      final mappedChunk = chunk.map(_mapCommonFieldsForSheet).toList();

      try {
        final result = await _sendPostRequest('syncPluMappings', {
          'endpoint': 'syncPluMappings',
          'data': mappedChunk,
        });

        if (result['success'] == true) {
          totalNew += (result['newCount'] ?? 0) as int;
          totalUpdated += (result['updatedCount'] ?? 0) as int;
          processedCount += chunk.length;
          onProgress?.call(processedCount, mappings.length);
          print(
            '✅ Chunk $chunkNumber complete: +${result['newCount']} new, ${result['updatedCount']} updated, ${result['deleted'] ?? 0} deleted',
          );
        } else {
          allSuccessful = false;
          lastError =
              result['message'] ?? 'Unknown error in chunk $chunkNumber';
          print('⚠️ Chunk $chunkNumber failed: $lastError');
        }
      } catch (e) {
        allSuccessful = false;
        lastError = e.toString();
        print('❌ Chunk $chunkNumber exception: $e');
      }

      if (i + chunkSize < mappings.length) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    return {
      'success': allSuccessful,
      'newCount': totalNew,
      'updatedCount': totalUpdated,
      'message': allSuccessful
          ? 'Synced ${mappings.length} mappings successfully'
          : 'Completed with errors: $lastError',
      'lastError': lastError,
    };
  }

  /// Sync locations with chunking
  Future<Map<String, dynamic>> syncNewLocationsWithChunking(
    List<Map<String, dynamic>> locations, {
    Function(int processed, int total)? onProgress,
    int chunkSize = 50,
  }) async {
    if (locations.isEmpty) {
      return {'success': true, 'count': 0, 'message': 'No locations to sync'};
    }

    print('📍 Syncing ${locations.length} locations in chunks of $chunkSize');

    int totalAdded = 0;
    bool allSuccessful = true;
    String lastError = '';
    int processedCount = 0;

    for (var i = 0; i < locations.length; i += chunkSize) {
      if (_isDisposed) {
        return {
          'success': false,
          'count': totalAdded,
          'message': 'Service disposed during sync',
        };
      }

      final end = (i + chunkSize).clamp(0, locations.length);
      final chunk = locations.sublist(i, end);
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (locations.length / chunkSize).ceil();

      print(
        '📍 Syncing location chunk $chunkNumber/$totalChunks (${chunk.length} records)',
      );

      final mappedChunk = chunk.map(_mapCommonFieldsForSheet).toList();

      try {
        final result = await _sendPostRequest('syncNewLocations', {
          'endpoint': 'syncNewLocations',
          'data': mappedChunk,
        });

        if (result['success'] == true) {
          totalAdded += (result['count'] ?? 0) as int;
          processedCount += chunk.length;
          onProgress?.call(processedCount, locations.length);
          print(
            '✅ Chunk $chunkNumber complete: +${result['count'] ?? 0} locations, ${result['deleted'] ?? 0} deleted',
          );
        } else {
          allSuccessful = false;
          lastError =
              result['message'] ?? 'Unknown error in chunk $chunkNumber';
          print('⚠️ Chunk $chunkNumber failed: $lastError');
        }
      } catch (e) {
        allSuccessful = false;
        lastError = e.toString();
        print('❌ Chunk $chunkNumber exception: $e');
      }

      if (i + chunkSize < locations.length) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    return {
      'success': allSuccessful,
      'count': totalAdded,
      'message': allSuccessful
          ? 'Synced ${locations.length} locations successfully'
          : 'Completed with errors: $lastError',
      'lastError': lastError,
    };
  }

  /// Sync new products with chunking.
  ///
  /// A transport timeout does not prove that Apps Script failed to commit the
  /// write. For an unknown outcome we do NOT replay the POST. Instead, we make
  /// a bounded read-after-write check against Inventory. This version uses the
  /// targeted Inventory GET endpoint to prevent multi-minute hangs on large stores.
  Future<Map<String, dynamic>> syncNewProductsWithChunking(
    List<Map<String, dynamic>> products, {
    Function(int processed, int total)? onProgress,
    int chunkSize = 10,
  }) async {
    if (products.isEmpty) {
      return {'success': true, 'count': 0, 'message': 'No products to sync'};
    }

    print('🆕 Syncing ${products.length} products in chunks of $chunkSize');

    int totalAdded = 0;
    bool allSuccessful = true;
    String lastError = '';
    int processedCount = 0;

    for (var i = 0; i < products.length; i += chunkSize) {
      if (_isDisposed) {
        return {
          'success': false,
          'count': totalAdded,
          'message': 'Service disposed during sync',
        };
      }

      final end = (i + chunkSize).clamp(0, products.length);
      final chunk = products.sublist(i, end);
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (products.length / chunkSize).ceil();

      print(
        '🆕 Syncing product chunk $chunkNumber/$totalChunks (${chunk.length} records)',
      );

      final mappedChunk = chunk.map(_mapCommonFieldsForSheet).toList();

      try {
        final result = await _sendPostRequest('syncNewProducts', {
          'endpoint': 'syncNewProducts',
          'data': mappedChunk,
        });

        bool confirmed = result['success'] == true;
        bool reconciled = false;
        final code = result['code']?.toString() ?? '';
        final unknownOutcome = {
          'OUTCOME_UNKNOWN',
          'HTTP_ERROR',
          'POST_ROUTE_MISMATCH',
        }.contains(code);

        if (!confirmed && unknownOutcome) {
          print(
            '🔎 NewProducts chunk $chunkNumber has an unknown POST outcome; '
            'checking Inventory before leaving it pending.',
          );

          // Apps Script can still be finishing the write when the client-side
          // POST times out. Give it a short grace period, then make at most two
          // authoritative checks. We never replay the mutation here.
          for (var attempt = 1; attempt <= 2 && !confirmed; attempt++) {
            await Future.delayed(Duration(seconds: attempt == 1 ? 2 : 4));

            try {
              // 🔥 OPTIMIZED: Use targeted lookup instead of downloading the entire
              // Inventory table. This prevents 4+ minute hangs on large stores
              // during unknown-outcome reconciliation.
              var allPresent = true;
              for (final product in mappedChunk) {
                final barcode = (product['Barcode'] ?? '').toString().trim();
                final expectedName = (product['Inventory Product Name'] ?? '')
                    .toString()
                    .trim();

                if (barcode.isEmpty) {
                  allPresent = false;
                  break;
                }

                final remote = await fetchRecordById('Inventory', barcode);
                if (remote == null) {
                  allPresent = false;
                  break;
                }

                final serverName = (remote['Inventory Product Name'] ?? '')
                    .toString()
                    .trim();

                // 🔥 STRICTER: Require the server name to match the expected name
                // if an expected name was provided. This prevents false positives
                // where a barcode exists but points to a different/legacy product.
                if (expectedName.isNotEmpty && serverName != expectedName) {
                  allPresent = false;
                  print(
                    '⚠️ Inventory mismatch for barcode $barcode: '
                    'expected name="$expectedName", remote="$serverName"',
                  );
                  break;
                }
              }

              if (allPresent) {
                confirmed = true;
                reconciled = true;
                print(
                  '✅ NewProducts chunk $chunkNumber confirmed from Inventory '
                  'after unknown POST outcome; POST was not replayed.',
                );
              } else {
                print(
                  '⏳ NewProducts reconciliation attempt $attempt/2 did not '
                  'find every expected barcode yet.',
                );
              }
            } catch (verificationError) {
              // A failed GET is also inconclusive. Do not convert it into a
              // mutation failure and do not replay the POST.
              print(
                '⚠️ NewProducts reconciliation attempt $attempt/2 could not '
                'verify Inventory: $verificationError',
              );
            }
          }
        }

        if (confirmed) {
          final added = result['added'];
          if (added is int) totalAdded += added;
          processedCount += chunk.length;
          onProgress?.call(processedCount, products.length);
          print(
            reconciled
                ? '✅ Chunk $chunkNumber complete: server state confirmed after unknown POST outcome'
                : '✅ Chunk $chunkNumber complete: +${result['added'] ?? 0} products, ${result['deleted'] ?? 0} deleted',
          );
        } else {
          allSuccessful = false;
          lastError =
              result['message'] ?? 'Unknown error in chunk $chunkNumber';
          print('⚠️ Chunk $chunkNumber failed: $lastError');
        }
      } catch (e) {
        allSuccessful = false;
        lastError = e.toString();
        print('❌ Chunk $chunkNumber exception: $e');
      }

      if (i + chunkSize < products.length) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    return {
      'success': allSuccessful,
      'count': totalAdded,
      'message': allSuccessful
          ? 'Synced ${products.length} products successfully'
          : 'Completed with errors: $lastError',
      'lastError': lastError,
    };
  }

  // ---------------------------------------------------------------------------
  // Delete Operations
  // ---------------------------------------------------------------------------

  Future<bool> deleteInvoice(String invoiceId) async {
    final cleanInvoiceId = invoiceId.trim();
    if (cleanInvoiceId.isEmpty) return false;

    final result = await _sendPostRequest('deleteInvoice', {
      'endpoint': 'deleteInvoice',
      'data': {'invoiceId': cleanInvoiceId},
    });

    if (result['success'] == true) return true;

    final code = result['code']?.toString() ?? '';
    final unknownOutcome = {
      'OUTCOME_UNKNOWN',
      'HTTP_ERROR',
      'POST_ROUTE_MISMATCH',
    }.contains(code);

    if (!unknownOutcome) return false;

    print(
      '🔎 deleteInvoice has an unknown POST outcome; verifying invoice and '
      'linked purchases before confirming deletion.',
    );

    // Never replay an ambiguous delete. Read server state instead.
    // Two bounded checks allow Apps Script a short period to finish a commit
    // whose HTTP response was lost or timed out.
    for (var attempt = 1; attempt <= 2; attempt++) {
      await Future.delayed(Duration(seconds: attempt == 1 ? 2 : 4));

      try {
        final invoice = await fetchInvoiceById(cleanInvoiceId);
        if (invoice != null) {
          print(
            '⏳ deleteInvoice reconciliation $attempt/2: invoice still exists.',
          );
          continue;
        }

        // Invoice is gone. Confirm the server-side cascade using the targeted
        // Purchases.invoiceDetailsID existence lookup. Do not download the
        // entire Purchases table and do not replay the mutation.
        final linkedPurchaseExists = await hasPurchasesForInvoice(
          cleanInvoiceId,
        );

        if (!linkedPurchaseExists) {
          print(
            '✅ deleteInvoice confirmed after unknown POST outcome; invoice '
            'and linked purchases are absent. POST was not replayed.',
          );
          return true;
        }

        print(
          '⏳ deleteInvoice reconciliation $attempt/2: invoice is absent but '
          'linked purchases still exist.',
        );
      } catch (verificationError) {
        // A failed GET is inconclusive. Keep the deletion unconfirmed and,
        // critically, do not replay the mutation.
        print(
          '⚠️ deleteInvoice reconciliation $attempt/2 could not verify server '
          'state: $verificationError',
        );
      }
    }

    print(
      '⚠️ deleteInvoice remains unconfirmed after reconciliation; mutation '
      'was not replayed.',
    );
    return false;
  }

  Future<bool> deletePurchase(String purchaseId) async {
    final result = await _sendPostRequest('deletePurchase', {
      'endpoint': 'deletePurchase',
      'data': {'purchaseId': purchaseId},
    });

    if (result['success'] == true) return true;

    final code = result['code']?.toString() ?? '';
    final unknownOutcome = {
      'OUTCOME_UNKNOWN',
      'HTTP_ERROR',
      'POST_ROUTE_MISMATCH',
    }.contains(code);

    if (unknownOutcome) {
      print(
        '🔎 deletePurchase has an unknown POST outcome; verifying deletion before failing.',
      );
      await Future.delayed(const Duration(seconds: 2));

      final remote = await fetchPurchaseById(purchaseId);
      if (remote == null) {
        print(
          '✅ deletePurchase confirmed after unknown POST outcome; record is absent.',
        );
        return true;
      }
    }

    return false;
  }

  Future<bool> deletePurchases(List<String> purchaseIds) async {
    if (purchaseIds.isEmpty) return true;

    final result = await _sendPostRequest('deletePurchases', {
      'endpoint': 'deletePurchases',
      'data': {'purchaseIds': purchaseIds},
    });

    if (result['success'] == true) return true;

    final code = result['code']?.toString() ?? '';

    // 🔥 NEW: Diagnostic print to reveal why the server rejected the deletion
    print(
      '⚠️ deletePurchases initial result: success=${result['success']}, code=$code, message=${result['message']}',
    );

    final unknownOutcome = {
      'OUTCOME_UNKNOWN',
      'HTTP_ERROR',
      'POST_ROUTE_MISMATCH',
    }.contains(code);

    if (unknownOutcome) {
      print(
        '🔎 deletePurchases has an unknown POST outcome; verifying deletions before failing.',
      );
      await Future.delayed(const Duration(seconds: 2));

      var allGone = true;
      for (final id in purchaseIds) {
        final remote = await fetchPurchaseById(id);
        if (remote != null) {
          allGone = false;
          break;
        }
      }

      if (allGone) {
        print(
          '✅ deletePurchases confirmed after unknown POST outcome; records are absent.',
        );
        return true;
      }
    }

    return false;
  }

  Future<bool> deleteInvoices(List<String> invoiceIds) async {
    if (invoiceIds.isEmpty) return true;

    print('📦 Deleting ${invoiceIds.length} invoices sequentially');
    bool allSuccessful = true;
    int failedCount = 0;

    for (var i = 0; i < invoiceIds.length; i++) {
      final id = invoiceIds[i];
      try {
        final result = await deleteInvoice(id);
        if (!result) {
          allSuccessful = false;
          failedCount++;
          print('⚠️ Failed to delete invoice $id');
        }

        if ((i + 1) % 10 == 0) {
          print('📊 Deleted ${i + 1}/${invoiceIds.length} invoices');
        }

        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e) {
        allSuccessful = false;
        failedCount++;
        print('❌ Error deleting invoice $id: $e');
      }
    }

    print(
      '✅ Invoice deletion: ${invoiceIds.length - failedCount} succeeded, $failedCount failed',
    );
    return allSuccessful;
  }

  Future<bool> updateInvoice(Map<String, dynamic> invoice) async {
    final mapped = _mapInvoiceFields(invoice);
    final result = await _sendPostRequest('updateInvoice', {
      'endpoint': 'updateInvoice',
      'data': mapped,
    });

    if (result['success'] == true) return true;

    final code = result['code']?.toString() ?? '';
    final unknownOutcome = {
      'OUTCOME_UNKNOWN',
      'HTTP_ERROR',
      'POST_ROUTE_MISMATCH',
    }.contains(code);

    if (unknownOutcome) {
      print(
        '🔎 updateInvoice has an unknown POST outcome; verifying before failing.',
      );
      await Future.delayed(const Duration(seconds: 2));

      final invId = mapped['invoiceDetailsID']?.toString();
      if (invId != null) {
        final remote = await fetchInvoiceById(invId);
        if (remote != null) {
          // Verify key fields match to ensure the update actually applied
          final expInvNum = mapped['Invoice Number']?.toString().trim();
          final remInvNum = remote['Invoice Number']?.toString().trim();
          if (expInvNum != null &&
              remInvNum != null &&
              expInvNum != remInvNum) {
            print(
              '⚠️ updateInvoice verification failed: Invoice Number mismatch',
            );
            return false;
          }
          print(
            '✅ updateInvoice confirmed after unknown POST outcome; POST was not replayed.',
          );
          return true;
        }
      }
    }

    print(
      '⚠️ updateInvoice failed. Server response: ${result['message']} (Code: $code)',
    );
    return false;
  }

  Future<bool> updatePurchase(Map<String, dynamic> purchase) async {
    final result = await _sendPostRequest('updatePurchase', {
      'endpoint': 'updatePurchase',
      'data': purchase,
    });

    if (result['success'] == true) return true;

    final code = result['code']?.toString() ?? '';
    final unknownOutcome = {
      'OUTCOME_UNKNOWN',
      'HTTP_ERROR',
      'POST_ROUTE_MISMATCH',
    }.contains(code);

    if (unknownOutcome) {
      print(
        '🔎 updatePurchase has an unknown POST outcome ($code); verifying before failing.',
      );
      await Future.delayed(const Duration(seconds: 2));

      final purchaseId = purchase['purchases_ID']?.toString();
      if (purchaseId != null) {
        final remote = await fetchPurchaseById(purchaseId);
        if (remote != null) {
          // 🔥 REUSE: Use the same robust numeric-aware matching logic
          // that successfully handles "3.0" vs "3" in the chunked sync.
          if (_purchaseSnapshotMatchesRemote(purchase, remote)) {
            print(
              '✅ updatePurchase confirmed after unknown POST outcome; POST was not replayed.',
            );
            return true;
          } else {
            print(
              '⚠️ updatePurchase verification failed: fields do not match remote state.',
            );
            return false;
          }
        } else {
          print(
            '⚠️ updatePurchase verification failed: Purchase not found after update.',
          );
        }
      }
    }

    print(
      '⚠️ updatePurchase failed. Server response: ${result['message']} (Code: $code)',
    );
    return false;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _mapCommonFieldsForSheet(Map<String, dynamic> c) {
    final item = Map<String, dynamic>.from(c);

    final rawCreated = c['createdAt'] ?? c['created_at'];
    final rawUpdated = c['updatedAt'] ?? c['updated_at'] ?? rawCreated;
    final rawSynced = c['syncedAt'] ?? c['synced_at'];

    if (rawCreated != null) {
      item['created_at'] = _formatTimestampUtc(rawCreated);
    }
    if (rawUpdated != null) {
      item['updated_at'] = _formatTimestampUtc(rawUpdated);
    }
    if (rawSynced != null) {
      item['synced_at'] = _formatTimestampUtc(rawSynced);
    }

    return item;
  }

  Map<String, dynamic> _mapStockCountForSheet(Map<String, dynamic> c) {
    final item = Map<String, dynamic>.from(c);
    final id = (c['id'] ?? c['stock_id'] ?? c['stockId'] ?? '')
        .toString()
        .trim();
    item['id'] = id;
    item['stock_id'] = id;
    item['deleted'] =
        c['syncStatus'] == 'deleted' ||
        c['deleted'] == true ||
        c['deleted'] == 'true';

    // Audit timestamps: ISO-8601 UTC
    for (final pair in [
      ['createdAt', 'created_at'],
      ['updatedAt', 'updated_at'],
    ]) {
      final value = c[pair[0]] ?? c[pair[1]];
      if (value != null) {
        final serialized = _formatTimestampUtc(value);
        item[pair[0]] = serialized;
        item[pair[1]] = serialized;
      }
    }

    // Business Audit Date: strictly yyyy-MM-dd
    if (item['Date'] != null) {
      item['Date'] = _formatCalendarDate(item['Date']);
    } else if (item['date'] != null) {
      item['date'] = _formatCalendarDate(item['date']);
    }

    return item;
  }

  String _formatDateTimeForSheet(dynamic value) {
    if (value == null || value.toString().isEmpty) return '';

    DateTime? dt;
    if (value is DateTime) {
      dt = value;
    } else if (value is String) {
      dt = DateTime.tryParse(value);
      if (dt == null) return value; // Already formatted or invalid
    } else {
      return value.toString();
    }

    // Format to dd/MM/yyyy HH:mm:ss
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');

    return '$day/$month/$year $hour:$minute:$second';
  }

  /// Maps purchase fields, normalizes calendar dates to yyyy-MM-dd,
  /// and writes the generated ID back to the input map for retry idempotency.
  Map<String, dynamic> _mapPurchaseFields(Map<String, dynamic> p) {
    final item = Map<String, dynamic>.from(p);

    // Idempotency: Mutate source purchase so ID persists across retries
    if (item['purchases_ID'] == null ||
        item['purchases_ID'].toString().isEmpty) {
      final generatedId = _generateUuid();
      item['purchases_ID'] = generatedId;
      p['purchases_ID'] = generatedId;
    }
    if (item['syncStatus'] == null) {
      item['syncStatus'] = 'synced';
    }

    // Format calendar dates to yyyy-MM-dd
    if (item['Date'] != null) {
      item['Date'] = _formatCalendarDate(item['Date']);
    }
    if (item['Inv. Date of Purchase'] != null) {
      item['Inv. Date of Purchase'] = _formatCalendarDate(
        item['Inv. Date of Purchase'],
      );
    }
    if (item['Stock Delivery Date'] != null) {
      item['Stock Delivery Date'] = _formatCalendarDate(
        item['Stock Delivery Date'],
      );
    }

    // Match Apps Script's existing unit rules. Zero is a placeholder when
    // bottle quantity is nonzero; signed explicit units (credit notes) survive.
    item['Purchase Units'] = _canonicalPurchaseUnits(item);
    item['purSupplierBottleID'] ??= item['supplierBottleID'] ?? '';
    return item;
  }

  double _canonicalPurchaseUnits(Map<String, dynamic> purchase) {
    double number(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(
            (value ?? '').toString().replaceAll(RegExp(r'[^\d.-]'), ''),
          ) ??
          0;
    }

    final supplied = number(purchase['Purchase Units']);
    if (supplied != 0) return supplied;
    final bottles = number(purchase['Purchases Bottles']);
    final volume = number(purchase['Single Unit Volume']);
    final category = (purchase['Category'] ?? '').toString().toLowerCase();
    const bottleCategories = [
      'Sparkling Wine',
      'Beer',
      'Soft Drinks',
      'Coolers',
      'Cider',
      'Champagne',
      'White Wine',
      'Red Wine',
      'Rose',
      'Champagne XL',
      'Still Water',
      'Sparkling Water',
      'Whiskey',
      'Vodka',
      'Gin',
      'Tequila',
      'Rum',
      'Brandy',
      'Cognac',
      'Liqueurs',
      'Liquor',
    ];
    if (bottleCategories.any((name) => category.contains(name.toLowerCase()))) {
      return bottles;
    }
    return volume > 0 ? bottles * volume / 25 : bottles;
  }

  Map<String, dynamic> _mapInvoiceFields(Map<String, dynamic> invoice) {
    final newMap = Map<String, dynamic>.from(invoice);

    if (newMap.containsKey('Invoice Number')) {
      newMap['Invoice Number'] = newMap['Invoice Number'].toString();
    }

    if (newMap.containsKey('supplierBottleID')) {
      newMap['purSupplierBottleID'] = newMap['supplierBottleID'];
      newMap.remove('supplierBottleID');
    }

    // Idempotency: Mutate source invoice so ID persists across retries
    if (newMap['invoiceDetailsID'] == null ||
        newMap['invoiceDetailsID'].toString().isEmpty) {
      final generatedId = _generateUuid();
      newMap['invoiceDetailsID'] = generatedId;
      invoice['invoiceDetailsID'] = generatedId;
    }

    // Calendar dates: strictly yyyy-MM-dd
    if (newMap['Date of Purchase'] != null) {
      newMap['Date of Purchase'] = _formatCalendarDate(
        newMap['Date of Purchase'],
      );
    }
    if (newMap['Delivery Date'] != null) {
      newMap['Delivery Date'] = _formatCalendarDate(newMap['Delivery Date']);
    }

    return newMap;
  }

  /// Formats audit timestamps (created_at, updated_at) to ISO-8601 UTC
  String _formatTimestampUtc(dynamic value) {
    if (value == null || value.toString().isEmpty) return '';
    final dt = SafeDateUtils.parseDate(value);
    if (dt == null) return value.toString();
    return dt.toUtc().toIso8601String();
  }

  /// Formats business/calendar dates (Date of Purchase, Audit Date) to yyyy-MM-dd
  String _formatCalendarDate(dynamic value) {
    if (value == null || value.toString().isEmpty) return '';
    final dt = SafeDateUtils.parseDate(value);
    if (dt == null) return value.toString();
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Generates a 128-bit (RFC 4122 v4) cryptographically secure UUID
  String _generateUuid() {
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant RFC 4122
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  bool isValidServerId(String id) {
    // Accepts GAS 8-char Base62, 32-char hex, and standard UUID strings
    return RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id);
  }
}

// Cache Entry Class
class _CacheEntry {
  final List<Map<String, dynamic>> data;
  final DateTime timestamp;

  _CacheEntry({required this.data, required this.timestamp});
}

// Private metadata carrier; public batch methods still return lists.
class _BatchResult {
  final List<Map<String, dynamic>> rows;
  final bool? hasMore;
  final int? total;

  _BatchResult({required this.rows, this.hasMore, this.total});
}

class _RedirectFailure implements Exception {
  final String reason;
  final List<String> trace;

  _RedirectFailure(this.reason, List<String> trace)
    : trace = List<String>.unmodifiable(trace);

  @override
  String toString() => '$reason (${trace.join('; ')})';
}

class _VerifiedDownload {
  final String version;
  final List<Map<String, dynamic>> rows;
  final String? rowHash;

  _VerifiedDownload(this.version, this.rows, [this.rowHash]);
}

class TableNotFoundException implements Exception {
  final String message;

  TableNotFoundException(this.message);

  @override
  String toString() => message;
}

// Shared GAS/Dart canonical form: numbers encoded as IEEE-754 big-endian doubles.
String _downloadCanonical(Object? value) {
  if (value == null) return 'n;';
  if (value is bool) return value ? 't;' : 'f;';
  if (value is num) {
    if (!value.isFinite) return 'n;';
    final bytes = ByteData(8)
      ..setFloat64(0, value == 0 ? 0 : value.toDouble(), Endian.big);
    return 'd${List.generate(8, (i) => bytes.getUint8(i).toRadixString(16).padLeft(2, '0')).join()};';
  }
  if (value is String) return 's${value.length}:$value';
  if (value is List)
    return 'a${value.length}:[${value.map(_downloadCanonical).join()}]';
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return 'o${keys.length}:{${keys.map((k) => '${_downloadCanonical(k)}${_downloadCanonical(value[k])}').join()}}';
  }
  throw const FormatException('Unsupported download hash value');
}

String _downloadBlockHash(List<Map<String, dynamic>> rows) => sha256
    .convert(utf8.encode('hola-rows-v1|${_downloadCanonical(rows)}'))
    .toString();

String _downloadTableHash(int total, List<String> hashes) => sha256
    .convert(utf8.encode(json.encode(['hola-table-v1', 1500, total, hashes])))
    .toString();

List<String> _downloadHashes(List<Map<String, dynamic>> rows) => [
  for (int i = 0; i < rows.length; i += 1500)
    _downloadBlockHash(rows.sublist(i, math.min(i + 1500, rows.length))),
];

class _PendingDownload {
  final List<Map<String, dynamic>> rows;
  final List<String> blockHashes;
  final String rowHash;

  _PendingDownload(this.rows, this.blockHashes)
    : rowHash = _downloadTableHash(rows.length, blockHashes);
}

class _RefreshManifest {
  final Map<String, String> versions, rowHashes, missing;
  final _SalesBlockPlan? sales;

  _RefreshManifest(this.versions, this.rowHashes, this.missing, this.sales);
}

class _SalesBlockPlan {
  final int total;
  final List<String> hashes;
  final String tableHash;

  _SalesBlockPlan(this.total, this.hashes, this.tableHash);

  static _SalesBlockPlan? parse(dynamic raw, String? expectedRoot) {
    if (raw is! Map ||
        raw['protocol'] != 1 ||
        raw['blockSize'] != 1500 ||
        raw['total'] is! int ||
        (raw['total'] as int) < 0 ||
        raw['hashes'] is! List)
      return null;
    final total = raw['total'] as int;
    final hashes = raw['hashes'] as List;
    if (hashes.length != (total / 1500).ceil() ||
        hashes.any(
          (h) => h is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(h),
        ))
      return null;
    final typed = hashes.cast<String>();
    final root = _downloadTableHash(total, typed);
    if (raw['tableHash'] != root || expectedRoot != root) return null;
    return _SalesBlockPlan(total, typed, root);
  }
}

class _GasReadError extends FormatException {
  final String? code;

  _GasReadError(String message, this.code) : super('GAS error: $message');
}

class _HttpReadFailure implements Exception {
  final int status;

  _HttpReadFailure(this.status);

  @override
  String toString() => 'HTTP $status';
}
