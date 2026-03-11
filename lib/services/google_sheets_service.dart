import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart'; // For kDebugMode
import 'logger_service.dart';

class GoogleSheetsService {
  final http.Client _client = http.Client();
  final String masterScriptUrl;
  final String storeIdentifier;
  final LoggerService? logger;

  // Cache for master suppliers to avoid repeated network calls
  List<Map<String, dynamic>>? _cachedMasterSuppliers;

  GoogleSheetsService({
    required this.masterScriptUrl,
    required this.storeIdentifier,
    this.logger,
  });

  void dispose() {
    _client.close();
  }

  // ---------------------------------------------------------------------------
  // 核心 CORE: POST Request with "Follow as POST" Redirect Handling & Retry
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _sendPostRequest(
      String tag,
      Map<String, dynamic> jsonData, {
        int maxRetries = 2,
      }) async {
    int attempt = 0;

    while (attempt <= maxRetries) {
      attempt++;
      try {
        final payload = {
          'data': jsonData['data'],
          'storeIdentifier': storeIdentifier,
          'endpoint': jsonData['endpoint'] ?? tag,
        };

        final body = json.encode(payload);
        final uri = Uri.parse(masterScriptUrl);

        if (kDebugMode) {
          print('📤 [Attempt $attempt] POST: $tag | Endpoint: ${jsonData['endpoint']}');
        }

        // 1. Initial POST Request
        var request = http.Request('POST', uri);
        request.headers['Content-Type'] = 'application/json';
        request.body = body;
        request.followRedirects = false;

        var streamedResponse = await _client
            .send(request)
            .timeout(const Duration(seconds: 30));

        var response = await http.Response.fromStream(streamedResponse);

        // 2. Handle Redirects - SWITCH TO GET for the redirect URL!
        if (response.statusCode == 302 || response.statusCode == 303) {
          final location = response.headers['location'];
          if (location != null) {
            if (kDebugMode) print('🔄 Redirecting to: $location');

            // ✅ FIX: Use GET, not POST
            final redirectRequest = http.Request('GET', Uri.parse(location));
            redirectRequest.followRedirects = false;

            final redirectStream = await _client
                .send(redirectRequest)
                .timeout(const Duration(seconds: 30));

            response = await http.Response.fromStream(redirectStream);
          }
        }

        if (response.statusCode == 200) {
          if (response.body.trim().toUpperCase().startsWith('<HTML')) {
            logger?.error('❌ POST Failed: Received HTML response');
            return {
              'success': false,
              'message': 'Server returned HTML instead of JSON. Check Script deployment.'
            };
          }
          return _parseSyncResponse(response.body);
        } else {
          logger?.error('❌ HTTP Error: ${response.statusCode}');
          if (response.statusCode >= 400 && response.statusCode < 500) {
            return {'success': false, 'message': 'HTTP Error: ${response.statusCode}'};
          }
        }
      } on SocketException catch (e) {
        logger?.error('⚠️ Network Error (Attempt $attempt)', e);
        if (attempt > maxRetries) return {'success': false, 'message': 'Network error: $e'};
      } on TimeoutException {
        logger?.error('⚠️ Timeout (Attempt $attempt)');
        if (attempt > maxRetries) return {'success': false, 'message': 'Connection timed out'};
      } catch (e) {
        logger?.error('❌ Exception in $tag', e);
        return {'success': false, 'message': 'Exception: $e'};
      }

      // Delay before retry
      if (attempt <= maxRetries) {
        await Future.delayed(Duration(seconds: attempt));
      }
    }

    return {'success': false, 'message': 'Request failed after $maxRetries retries'};
  }

  // Helper to standardize sync responses

  Map<String, dynamic> _parseSyncResponse(String responseBody) {
    try {
      final result = json.decode(responseBody);
      if (result is Map<String, dynamic>) {
        return {
          'success': result['status'] == 'success' || result['success'] == true,
          'newCount': result['newCount'] ?? 0,
          'updatedCount': result['updatedCount'] ?? 0,  // 🔴 ADD THIS
          'duplicateCount': result['duplicateCount'] ?? 0,
          'duplicates': result['duplicates'] ?? [],
          'message': result['message'] ?? 'Sync operation completed',
        };
      }
    } catch (e) {
      logger?.error('Error parsing sync response', e);
    }
    return {'success': false, 'message': 'Invalid server response format'};
  }

