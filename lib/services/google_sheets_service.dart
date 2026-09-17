import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'logger_service.dart';

// ============================================================================
// UTILITY: Safe Date Handling
// ============================================================================

class SafeDateUtils {
  /// Safe date parsing from various formats
  static DateTime? parseDate(dynamic value) {
    if (value == null) return null;

    if (value is DateTime) {
      return value;
    }

    if (value is String) {
      try {
        return DateTime.parse(value);
      } catch (e) {
        // Try alternative formats
        try {
          // Handle ISO format with timezone
          final cleaned = value.replaceAll('Z', '').replaceAll('+00:00', '');
          return DateTime.parse(cleaned);
        } catch (e2) {
          return null;
        }
      }
    }

    if (value is int) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(value);
      } catch (e) {
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

// ============================================================================
// GoogleSheetsService
// ============================================================================

class GoogleSheetsService {
  late http.Client _client;
  final String masterScriptUrl;
  final String storeIdentifier;
  final LoggerService? logger;
  List<Map<String, dynamic>>? _cachedMasterSuppliers;

  // Cache for frequently accessed data
  final Map<String, _CacheEntry> _cache = {};
  static const Duration cacheDuration = Duration(minutes: 5);

  // Cancellation support
  bool _isCancelled = false;

  // 🔥 Circuit breaker for failure tracking
  int _consecutiveFailures = 0;
  DateTime? _lastFailureTime;
  static const int failureThreshold = 5;
  static const Duration resetTimeout = Duration(minutes: 1);

  // 🔥 Track active clients to prevent memory leaks
  final List<http.Client> _activeClients = [];
  bool _isDisposed = false;

  // 🔥 Redirect tracking
  int _redirectCount = 0;
  static const int maxRedirects = 3;
  DateTime? _lastRecreateTime;

  // Constants
  static const int defaultBatchSize = 2000;
  static const int largeBatchSize = 3000;
  static const int defaultTimeoutSeconds = 120;
  static const int largeTableTimeoutSeconds = 180;
  static const int countTimeoutSeconds = 45;
  static const int maxRetries = 3;
  static const int chunkSize = 500;
  static const int computeThreshold = 500;

  GoogleSheetsService({
    required this.masterScriptUrl,
    required this.storeIdentifier,
    this.logger,
  }) {
    _client = _createClient();
    _activeClients.add(_client);
  }

  // 🔥 Centralized client creation
  http.Client _createClient() {
    return http.Client();
  }

  // 🔥 Proper client cleanup - removed isClosed check
  void _closeClient(http.Client client) {
    try {
      client.close();
    } catch (e) {
      // Ignore errors during cleanup
    }
  }

  // 🔥 Recreate client with proper cleanup and rate limiting
  void _recreateClient() {
    if (_isDisposed) return;

    // Don't recreate if we just recreated (within 5 seconds)
    if (_lastRecreateTime != null &&
        DateTime.now().difference(_lastRecreateTime!) < const Duration(seconds: 5)) {
      print('⏳ Skipping recreate - too soon (${DateTime.now().difference(_lastRecreateTime!).inSeconds}s ago)');
      return;
    }

    _lastRecreateTime = DateTime.now();

    try {
      _client.close();
      _activeClients.remove(_client);
    } catch (e) {
      // Ignore cleanup errors
    }

    _client = _createClient();
    _activeClients.add(_client);
    // print('🔄 Client recreated (${_activeClients.length} active)');
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    // print('🧹 Disposing GoogleSheetsService...');
    _cache.clear();

    // Close all tracked clients
    for (var client in _activeClients) {
      _closeClient(client);
    }
    _activeClients.clear();
    // print('✅ All clients closed');
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

  Future<Map<String, dynamic>> _sendPostRequest(
      String tag,
      Map<String, dynamic> jsonData,
      ) async {
    int attempt = 0;

    while (attempt <= maxRetries) {
      attempt++;
      try {
        if (_circuitBreakerOpen) {
          print('⏳ Circuit breaker OPEN, waiting 1 minute...');
          await Future.delayed(const Duration(minutes: 1));
          _resetCircuitBreaker();
        }

        // 🔥 Build payload with all required fields
        final payload = {
          'data': jsonData['data'],
          'storeIdentifier': storeIdentifier,
          'endpoint': jsonData['endpoint'] ?? tag,
          'table': jsonData['table'] ?? '',  // 🔥 Include table if provided
        };

        final body = json.encode(payload);
        final uri = Uri.parse(masterScriptUrl);

        // if (kDebugMode) {
        //   print('📤 [Attempt $attempt] POST: ${jsonData['endpoint'] ?? tag}');
        //   print('📦 Payload keys: ${payload.keys.join(', ')}');
        //   if (payload['table'] != null && payload['table'].isNotEmpty) {
        //     print('📋 Table: ${payload['table']}');
        //   }
        // }

        var response = await _client.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: body,
        ).timeout(Duration(seconds: defaultTimeoutSeconds));

        // 🔥 MANUAL REDIRECT HANDLING - The proven GAS workaround
        if (response.statusCode == 302 || response.statusCode == 303) {
          final location = response.headers['location'];
          if (location != null) {
            if (kDebugMode) print('🔄 Following redirect with 500ms delay');
            await Future.delayed(const Duration(milliseconds: 500));
            response = await _client.get(
              Uri.parse(location),
              headers: {'Accept': 'application/json'},
            ).timeout(Duration(seconds: defaultTimeoutSeconds));
          }
        }

        if (response.statusCode == 200) {
          final responseBody = response.body.trim();
          if (responseBody.toUpperCase().startsWith('<HTML')) {
            logger?.error('❌ POST Failed: Received HTML response');
            _recordFailure();
            return {
              'success': false,
              'message': 'Server returned HTML instead of JSON.'
            };
          }
          _recordSuccess();
          return _parseSyncResponse(responseBody);
        }

        if (response.statusCode == 404 || response.statusCode >= 500) {
          logger?.error('⚠️ HTTP Error ${response.statusCode} (Attempt $attempt)');
          _recordFailure();
        } else {
          logger?.error('❌ HTTP Error: ${response.statusCode}');
          _recordFailure();
          return {'success': false, 'message': 'HTTP Error: ${response.statusCode}'};
        }

      } on SocketException catch (e) {
        logger?.error('⚠️ Network Error (Attempt $attempt)', e);
        _recordFailure();
      } on TimeoutException catch (e) {
        logger?.error('⚠️ Timeout (Attempt $attempt)', e);
        _recordFailure();
      } catch (e) {
        logger?.error('❌ Exception in $tag (Attempt $attempt)', e);
        _recordFailure();
        return {'success': false, 'message': 'Exception: $e'};
      }

      if (attempt <= maxRetries) {
        final int delaySeconds = attempt * 3;
        await Future.delayed(Duration(seconds: delaySeconds));
      }
    }

    return {'success': false, 'message': 'Request failed after $maxRetries retries'};
  }

  Map<String, dynamic> _parseSyncResponse(String responseBody) {
    // if (kDebugMode) {
    //   print('🔍 Parsing response: ${responseBody.substring(0, responseBody.length > 100 ? 100 : responseBody.length)}');
    // }

    try {
      final result = json.decode(responseBody);
      if (result is Map<String, dynamic>) {
        // if (kDebugMode) print('✅ Parsed JSON: ${result.keys.join(', ')}');

        // 🔥 FIXED: Handle error responses properly
        if (result.containsKey('error') ||
            (result.containsKey('status') && result['status'] == 'error')) {
          return {
            'success': false,
            'message': result['message'] ?? result['error'] ?? 'Server returned an error',
            'newCount': 0,
            'updatedCount': 0,
            'duplicateCount': 0,
            'duplicates': [],
            'count': 0,
            'updated': 0,
            'deleted': 0,
          };
        }

        // 🔥 FIXED: Handle ALL status types (success, partial_success)
        final bool isSuccess = result['status'] == 'success' ||
            result['status'] == 'partial_success' ||
            result['success'] == true;

        // 🔥 FIXED: Extract ALL possible field names from server response
        // Stock count endpoints return: count, updated, deleted
        // Invoice endpoints return: newCount, updatedCount, duplicateCount
        // Location endpoints return: count
        // Product endpoints return: added, storeAdded

        final count = result['count'] ?? result['newCount'] ?? result['added'] ?? 0;
        final updated = result['updated'] ?? result['updatedCount'] ?? 0;
        final deleted = result['deleted'] ?? 0;
        final duplicates = result['duplicates'] ?? [];
        final duplicateCount = result['duplicateCount'] ?? duplicates.length ?? 0;

        // if (kDebugMode) {
        //   print('📊 Extracted: count=$count, updated=$updated, deleted=$deleted, duplicates=$duplicateCount');
        // }

        return {
          'success': isSuccess,
          // For invoice/purchase compatibility
          'newCount': count,
          'updatedCount': updated,
          'duplicateCount': duplicateCount,
          // 🔥 For stock count compatibility
          'count': count,
          'updated': updated,
          'deleted': deleted,
          'duplicates': duplicates,
          'message': result['message'] ?? 'Sync completed',
          'raw': result, // 🔥 Pass through raw for debugging
        };
      }
    } catch (e) {
      logger?.error('Error parsing sync response', e);
      print('❌ JSON parse error: $e');
    }

    return {
      'success': false,
      'message': 'Invalid server response format',
      'newCount': 0,
      'updatedCount': 0,
      'duplicateCount': 0,
      'duplicates': [],
      'count': 0,
      'updated': 0,
      'deleted': 0,
    };
  }
  // ---------------------------------------------------------------------------
  // 🔥 GENERIC: Fetch ANY table with pagination (The Main Method)
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> fetchTableWithPagination(
      String tableName, {
        int batchSize = defaultBatchSize,
        int timeoutSeconds = defaultTimeoutSeconds,
        Function(int received, int? total)? onProgress,
        Function(String message)? onStatus,
      }) async {
    // Check if disposed
    if (_isDisposed) {
      throw Exception('Service is disposed');
    }

    // Reset cancellation
    _isCancelled = false;

    // Check cache first
    final cachedEntry = _cache[tableName];
    if (cachedEntry != null && DateTime.now().difference(cachedEntry.timestamp) < cacheDuration) {
      if (kDebugMode) {
        print('✅ Using cached data for $tableName (${cachedEntry.data.length} records)');
      }
      return cachedEntry.data;
    }

    if (kDebugMode) {
      print('🔍 FETCHING $tableName with pagination');
    }

    // Get total count with retry
    int? totalRecords;
    int countAttempt = 0;
    while (countAttempt < 3) {
      countAttempt++;
      try {
        onStatus?.call('Getting total record count...');
        totalRecords = await getTableRowCount(tableName);
        if (totalRecords > 0) {
          // if (kDebugMode) print('📊 Total records: $totalRecords');

          // Adaptive batch sizing
          if (totalRecords > 50000 && batchSize < largeBatchSize) {
            batchSize = largeBatchSize;
            // if (kDebugMode) print('📦 Large dataset, increased batch size to $batchSize');
            if (timeoutSeconds < largeTableTimeoutSeconds) {
              timeoutSeconds = largeTableTimeoutSeconds;
              // if (kDebugMode) print('⏱️ Large table, using ${timeoutSeconds}s timeout');
            }
          } else if (totalRecords < 500 && batchSize > 500) {
            batchSize = 500;
            // if (kDebugMode) print('📦 Small dataset, using batch size: $batchSize');
          }
          break;
        } else if (countAttempt < 3) {
          print('⚠️ Count returned 0 for $tableName, retrying (attempt $countAttempt)...');
          await Future.delayed(Duration(seconds: countAttempt * 2));
        }
      } catch (e) {
        print('⚠️ Could not get total count (attempt $countAttempt): $e');
        if (countAttempt < 3) {
          await Future.delayed(Duration(seconds: countAttempt * 2));
        }
      }
    }

    List<Map<String, dynamic>> allResults = [];
    int offset = 0;
    int batchNumber = 1;
    int consecutiveFailures = 0;
    int totalFetched = 0;
    int consecutive404Count = 0;
    bool useAlternativeUrl = false;

    while (true) {
      if (_isCancelled) {
        print('🛑 Fetch cancelled');
        break;
      }

      if (totalRecords != null && totalFetched >= totalRecords) {
        // if (kDebugMode) print('✅ Reached expected total: $totalRecords');
        break;
      }

      if (consecutiveFailures >= 3) {
        print('❌ 3 consecutive failures. Aborting.');
        break;
      }

      // Check circuit breaker
      if (_circuitBreakerOpen) {
        print('⏳ Circuit breaker OPEN, waiting 1 minute...');
        await Future.delayed(const Duration(minutes: 1));
        _resetCircuitBreaker();
      }

      int retryCount = 0;
      List<Map<String, dynamic>>? batch;

      while (retryCount < maxRetries) {
        try {
          onStatus?.call('Fetching batch $batchNumber (offset: $offset)');
          if (kDebugMode) {
            print('📦 Batch $batchNumber (offset: $offset, limit: $batchSize)');
          }

          batch = await fetchBatchWithPagination(
            tableName,
            offset: offset,
            limit: batchSize,
            timeoutSeconds: timeoutSeconds,
            useAlternativeUrl: useAlternativeUrl,
            attempt: retryCount + 1,
          );

          // Reset 404 counter on success
          consecutive404Count = 0;
          consecutiveFailures = 0;
          _recordSuccess();
          break;

        } catch (e) {
          retryCount++;
          final bool is404 = e.toString().contains('404');

          print('⚠️ Batch $batchNumber failed (attempt $retryCount): $e');

          if (is404) {
            consecutive404Count++;
            print('⚠️ 404 count: $consecutive404Count');

            // Try alternative URL after first 404
            if (consecutive404Count == 1 && !useAlternativeUrl) {
              print('🔄 First 404 - trying alternative URL...');
              useAlternativeUrl = true;
              await Future.delayed(const Duration(milliseconds: 500));
              continue;
            }

            // If it's the first batch and we get 404, try again with delay
            if (allResults.isEmpty && retryCount < maxRetries) {
              print('⚠️ First batch 404 - retrying with delay...');
              await Future.delayed(Duration(seconds: retryCount * 2));
              continue;
            }

            // If we still get 404 after alternative URL, this batch is
            // unrecoverable. Throw so the caller knows the download is
            // incomplete instead of silently treating it as end-of-data.
            if (useAlternativeUrl && consecutive404Count >= 2) {
              throw Exception(
                  'Batch $batchNumber (offset $offset) for $tableName failed: '
                      '404 even with alternative URL after $consecutive404Count attempts.');
            }
          }

          _recordFailure();

          if (e.toString().contains('Redirect loop')) {
            print('⚠️ Redirect loop. Recreating client...');
            _recreateClient();
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }

          final bool isRateLimit = e.toString().contains('429') ||
              e.toString().contains('Too Many Requests');

          if (retryCount >= maxRetries) {
            throw Exception(
                'Batch $batchNumber (offset $offset) for $tableName failed '
                    'after $maxRetries attempts: $e');
          }

          // Exponential backoff with jitter
          final int baseDelay = isRateLimit ? 5 : retryCount * 2;
          final int jitter = math.Random().nextInt(500);
          final int totalDelayMs = baseDelay * 1000 + jitter;
          await Future.delayed(Duration(milliseconds: totalDelayMs));
        }
      }

      if (batch == null) {
        // Should be unreachable: every failure path above now throws
        // instead of leaving batch unset. Fail loudly rather than
        // silently skipping this chunk and moving on.
        throw Exception(
            'Batch $batchNumber (offset $offset) for $tableName returned '
                'no result and no error. Aborting download.');
      }

      if (batch.isEmpty) {
        if (totalRecords == null || totalFetched > 0) {
          print('✅ Reached end of data');
        } else {
          print('⚠️ Table may be empty');
        }
        break;
      }

      allResults.addAll(batch);
      totalFetched += batch.length;
      onProgress?.call(totalFetched, totalRecords);

      if (totalFetched % 10000 == 0 && totalFetched > 0) {
        final String percent = totalRecords != null
            ? (totalFetched / totalRecords * 100).toStringAsFixed(1)
            : '?';
        // if (kDebugMode) print('📊 Progress: $totalFetched/${totalRecords ?? '?'} ($percent%)');
      }

      if (batch.length < batchSize) {
        // if (kDebugMode) print('✅ Last batch: ${batch.length} records');
        break;
      }

      offset += batchSize;
      batchNumber++;

      final int delayMs = totalRecords != null && totalRecords > 50000 ? 500 : 300;
      await Future.delayed(Duration(milliseconds: delayMs));
    }

    if (allResults.isNotEmpty) {
      _cache[tableName] = _CacheEntry(
        data: allResults,
        timestamp: DateTime.now(),
      );
      // if (kDebugMode) print('💾 Cached $tableName (${allResults.length} records)');
    }

    // if (kDebugMode) print('✅ Completed $tableName: ${allResults.length} records');
    return allResults;
  }

  // 🔥 Extract response processing to a separate method
  Future<List<Map<String, dynamic>>> _processBatchResponse(
      http.Response response,
      String tableName,
      int offset,
      int attempt,
      ) async {
    if (response.statusCode == 200 && response.body.trim().startsWith('<')) {
      throw Exception('GAS returned HTML instead of JSON');
    }

    if (response.statusCode == 404) {
      throw Exception('HTTP 404: Not Found');
    }

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final decoded = json.decode(response.body);

    if (decoded is Map && decoded.containsKey('data')) {
      final data = decoded['data'];
      if (data is List) {
        final bool hasMore = decoded['hasMore'] ?? false;
        final int total = ((decoded['total'] ?? 0) as num).toInt();
        // if (kDebugMode) {
        //   print('📦 Received ${data.length} records (total: $total, hasMore: $hasMore)');
        // }
        return await _parseSmart(data);
      }
      return [];
    }

    if (decoded is List) {
      // if (kDebugMode) print('📦 Received ${decoded.length} records');
      return await _parseSmart(decoded);
    }

    if (decoded is Map && decoded.containsKey('error')) {
      throw Exception('GAS Error: ${decoded['error']}');
    }

    print('⚠️ Unexpected response format');
    return [];
  }

  // ---------------------------------------------------------------------------
// 🔥 Fetch a single batch with pagination & retry
// ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> fetchBatchWithPagination(
      String tableName, {
        int offset = 0,
        int limit = defaultBatchSize,
        int timeoutSeconds = defaultTimeoutSeconds,
        bool useAlternativeUrl = false,
        int attempt = 1,
      }) async {
    // Check if disposed
    if (_isDisposed) {
      throw Exception('Service is disposed');
    }

    // Reset redirect counter for new requests
    if (offset == 0) {
      _redirectCount = 0;
    }

    String urlString;

    if (useAlternativeUrl) {
      final uri = Uri.parse(masterScriptUrl);
      final scriptId = uri.pathSegments.length > 1
          ? uri.pathSegments[uri.pathSegments.length - 2]
          : uri.pathSegments.last;

      urlString = 'https://script.google.com/macros/s/$scriptId/exec?' 'table=$tableName&storeIdentifier=$storeIdentifier&offset=$offset&limit=$limit' '&_t=${DateTime.now().millisecondsSinceEpoch}';
    } else {
      urlString = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': tableName,
          'storeIdentifier': storeIdentifier,
          'offset': offset.toString(),
          'limit': limit.toString(),
          '_t': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      ).toString();
    }

    try {
      final response = await _client.get(
        Uri.parse(urlString),
        headers: {
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
        },
      ).timeout(Duration(seconds: timeoutSeconds));

      // Check for redirect (301, 302, 303, 307, 308)
      if (response.statusCode >= 300 && response.statusCode < 400) {
        _redirectCount++;
        print('🔄 Redirect $_redirectCount/$maxRedirects for $tableName');

        if (_redirectCount > maxRedirects) {
          // Too many redirects - try alternative URL or throw
          if (!useAlternativeUrl && attempt < 3) {
            print('⚠️ Too many redirects, trying alternative URL...');
            return fetchBatchWithPagination(
              tableName,
              offset: offset,
              limit: limit,
              timeoutSeconds: timeoutSeconds,
              useAlternativeUrl: true,
              attempt: attempt + 1,
            );
          }
          throw Exception('Redirect loop detected after $_redirectCount redirects');
        }

        // Follow redirect manually with a delay
        final location = response.headers['location'];
        if (location != null) {
          await Future.delayed(const Duration(milliseconds: 500));
          print('🔄 Following redirect to: $location');
          final redirectResponse = await _client.get(
            Uri.parse(location),
            headers: {
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
            },
          ).timeout(Duration(seconds: timeoutSeconds));

          return _processBatchResponse(redirectResponse, tableName, offset, attempt);
        }
      }

      return _processBatchResponse(response, tableName, offset, attempt);

    } catch (e) {
      // Only recreate client for redirect loops, and do it properly
      if (e.toString().contains('Redirect loop')) {
        print('⚠️ Redirect loop detected. Recreating client...');
        _recreateClient();
        await Future.delayed(const Duration(seconds: 2));
        return fetchBatchWithPagination(
          tableName,
          offset: offset,
          limit: limit,
          timeoutSeconds: timeoutSeconds,
          useAlternativeUrl: useAlternativeUrl,
          attempt: attempt,
        );
      }

      if (!useAlternativeUrl && attempt < 3 &&
          (e.toString().contains('404') || e.toString().contains('TimeoutException'))) {
        print('⚠️ Attempting alternative URL format (attempt $attempt)...');
        await Future.delayed(Duration(seconds: attempt));
        return fetchBatchWithPagination(
          tableName,
          offset: offset,
          limit: limit,
          timeoutSeconds: timeoutSeconds,
          useAlternativeUrl: true,
          attempt: attempt + 1,
        );
      }
      rethrow;
    }
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

  Future<int> getTableRowCount(String tableName) async {
    int attempt = 0;
    while (attempt < 3) {
      attempt++;
      try {
        final url = Uri.parse(masterScriptUrl).replace(
          queryParameters: {
            'table': '_count',
            'targetTable': tableName,
            'storeIdentifier': storeIdentifier,
          },
        );

        final response = await _client.get(url).timeout(
            Duration(seconds: countTimeoutSeconds)
        );

        if (response.statusCode == 200 && !response.body.trim().startsWith('<')) {
          final decoded = json.decode(response.body);
          final int count = ((decoded['count'] ?? 0) as num).toInt();
          if (kDebugMode) print('📊 Count for $tableName: $count');
          _recordSuccess();
          return count;
        }

        if (response.statusCode == 404 && attempt < 3) {
          print('⚠️ Count 404 for $tableName, retrying (attempt $attempt)...');
          await Future.delayed(Duration(seconds: attempt * 2));
          continue;
        }

        return 0;

      } on TimeoutException catch (e) {
        if (attempt < 3) {
          print('⚠️ Count timeout for $tableName, retrying (attempt $attempt)...');
          await Future.delayed(Duration(seconds: attempt * 2));
          continue;
        }
        logger?.error('Could not get count for $tableName after 3 attempts', e);
        return 0;
      } catch (e) {
        if (attempt < 3) {
          print('⚠️ Count error for $tableName (attempt $attempt): $e');
          await Future.delayed(Duration(seconds: attempt * 2));
          continue;
        }
        logger?.error('Could not get count for $tableName', e);
        return 0;
      }
    }
    return 0;
  }

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

      final response = await _client.get(url).timeout(
          const Duration(seconds: 10)
      );

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
      final url = Uri.parse(masterScriptUrl).replace(queryParameters: {
        'table': 'validateStore',
        'sheetId': sheetId,
        if (userEmail != null && userEmail.isNotEmpty) 'userEmail': userEmail,
      });

      var response = await http.get(url).timeout(const Duration(seconds: 30));

      if (response.statusCode == 302 || response.statusCode == 303) {
        final location = response.headers['location'];
        if (location != null) {
          await Future.delayed(const Duration(milliseconds: 500));
          response = await http.get(
            Uri.parse(location),
            headers: {'Accept': 'application/json'},
          ).timeout(const Duration(seconds: 30));
        }
      }

      if (response.statusCode != 200) {
        return {'found': false, 'message': 'Server error (${response.statusCode})'};
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
    _isCancelled = true;
    print('🛑 Cancellation requested');
  }

  void clearCache({String? tableName}) {
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

  // ---------------------------------------------------------------------------
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
  }) async =>
      fetchTableWithPagination(
        'Purchases',
        onProgress: onProgress,
        onStatus: onStatus,
      );

  Future<List<Map<String, dynamic>>> fetchStoreSalesData({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async =>
      fetchTableWithPagination(
        'StoreSalesData',
        onProgress: onProgress,
        onStatus: onStatus,
      );

  Future<List<Map<String, dynamic>>> fetchItemSales({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async =>
      fetchTableWithPagination(
        'ItemSales',
        onProgress: onProgress,
        onStatus: onStatus,
      );

  Future<List<Map<String, dynamic>>> fetchItemsIssued({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async =>
      fetchTableWithPagination(
        'ItemsIssued',
        onProgress: onProgress,
        onStatus: onStatus,
      );

  Future<List<Map<String, dynamic>>> fetchInvoices({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async =>
      fetchTableWithPagination(
        'InvoiceDetails',
        onProgress: onProgress,
        onStatus: onStatus,
      );

  Future<List<Map<String, dynamic>>> fetchStockCounts({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async =>
      fetchTableWithPagination(
        'StockCounts',
        onProgress: onProgress,
        onStatus: onStatus,
      );

  Future<List<Map<String, dynamic>>> fetchPluMappings({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async =>
      fetchTableWithPagination(
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
  }) async {
    if (kDebugMode) print('🔍 FETCH COMPUTED COSTS');

    // Check cache first
    final cachedEntry = _cache['MasterCostsComputed'];
    if (cachedEntry != null && DateTime.now().difference(cachedEntry.timestamp) < cacheDuration) {
      if (kDebugMode) {
        print('✅ Using cached data for MasterCostsComputed (${cachedEntry.data.length} records)');
      }
      return cachedEntry.data;
    }

    try {
      onStatus?.call('Fetching computed costs...');

      // Direct GET - bypasses pagination
      final url = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': 'MasterCostsComputed',
          'storeIdentifier': storeIdentifier,
        },
      );

      final response = await _client.get(url).timeout(
          const Duration(seconds: 60)
      );

      if (response.statusCode == 200) {
        if (response.body.trim().startsWith('<')) {
          throw Exception('GAS returned HTML instead of JSON');
        }

        final decoded = json.decode(response.body);
        List<Map<String, dynamic>> result = [];

        // Handle wrapped response
        if (decoded is Map && decoded.containsKey('data')) {
          final data = decoded['data'];
          if (data is List) {
            result = data.map((item) => Map<String, dynamic>.from(item)).toList();
          }
        } else if (decoded is List) {
          result = decoded.map((item) => Map<String, dynamic>.from(item)).toList();
        }

        print('📊 Fetched ${result.length} computed costs');

        // Cache the result
        if (result.isNotEmpty) {
          _cache['MasterCostsComputed'] = _CacheEntry(
            data: result,
            timestamp: DateTime.now(),
          );
          print('💾 Cached MasterCostsComputed (${result.length} records)');
          onProgress?.call(result.length, result.length);
        }

        return result;
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
      }
    } catch (e) {
      print('⚠️ Error fetching computed costs: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchMasterSuppliers({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedMasterSuppliers != null && _cachedMasterSuppliers!.isNotEmpty) {
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
  }) async =>
      fetchTableWithPagination(
        'InvoiceDetails',
        onProgress: onProgress,
        onStatus: onStatus,
      );

  Future<List<Map<String, dynamic>>> fetchAllInvoices({
    Function(int received, int? total)? onProgress,
    Function(String message)? onStatus,
  }) async =>
      fetchTableWithPagination(
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
    if (products.length > chunkSize) {
      final result = await syncNewProductsWithChunking(products);
      return result['success'] == true;
    }

    final payload = products.map(_mapCommonFieldsForSheet).toList();

    final result = await _sendPostRequest(
        'syncNewProducts',
        {'data': payload, 'endpoint': 'syncNewProducts'}
    );
    return result['success'] == true;
  }

  Future<bool> syncNewLocations(List<Map<String, dynamic>> locations) async {
    // 🔥 FIXED: Use the chunking method
    if (locations.length > chunkSize) {
      final result = await syncNewLocationsWithChunking(locations);
      return result['success'] == true;
    }

    final payload = locations.map(_mapCommonFieldsForSheet).toList();

    final result = await _sendPostRequest(
        'syncNewLocations',
        {'data': payload, 'endpoint': 'syncNewLocations'}
    );
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

    // 🔥 FIXED: Use the chunking method
    if (syncedInvoices.length > chunkSize) {
      return syncInvoiceDetailsWithChunking(syncedInvoices);
    }

    final result = await _sendPostRequest(
        'syncInvoiceDetails',
        {
          'endpoint': 'syncInvoiceDetails',
          'data': syncedInvoices,
          'table': 'InvoiceDetails',
        }
    );

    print('📥 Raw syncInvoiceDetails result: $result');
    return result;
  }

  Future<bool> syncInvoiceDetails(List<Map<String, dynamic>> invoices) async {
    final result = await syncInvoiceDetailsWithResult(invoices);
    return result['success'] == true;
  }

  Future<Map<String, dynamic>> syncPurchasesWithResult(
      List<Map<String, dynamic>> purchases,
      ) async {
    final sanitized = purchases.map((p) {
      final item = Map<String, dynamic>.from(p);
      if (item['purchases_ID'] == null || item['purchases_ID'].toString().isEmpty) {
        item['purchases_ID'] = _generateUuid();
      }
      if (item['syncStatus'] == null) {
        item['syncStatus'] = 'synced';
      }
      return item;
    }).toList();

    // 🔥 FIXED: Use the chunking method
    if (sanitized.length > chunkSize) {
      return syncPurchasesWithChunking(sanitized);
    }

    final result = await _sendPostRequest(
        'syncPurchases',
        {
          'endpoint': 'syncPurchases',
          'data': sanitized,
          'table': 'Purchases',
        }
    );

    print('📥 Raw syncPurchases result: $result');
    return result;
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

    final result = await _sendPostRequest(
        'syncPluMappings',
        {'endpoint': 'syncPluMappings', 'data': mappings}
    );
    return result['success'] == true;
  }

  // ============================================================================
// 🔥 CHUNKED SYNC METHODS WITH RETRY AND PROGRESS
// ============================================================================

  /// Sync invoices with chunking, retry, and progress reporting

  Future<Map<String, dynamic>> syncInvoiceDetailsWithChunking(
      List<Map<String, dynamic>> invoices, {
        Function(int processed, int total)? onProgress,
        int chunkSize = 25,
      }) async {
    if (invoices.isEmpty) {
      return {
        'success': true,
        'newCount': 0,
        'updatedCount': 0,
        'duplicateCount': 0,
        'duplicates': [],
        'message': 'No invoices to sync'
      };
    }

    print('📄 Syncing ${invoices.length} invoices in chunks of $chunkSize');

    final mappedInvoices = invoices.map(_mapInvoiceFields).toList();
    final syncedInvoices = mappedInvoices.map((inv) {
      final modified = Map<String, dynamic>.from(inv);
      modified['syncStatus'] = 'synced';
      return modified;
    }).toList();

    int totalNew = 0;
    int totalUpdated = 0;
    int totalDuplicates = 0;
    bool allSuccessful = true;
    String lastError = '';
    int processedCount = 0;
    List<Map<String, dynamic>> allDuplicates = [];

    // 🔥 Generate unique transaction ID
    final transactionId = DateTime.now().millisecondsSinceEpoch.toString();

    for (var i = 0; i < syncedInvoices.length; i += chunkSize) {
      if (_isDisposed) {
        return {
          'success': false,
          'newCount': totalNew,
          'updatedCount': totalUpdated,
          'duplicateCount': totalDuplicates,
          'duplicates': allDuplicates,
          'message': 'Service disposed during sync'
        };
      }

      final end = (i + chunkSize).clamp(0, syncedInvoices.length);
      final chunk = syncedInvoices.sublist(i, end);
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (syncedInvoices.length / chunkSize).ceil();

      print('📤 Syncing invoice chunk $chunkNumber/$totalChunks (${chunk.length} records)');

      // 🔥 Add idempotency metadata
      final enrichedChunk = chunk.map((inv) => ({
        ...inv,
        'transactionId': transactionId,
        'chunkIndex': i ~/ chunkSize,
        'chunkTotal': totalChunks,
      })).toList();

      // 🔥 RETRY LOGIC
      bool chunkSuccess = false;
      int retryCount = 0;
      Map<String, dynamic>? result;

      while (retryCount < 3 && !chunkSuccess) {
        if (retryCount > 0) {
          print('🔄 Retry $retryCount/3 for invoice chunk $chunkNumber');
          await Future.delayed(Duration(seconds: retryCount * 2));
        }

        try {
          result = await _sendPostRequest(
            'syncInvoiceDetails',
            {
              'endpoint': 'syncInvoiceDetails',
              'data': enrichedChunk,
              'table': 'InvoiceDetails',
              'retry': retryCount,
            },
          );

          final isSuccess = result['success'] == true;
          final isDuplicate = result['status'] == 'duplicate';

          if (isSuccess || isDuplicate) {
            chunkSuccess = true;
            totalNew += (result['newCount'] ?? 0) as int;
            totalUpdated += (result['updatedCount'] ?? 0) as int;
            totalDuplicates += (result['duplicateCount'] ?? 0) as int;
            if (result['duplicates'] != null) {
              allDuplicates.addAll(List<Map<String, dynamic>>.from(result['duplicates']));
            }
            processedCount += chunk.length;
            onProgress?.call(processedCount, syncedInvoices.length);
            print('✅ Chunk $chunkNumber complete: +${result['newCount']} new, ${result['updatedCount']} updated');
          } else {
            lastError = result['message'] ?? 'Unknown error in chunk $chunkNumber';
            print('⚠️ Chunk $chunkNumber failed: $lastError');

            final isRetryable = result['status'] == 'error' ||
                result['message']?.contains('timeout') == true ||
                result['message']?.contains('busy') == true;

            if (!isRetryable) break;
          }
        } catch (e) {
          lastError = e.toString();
          print('❌ Chunk $chunkNumber exception (attempt ${retryCount + 1}): $e');

          final isRetryable = e.toString().contains('timeout') ||
              e.toString().contains('socket') ||
              e.toString().contains('connection');

          if (!isRetryable) break;
        }

        retryCount++;
      }

      if (!chunkSuccess) {
        allSuccessful = false;
        print('❌ Chunk $chunkNumber FAILED after $retryCount attempts');
      }

      if (i + chunkSize < syncedInvoices.length) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    return {
      'success': allSuccessful,
      'newCount': totalNew,
      'updatedCount': totalUpdated,
      'duplicateCount': totalDuplicates,
      'duplicates': allDuplicates,
      'message': allSuccessful
          ? 'Synced ${syncedInvoices.length} invoices successfully'
          : 'Completed with errors: $lastError',
      'lastError': lastError,
    };
  }

  /// Sync purchases with chunking, retry, and progress reporting

  Future<Map<String, dynamic>> syncPurchasesWithChunking(
      List<Map<String, dynamic>> purchases, {
        Function(int processed, int total)? onProgress,
        int chunkSize = 50,
      }) async {
    if (purchases.isEmpty) {
      return {
        'success': true,
        'newCount': 0,
        'updatedCount': 0,
        'duplicateCount': 0,
        'message': 'No purchases to sync'
      };
    }

    print('📦 Syncing ${purchases.length} purchases in chunks of $chunkSize');

    final sanitized = purchases.map((p) {
      final item = Map<String, dynamic>.from(p);
      if (item['purchases_ID'] == null || item['purchases_ID'].toString().isEmpty) {
        item['purchases_ID'] = _generateUuid();
      }
      if (item['syncStatus'] == null) {
        item['syncStatus'] = 'synced';
      }
      return item;
    }).toList();

    int totalNew = 0;
    int totalUpdated = 0;
    int totalDuplicates = 0;
    bool allSuccessful = true;
    String lastError = '';
    int processedCount = 0;

    final transactionId = DateTime.now().millisecondsSinceEpoch.toString();

    for (var i = 0; i < sanitized.length; i += chunkSize) {
      if (_isDisposed) {
        return {
          'success': false,
          'newCount': totalNew,
          'updatedCount': totalUpdated,
          'duplicateCount': totalDuplicates,
          'message': 'Service disposed during sync'
        };
      }

      final end = (i + chunkSize).clamp(0, sanitized.length);
      final chunk = sanitized.sublist(i, end);
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (sanitized.length / chunkSize).ceil();

      print('📤 Syncing purchase chunk $chunkNumber/$totalChunks (${chunk.length} records)');

      final enrichedChunk = chunk.map((p) => ({
        ...p,
        'transactionId': transactionId,
        'chunkIndex': i ~/ chunkSize,
        'chunkTotal': totalChunks,
      })).toList();

      bool chunkSuccess = false;
      int retryCount = 0;
      Map<String, dynamic>? result;

      while (retryCount < 3 && !chunkSuccess) {
        if (retryCount > 0) {
          print('🔄 Retry $retryCount/3 for purchase chunk $chunkNumber');
          await Future.delayed(Duration(seconds: retryCount * 2));
        }

        try {
          result = await _sendPostRequest(
            'syncPurchases',
            {
              'endpoint': 'syncPurchases',
              'data': enrichedChunk,
              'table': 'Purchases',
              'retry': retryCount,
            },
          );

          final isSuccess = result['success'] == true;
          final isDuplicate = result['status'] == 'duplicate';

          if (isSuccess || isDuplicate) {
            chunkSuccess = true;
            totalNew += (result['newCount'] ?? 0) as int;
            totalUpdated += (result['updatedCount'] ?? 0) as int;
            totalDuplicates += (result['duplicateCount'] ?? 0) as int;
            processedCount += chunk.length;
            onProgress?.call(processedCount, sanitized.length);
            print('✅ Chunk $chunkNumber complete: +${result['newCount']} new, ${result['updatedCount']} updated');
          } else {
            lastError = result['message'] ?? 'Unknown error in chunk $chunkNumber';
            print('⚠️ Chunk $chunkNumber failed: $lastError');

            final isRetryable = result['status'] == 'error' ||
                result['message']?.contains('timeout') == true ||
                result['message']?.contains('busy') == true;

            if (!isRetryable) break;
          }
        } catch (e) {
          lastError = e.toString();
          print('❌ Chunk $chunkNumber exception (attempt ${retryCount + 1}): $e');

          final isRetryable = e.toString().contains('timeout') ||
              e.toString().contains('socket') ||
              e.toString().contains('connection');

          if (!isRetryable) break;
        }

        retryCount++;
      }

      if (!chunkSuccess) {
        allSuccessful = false;
        print('❌ Chunk $chunkNumber FAILED after $retryCount attempts');
      }

      if (i + chunkSize < sanitized.length) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    return {
      'success': allSuccessful,
      'newCount': totalNew,
      'updatedCount': totalUpdated,
      'duplicateCount': totalDuplicates,
      'message': allSuccessful
          ? 'Synced ${sanitized.length} purchases successfully'
          : 'Completed with errors: $lastError',
      'lastError': lastError,
    };
  }

  /// Sync stock counts with chunking, retry, and progress reporting
  Future<Map<String, dynamic>> syncStockCountsWithChunking(
      List<Map<String, dynamic>> counts, {
        Function(int processed, int total)? onProgress,
        int chunkSize = 200, // 🔥 REDUCED from 500 to 200 for GAS memory safety
      }) async {
    if (counts.isEmpty) {
      return {
        'success': true,
        'count': 0,
        'updated': 0,
        'deleted': 0,
        'syncedIds': <String>[],
        'failedIds': <String>[],
        'message': 'No stock counts to sync'
      };
    }

    print('📊 Syncing ${counts.length} stock counts in chunks of $chunkSize');

    int totalInserted = 0;
    int totalUpdated = 0;
    int totalDeleted = 0;
    bool allSuccessful = true;
    String lastError = '';
    int processedCount = 0;
    final List<String> syncedIds = [];
    final List<String> failedIds = [];

    // 🔥 Generate unique transaction ID for idempotency
    final transactionId = DateTime.now().millisecondsSinceEpoch.toString();

    for (var i = 0; i < counts.length; i += chunkSize) {
      if (_isDisposed) {
        return {
          'success': false,
          'count': totalInserted,
          'updated': totalUpdated,
          'deleted': totalDeleted,
          'syncedIds': syncedIds,
          'failedIds': failedIds,
          'message': 'Service disposed during sync'
        };
      }

      final end = (i + chunkSize).clamp(0, counts.length);
      final rawChunk = counts.sublist(i, end);
      final chunk = rawChunk.map(_mapStockCountForSheet).toList();
      final chunkIds = rawChunk
          .where((c) => c['id'] != null)
          .map((c) => c['id'].toString())
          .toList();
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (counts.length / chunkSize).ceil();

      print('📊 Syncing stock count chunk $chunkNumber/$totalChunks (${chunk.length} records)');

      // 🔥 Add idempotency metadata
      final enrichedChunk = chunk.map((c) => {
        ...c,
        'transactionId': transactionId,
        'chunkIndex': i ~/ chunkSize,
        'chunkTotal': totalChunks,
      }).toList();

      // 🔥 RETRY LOGIC: Try up to 3 times
      bool chunkSuccess = false;
      int retryCount = 0;
      Map<String, dynamic>? result;

      while (retryCount < 3 && !chunkSuccess) {
        if (retryCount > 0) {
          print('🔄 Retry $retryCount/3 for chunk $chunkNumber (waiting ${retryCount * 2}s)...');
          await Future.delayed(Duration(seconds: retryCount * 2));
        }

        try {
          result = await _sendPostRequest(
            'syncStockCounts',
            {
              'endpoint': 'syncStockCounts',
              'data': enrichedChunk,
              'retry': retryCount, // 🔥 Pass retry count for GAS backoff
            },
          );

          // Check if chunk was successful
          final isSuccess = result['success'] == true ||
              result['status'] == 'success' ||
              result['status'] == 'partial_success';

          // Check if duplicate (already processed)
          final isDuplicate = result['status'] == 'duplicate';

          if (isSuccess || isDuplicate) {
            chunkSuccess = true;
            final count = (result['count'] ?? result['newCount'] ?? 0) as int;
            final updated = (result['updated'] ?? result['updatedCount'] ?? 0) as int;
            final deleted = (result['deleted'] ?? 0) as int;

            totalInserted += count;
            totalUpdated += updated;
            totalDeleted += deleted;
            processedCount += chunk.length;

            if (isDuplicate) {
              print('⏭️ Chunk $chunkNumber already processed (duplicate)');
            } else {
              print('✅ Chunk $chunkNumber complete: +$count inserted, $updated updated, $deleted deleted');
            }

            // Only mark as synced if not duplicate
            if (!isDuplicate) {
              syncedIds.addAll(chunkIds);
            }

            onProgress?.call(processedCount, counts.length);
          } else {
            // Server responded but didn't confirm success
            lastError = (result['message'] ??
                'Chunk $chunkNumber: server did not confirm success (status: ${result['status']})')
                .toString();
            print('⚠️ Chunk $chunkNumber NOT confirmed: $lastError');

            // Check if we should retry
            final isRetryable = result['status'] == 'error' ||
                result['status'] == 'partial_success' ||
                result['message']?.contains('timeout') == true ||
                result['message']?.contains('busy') == true;

            if (!isRetryable) {
              break; // Don't retry non-retryable errors
            }
          }
        } catch (e) {
          lastError = e.toString();
          print('❌ Chunk $chunkNumber exception (attempt ${retryCount + 1}): $e');

          // Check if we should retry
          final isRetryable = e.toString().contains('timeout') ||
              e.toString().contains('socket') ||
              e.toString().contains('connection');

          if (!isRetryable) {
            break; // Don't retry non-retryable errors
          }
        }

        retryCount++;
      }

      // If chunk still failed after retries
      if (!chunkSuccess) {
        allSuccessful = false;
        failedIds.addAll(chunkIds);
        print('❌ Chunk $chunkNumber FAILED after $retryCount attempts: $lastError');
      }

      // 🔥 Add delay between chunks (increased for GAS safety)
      if (i + chunkSize < counts.length) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }

    // Calculate success rate
    final totalAttempted = counts.length;
    final totalConfirmed = syncedIds.length;
    final successRate = totalAttempted > 0 ? (totalConfirmed / totalAttempted * 100) : 0;

    return {
      'success': allSuccessful && failedIds.isEmpty,
      'count': totalInserted,
      'updated': totalUpdated,
      'deleted': totalDeleted,
      'syncedIds': syncedIds,
      'failedIds': failedIds,
      'totalAttempted': totalAttempted,
      'totalConfirmed': totalConfirmed,
      'successRate': successRate,
      'message': allSuccessful && failedIds.isEmpty
          ? 'Synced $totalConfirmed of $totalAttempted stock counts successfully ($successRate% success rate)'
          : 'Completed with errors: $lastError ($totalConfirmed of $totalAttempted confirmed, ${failedIds.length} failed)',
      'lastError': lastError,
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
        'message': 'No mappings to sync'
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
          'message': 'Service disposed during sync'
        };
      }

      final end = (i + chunkSize).clamp(0, mappings.length);
      final chunk = mappings.sublist(i, end);
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (mappings.length / chunkSize).ceil();

      print('🔗 Syncing PLU chunk $chunkNumber/$totalChunks (${chunk.length} records)');

      final mappedChunk = chunk.map(_mapCommonFieldsForSheet).toList();

      try {
        final result = await _sendPostRequest(
          'syncPluMappings',
          {
            'endpoint': 'syncPluMappings',
            'data': mappedChunk,
          },
        );

        if (result['success'] == true) {
          totalNew += (result['newCount'] ?? 0) as int;
          totalUpdated += (result['updatedCount'] ?? 0) as int;
          processedCount += chunk.length;
          onProgress?.call(processedCount, mappings.length);
          print('✅ Chunk $chunkNumber complete: +${result['newCount']} new, ${result['updatedCount']} updated, ${result['deleted'] ?? 0} deleted');
        } else {
          allSuccessful = false;
          lastError = result['message'] ?? 'Unknown error in chunk $chunkNumber';
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
      return {
        'success': true,
        'count': 0,
        'message': 'No locations to sync'
      };
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
          'message': 'Service disposed during sync'
        };
      }

      final end = (i + chunkSize).clamp(0, locations.length);
      final chunk = locations.sublist(i, end);
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (locations.length / chunkSize).ceil();

      print('📍 Syncing location chunk $chunkNumber/$totalChunks (${chunk.length} records)');

      final mappedChunk = chunk.map(_mapCommonFieldsForSheet).toList();

      try {
        final result = await _sendPostRequest(
          'syncNewLocations',
          {
            'endpoint': 'syncNewLocations',
            'data': mappedChunk,
          },
        );

        if (result['success'] == true) {
          totalAdded += (result['count'] ?? 0) as int;
          processedCount += chunk.length;
          onProgress?.call(processedCount, locations.length);
          print('✅ Chunk $chunkNumber complete: +${result['count'] ?? 0} locations, ${result['deleted'] ?? 0} deleted');
        } else {
          allSuccessful = false;
          lastError = result['message'] ?? 'Unknown error in chunk $chunkNumber';
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

  /// Sync new products with chunking
  Future<Map<String, dynamic>> syncNewProductsWithChunking(
      List<Map<String, dynamic>> products, {
        Function(int processed, int total)? onProgress,
        int chunkSize = 10,
      }) async {
    if (products.isEmpty) {
      return {
        'success': true,
        'count': 0,
        'message': 'No products to sync'
      };
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
          'message': 'Service disposed during sync'
        };
      }

      final end = (i + chunkSize).clamp(0, products.length);
      final chunk = products.sublist(i, end);
      final chunkNumber = (i ~/ chunkSize) + 1;
      final totalChunks = (products.length / chunkSize).ceil();

      print('🆕 Syncing product chunk $chunkNumber/$totalChunks (${chunk.length} records)');

      final mappedChunk = chunk.map(_mapCommonFieldsForSheet).toList();

      try {
        final result = await _sendPostRequest(
          'syncNewProducts',
          {
            'endpoint': 'syncNewProducts',
            'data': mappedChunk,
          },
        );

        if (result['success'] == true) {
          totalAdded += (result['added'] ?? 0) as int;
          processedCount += chunk.length;
          onProgress?.call(processedCount, products.length);
          print('✅ Chunk $chunkNumber complete: +${result['added'] ?? 0} products, ${result['deleted'] ?? 0} deleted');
        } else {
          allSuccessful = false;
          lastError = result['message'] ?? 'Unknown error in chunk $chunkNumber';
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
    final result = await _sendPostRequest(
        'deleteInvoice',
        {'endpoint': 'deleteInvoice', 'data': {'invoiceId': invoiceId}}
    );
    return result['success'] == true;
  }

  Future<bool> deletePurchase(String purchaseId) async {
    final result = await _sendPostRequest(
        'deletePurchase',
        {'endpoint': 'deletePurchase', 'data': {'purchaseId': purchaseId}}
    );
    return result['success'] == true;
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

    print('✅ Invoice deletion: ${invoiceIds.length - failedCount} succeeded, $failedCount failed');
    return allSuccessful;
  }

  Future<bool> deletePurchases(List<String> purchaseIds) async {
    if (purchaseIds.isEmpty) return true;

    if (purchaseIds.length > 100) {
      print('📦 Deleting ${purchaseIds.length} purchases in chunks');
      bool allSuccessful = true;
      int failedCount = 0;

      for (var i = 0; i < purchaseIds.length; i += 100) {
        final int end = (i + 100).clamp(0, purchaseIds.length).toInt();
        final chunk = purchaseIds.sublist(i, end);

        try {
          final result = await _sendPostRequest(
              'deletePurchases',
              {'endpoint': 'deletePurchases', 'data': {'purchaseIds': chunk}}
          );

          if (result['success'] != true) {
            allSuccessful = false;
            failedCount += chunk.length;
            print('⚠️ Delete chunk ${(i ~/ 100) + 1} failed');
          }
        } catch (e) {
          allSuccessful = false;
          failedCount += chunk.length;
          print('❌ Delete chunk ${(i ~/ 100) + 1} error: $e');
        }

        await Future.delayed(const Duration(milliseconds: 200));
      }

      print('✅ Purchase deletion: ${purchaseIds.length - failedCount} succeeded, $failedCount failed');
      return allSuccessful;
    }

    final result = await _sendPostRequest(
        'deletePurchases',
        {'endpoint': 'deletePurchases', 'data': {'purchaseIds': purchaseIds}}
    );
    return result['success'] == true;
  }

  Future<bool> updateInvoice(Map<String, dynamic> invoice) async {
    final result = await _sendPostRequest(
        'updateInvoice',
        {'endpoint': 'updateInvoice', 'data': _mapInvoiceFields(invoice)}
    );
    return result['success'] == true;
  }

  Future<bool> updatePurchase(Map<String, dynamic> purchase) async {
    final result = await _sendPostRequest(
        'updatePurchase',
        {'endpoint': 'updatePurchase', 'data': purchase}
    );
    return result['success'] == true;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _mapCommonFieldsForSheet(Map<String, dynamic> c) {
    final item = Map<String, dynamic>.from(c);

    // 🔥 Force date formatting for consistency in Google Sheets (dd/MM/yyyy HH:mm:ss)
    final rawCreated = c['createdAt'] ?? c['created_at'];
    final rawUpdated = c['updatedAt'] ?? c['updated_at'] ?? rawCreated;
    final rawSynced = c['syncedAt'] ?? c['synced_at'];

    if (rawCreated != null) {
      item['created_at'] = _formatDateTimeForSheet(rawCreated);
    }
    if (rawUpdated != null) {
      item['updated_at'] = _formatDateTimeForSheet(rawUpdated);
    }
    if (rawSynced != null) {
      item['synced_at'] = _formatDateTimeForSheet(rawSynced);
    }

    return item;
  }

  Map<String, dynamic> _mapStockCountForSheet(Map<String, dynamic> c) {
    final item = Map<String, dynamic>.from(c);
    item['deleted'] = (c['syncStatus'] == 'deleted');
    if (item['stock_id'] == null && item['id'] != null) {
      item['stock_id'] = item['id'];
    }

    // 🔥 Ensure consistent date formatting for both created_at and updated_at
    // We look for both camelCase and snake_case to be safe with older data
    final rawCreated = c['createdAt'] ?? c['created_at'];
    final rawUpdated = c['updatedAt'] ?? c['updated_at'] ?? rawCreated;

    if (rawCreated != null) {
      item['created_at'] = _formatDateTimeForSheet(rawCreated);
    }
    if (rawUpdated != null) {
      item['updated_at'] = _formatDateTimeForSheet(rawUpdated);
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

  Map<String, dynamic> _mapInvoiceFields(Map<String, dynamic> invoice) {
    final newMap = Map<String, dynamic>.from(invoice);

    if (newMap.containsKey('Invoice Number')) {
      newMap['Invoice Number'] = newMap['Invoice Number'].toString();
    }

    if (newMap.containsKey('supplierBottleID')) {
      newMap['purSupplierBottleID'] = newMap['supplierBottleID'];
      newMap.remove('supplierBottleID');
    }

    if (newMap['invoiceDetailsID'] == null || newMap['invoiceDetailsID'].toString().isEmpty) {
      newMap['invoiceDetailsID'] = _generateUuid();
    }

    return newMap;
  }

  String _generateUuid() {
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(4, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  bool isValidServerId(String id) {
    return RegExp(r'^[a-f0-9]{8}$').hasMatch(id);
  }
}

// Cache Entry Class
class _CacheEntry {
  final List<Map<String, dynamic>> data;
  final DateTime timestamp;

  _CacheEntry({
    required this.data,
    required this.timestamp,
  });
}