  // ---------------------------------------------------------------------------
  // 核心 CORE: GET Request
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _fetchTable(String tableName) async {
    print('DEBUG: Fetching table: "$tableName"');
    StackTrace.current.toString().split('\n').take(5).forEach((line) => print('  $line'));
    // Validate table name
    if (tableName.isEmpty) {
      logger?.error('❌ _fetchTable called with EMPTY table name');
      return [];
    }

    try {
      final url = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': tableName,
          'storeIdentifier': storeIdentifier,
        },
      );

      if (kDebugMode) {
        print('📤 GET Request: $tableName');
        print('   URL: $url');
      }

      final response = await _client.get(url).timeout(const Duration(seconds: 20));

      if (kDebugMode) {
        print('📥 Response Status: ${response.statusCode}');
        print('📥 Response Size: ${response.body.length} bytes');
      }

      if (response.statusCode == 200) {
        // Check for HTML response (error page)
        if (response.body.trim().startsWith('<')) {
          logger?.error('❌ GET $tableName Failed: Received HTML response');
          if (kDebugMode) {
            final previewLength = response.body.length > 200 ? 200 : response.body.length;
            print('   HTML Preview: ${response.body.substring(0, previewLength)}...');
          }
          return [];
        }

        try {
          final dynamic decoded = json.decode(response.body);

          // Handle case where API returns { "data": [...] }
          if (decoded is Map) {
            // Check for error response
            if (decoded.containsKey('error')) {
              logger?.error('❌ Server error for $tableName: ${decoded['error']}');
              return [];
            }

            // Handle wrapped data
            if (decoded.containsKey('data') && decoded['data'] is List) {
              final dataList = decoded['data'] as List;
              if (kDebugMode) {
                print('   ✅ Found ${dataList.length} items (wrapped in data field)');
              }
              return dataList.map((item) {
                if (item is Map) return Map<String, dynamic>.from(item);
                return <String, dynamic>{};
              }).toList();
            }
          }

          // Handle direct array response
          if (decoded is List) {
            if (kDebugMode) {
              print('   ✅ Found ${decoded.length} items');
            }
            return decoded.map((item) {
              if (item is Map) return Map<String, dynamic>.from(item);
              return <String, dynamic>{};
            }).toList();
          }

          // Unexpected response format
          logger?.error('⚠️ Unexpected response format for $tableName: ${decoded.runtimeType}');
          return [];

        } catch (e) {
          logger?.error('❌ JSON parse error for $tableName', e);
          if (kDebugMode) {
            final previewLength = response.body.length > 200 ? 200 : response.body.length;
            print('   Body preview: ${response.body.substring(0, previewLength)}...');
          }
          return [];
        }
      } else if (response.statusCode == 404) {
        logger?.error('❌ Table not found: $tableName (404)');
        return [];
      } else if (response.statusCode == 302 || response.statusCode == 303) {
        // Handle redirect for GET requests (rare but possible)
        final location = response.headers['location'];
        if (location != null) {
          if (kDebugMode) {
            print('🔄 Redirecting GET to: $location');
          }

          try {
            final redirectResponse = await _client.get(Uri.parse(location)).timeout(const Duration(seconds: 20));

            if (redirectResponse.statusCode == 200 && !redirectResponse.body.trim().startsWith('<')) {
              final decoded = json.decode(redirectResponse.body);
              if (decoded is List) {
                return decoded.map((item) {
                  if (item is Map) return Map<String, dynamic>.from(item);
                  return <String, dynamic>{};
                }).toList();
              }
            }
          } catch (e) {
            logger?.error('❌ Error following redirect for $tableName', e);
          }
        }
        return [];
      } else {
        logger?.error('❌ HTTP Error ${response.statusCode} for $tableName');
        return [];
      }
    } on TimeoutException catch (e) {
      logger?.error('⏱️ Timeout fetching $tableName', e);
      return [];
    } on SocketException catch (e) {
      logger?.error('📡 Network error fetching $tableName', e);
      return [];
    } catch (e) {
      logger?.error('❌ Exception fetching $tableName', e);
      return [];
    }
  }

  // Update the fetchLargeTableInBatches method to include timeoutSeconds
  Future<List<Map<String, dynamic>>> fetchLargeTableInBatches(
      String tableName, {
        int batchSize = 2000, // REDUCE from 5000 to 2000
        int timeoutSeconds = 60, // INCREASE from 30 to 60
        Function(int received, int total)? onProgress,
      }) async {
    print('🔍 FETCHING $tableName in batches of $batchSize with ${timeoutSeconds}s timeout');

    List<Map<String, dynamic>> allResults = [];
    int offset = 0;
    int batchNumber = 1;
    int maxRetries = 3; // Add retry logic

    while (true) {
      int retryCount = 0;
      List<Map<String, dynamic>>? batch;

      while (retryCount < maxRetries) {
        try {
          print('📦 Fetching batch $batchNumber (offset: $offset, limit: $batchSize, attempt: ${retryCount + 1})');

          batch = await fetchTableBatch(
            tableName,
            offset: offset,
            limit: batchSize,
            timeoutSeconds: timeoutSeconds,
          );

          break; // Success, exit retry loop
        } catch (e) {
          retryCount++;
          print('⚠️ Batch $batchNumber failed (attempt $retryCount): $e');

          if (retryCount >= maxRetries) {
            print('❌ Batch $batchNumber failed after $maxRetries attempts, aborting');
            return allResults; // Return what we have so far
          }

          // Wait before retrying (exponential backoff)
          await Future.delayed(Duration(seconds: retryCount * 2));
        }
      }

      if (batch == null || batch.isEmpty) {
        break; // No more data
      }

      allResults.addAll(batch);
      onProgress?.call(allResults.length, allResults.length + batchSize); // Approximate

      if (batch.length < batchSize) {
        break; // Last batch
      }

      offset += batchSize;
      batchNumber++;

      // Small delay between batches
      await Future.delayed(const Duration(milliseconds: 1000));
    }

    print('✅ Completed fetching $tableName: ${allResults.length} records');
    return allResults;
  }

// Update fetchTableBatch to accept timeoutSeconds
  Future<List<Map<String, dynamic>>> fetchTableBatch(
      String tableName, {
        int offset = 0,
        int limit = 2000,
        int timeoutSeconds = 60,
      }) async {
    try {
      final url = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': tableName,
          'storeIdentifier': storeIdentifier,
          'offset': offset.toString(),
          'limit': limit.toString(),
        },
      );

      final response = await _client
          .get(url)
          .timeout(Duration(seconds: timeoutSeconds));

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);

        // Handle paginated response
        if (decoded is Map && decoded.containsKey('data')) {
          final data = decoded['data'] as List;
          return data.map((item) => Map<String, dynamic>.from(item)).toList();
        }

        // Handle direct array response
        if (decoded is List) {
          return decoded.map((item) => Map<String, dynamic>.from(item)).toList();
        }
      }
    } on TimeoutException catch (e) {
      print('⏱️ Timeout fetching batch $tableName at offset $offset');
      rethrow; // Rethrow to trigger retry
    } catch (e) {
      print('Error fetching batch $tableName: $e');
      rethrow;
    }

    return [];
  }

// Also update getTableRowCount to be more robust
  Future<int> getTableRowCount(String tableName) async {
    try {
      final url = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': tableName,
          'storeIdentifier': storeIdentifier,
          'countOnly': 'true',
        },
      );

      final response = await _client.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is Map && decoded.containsKey('total')) {
          return decoded['total'] as int;
        }
        // If it's a direct array, return its length
        if (decoded is List) {
          return decoded.length;
        }
      }
    } catch (e) {
      logger?.error('Error getting row count for $tableName', e);
    }

    // If we can't get count, return a large number to trigger batching anyway
    // The loop will stop when batches return fewer than batchSize
    return 999999;
  }

  // ---------------------------------------------------------------------------
  // SYNC OPERATIONS
  // ---------------------------------------------------------------------------

  Future<bool> syncStockCounts(List<Map<String, dynamic>> counts) async {
    final payload = counts.map((c) {
      final item = Map<String, dynamic>.from(c);
      // Ensure logic required by script
      item['deleted'] = (c['syncStatus'] == 'deleted');
      if (item['stock_id'] == null && item['id'] != null) {
        item['stock_id'] = item['id'];
      }
      return item;
    }).toList();

    final result = await _sendPostRequest(
        'syncStockCounts',
        {'data': payload, 'endpoint': 'syncStockCounts'}
    );
    return result['success'] == true;
  }

  Future<bool> syncNewProducts(List<Map<String, dynamic>> products) async {
    final result = await _sendPostRequest(
        'syncNewProducts',
        {'data': products, 'endpoint': 'syncNewProducts'}
    );
    return result['success'] == true;
  }

  Future<bool> syncNewLocations(List<Map<String, dynamic>> locations) async {
    final result = await _sendPostRequest(
        'syncNewLocations',
        {'data': locations, 'endpoint': 'syncNewLocations'}
    );
    return result['success'] == true;
  }

  // Standardized Invoice Sync with Field Mapping
  // In google_sheets_service.dart
  Future<Map<String, dynamic>> syncInvoiceDetailsWithResult(List<Map<String, dynamic>> invoices) async {
    // Apply critical field mapping fixes
    final mappedInvoices = invoices.map(_mapInvoiceFields).toList();

    // 🔴 LOG THE FIRST MAPPED INVOICE TO VERIFY
    if (mappedInvoices.isNotEmpty) {
      print('📋 First mapped invoice: ${mappedInvoices.first}');
      print('  - Invoice Number field: "${mappedInvoices.first['Invoice Number']}"');
      print('  - Invoice Nr. field: "${mappedInvoices.first['Invoice Nr.']}"');
    }

    final result = await _sendPostRequest('syncInvoiceDetails', {
      'endpoint': 'syncInvoiceDetails',
      'data': mappedInvoices,
    });

    print('📥 Raw syncInvoiceDetails result: $result');

    return result;
  }

  // Wrapper for backward compatibility
  Future<bool> syncInvoiceDetails(List<Map<String, dynamic>> invoices) async {
    final result = await syncInvoiceDetailsWithResult(invoices);
    return result['success'] == true;
  }

  Future<bool> syncPurchases(List<Map<String, dynamic>> purchases) async {
    // Ensure IDs exist
    final sanitized = purchases.map((p) {
      final item = Map<String, dynamic>.from(p);
      if (item['purchases_ID'] == null || item['purchases_ID'].toString().isEmpty) {
        item['purchases_ID'] = _generateUuid();
      }
      return item;
    }).toList();

    final result = await _sendPostRequest(
        'syncPurchases',
        {'endpoint': 'syncPurchases', 'data': sanitized}
    );
    return result['success'] == true;
  }

  // Single Item Operations
  Future<bool> deleteInvoice(String invoiceId) async {
    final result = await _sendPostRequest('deleteInvoice', {
      'endpoint': 'deleteInvoice',
      'data': {'invoiceId': invoiceId}
    });
    return result['success'] == true;
  }

  Future<bool> deletePurchase(String purchaseId) async {
    final result = await _sendPostRequest('deletePurchase', {
      'endpoint': 'deletePurchase',
      'data': {'purchaseId': purchaseId}
    });
    return result['success'] == true;
  }

  Future<bool> updateInvoice(Map<String, dynamic> invoice) async {
    final result = await _sendPostRequest('updateInvoice', {
      'endpoint': 'updateInvoice',
      'data': _mapInvoiceFields(invoice)
    });
    return result['success'] == true;
  }

  Future<bool> updatePurchase(Map<String, dynamic> purchase) async {
    final result = await _sendPostRequest('updatePurchase', {
      'endpoint': 'updatePurchase',
      'data': purchase
    });
    return result['success'] == true;
  }

  Future<bool> syncPluMappings(List<Map<String, dynamic>> mappings) async {
    final result = await _sendPostRequest(
        'syncPluMappings',
        {'endpoint': 'syncPluMappings', 'data': mappings}
    );
    return result['success'] == true;
  }

  // ---------------------------------------------------------------------------
// FETCH OPERATIONS
// ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> fetchLocations() async => _fetchTable('Locations');
  Future<List<Map<String, dynamic>>> fetchInventory() async => _fetchTable('Inventory');
  Future<List<Map<String, dynamic>>> fetchAudits() async => _fetchTable('AuditCalendar');
  Future<List<Map<String, dynamic>>> fetchPurchases() async => _fetchTable('Purchases');
  Future<List<Map<String, dynamic>>> fetchStoreSalesData() async => _fetchTable('StoreSalesData');
  Future<List<Map<String, dynamic>>> fetchItemSales() async => _fetchTable('ItemSales');
  Future<List<Map<String, dynamic>>> fetchMasterProducts() async => _fetchTable('MasterProducts');
  Future<List<Map<String, dynamic>>> fetchMasterBarcodes() async => _fetchTable('MasterBarcodes');

  Future<List<Map<String, dynamic>>> fetchInvoices() async {
    if (kDebugMode) print('🔍 FETCHING INVOICES');
    return _fetchTable('InvoiceDetails');
  }

// 🔥 NEW: Fetch invoice details
  Future<List<Map<String, dynamic>>> fetchInvoiceDetails() async {
    if (kDebugMode) print('🔍 FETCH INVOICE DETAILS');
    return _fetchTable('InvoiceDetails');
  }

// 🔥 NEW: Alias for fetchInvoiceDetails (if needed)
  Future<List<Map<String, dynamic>>> fetchAllInvoices() async {
    if (kDebugMode) print('🔍 FETCH ALL INVOICES');
    return _fetchTable('InvoiceDetails');
  }

  Future<List<Map<String, dynamic>>> fetchStockCounts() async {
    if (kDebugMode) print('🔍 FETCH STOCK COUNTS');
    return _fetchTable('StockCounts');
  }

  Future<List<Map<String, dynamic>>> fetchComputedCosts() async {
    if (kDebugMode) print('🔍 FETCH COMPUTED COSTS');
    return _fetchTable('MasterCostsComputed');
  }

  Future<List<Map<String, dynamic>>> fetchMasterSuppliers() async {
    if (_cachedMasterSuppliers != null && _cachedMasterSuppliers!.isNotEmpty) {
      return _cachedMasterSuppliers!;
    }

    const maxRetries = 3;
    int attempt = 0;

    while (attempt < maxRetries) {
      try {
        attempt++;
        final url = Uri.parse(masterScriptUrl).replace(
          queryParameters: {
            'table': 'MasterSuppliers',
            'storeIdentifier': 'MASTER',
          },
        );

        final response = await _client.get(url).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is List) {
            _cachedMasterSuppliers = data.cast<Map<String, dynamic>>();
            return _cachedMasterSuppliers!;
          }
        }
      } catch (e) {
        logger?.error('fetchMasterSuppliers Attempt $attempt failed', e);
        if (attempt == maxRetries) break;
        await Future.delayed(Duration(seconds: attempt));
      }
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> fetchItemsIssued() async {
    if (kDebugMode) print('🔍 FETCHING ITEMS ISSUED');
    return _fetchTable('ItemsIssued');
  }

  Future<List<Map<String, dynamic>>> fetchStockIssues() async {
    if (kDebugMode) print('🔍 FETCHING STOCK ISSUES');
    return _fetchTable('StockIssues');
  }

  Future<List<Map<String, dynamic>>> fetchItemsIssuedMap() async {
    if (kDebugMode) print('🔍 FETCHING ITEMS ISSUED MAP');
    return _fetchTable('ItemsIssuedMap');
  }

  Future<List<Map<String, dynamic>>> fetchPluMappings() async {
    if (kDebugMode) print('🔍 FETCH PLU MAPPINGS');
    return _fetchTable('PluMappings');
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  // Maps app-side field names to Google Sheets column headers
  Map<String, dynamic> _mapInvoiceFields(Map<String, dynamic> invoice) {
    // Create a copy without renaming fields
    final newMap = Map<String, dynamic>.from(invoice);

    // 🔴 CRITICAL: Ensure Invoice Number is a string with leading zeros
    if (newMap.containsKey('Invoice Number')) {
      // Convert to string explicitly
      newMap['Invoice Number'] = newMap['Invoice Number'].toString();
      print('📋 Sending invoice number to GAS: "${newMap['Invoice Number']}"');
    }

    // Only map supplierBottleID if needed
    if (newMap.containsKey('supplierBottleID')) {
      newMap['purSupplierBottleID'] = newMap['supplierBottleID'];
      newMap.remove('supplierBottleID');
    }

    // Ensure ID generation if missing
    if (newMap['invoiceDetailsID'] == null || newMap['invoiceDetailsID'].toString().isEmpty) {
      newMap['invoiceDetailsID'] = _generateUuid();
    }

    return newMap;
  }

  // Simple V4-like UUID generator to avoid external dependencies
  // Replace the current _generateUuid with this
  String _generateUuid() {
    // Match server's 8-character hex format
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(4, (_) => rnd.nextInt(256));

    // Format as 8 hex characters
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

// Optional: Add validation to ensure format matches
  bool isValidServerId(String id) {
    return RegExp(r'^[a-f0-9]{8}$').hasMatch(id);
  }
}