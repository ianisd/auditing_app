import 'dart:convert';
import 'package:http/http.dart' as http;

class GoogleSheetsService {
  final String scriptUrl;

  GoogleSheetsService({required this.scriptUrl});

  // ===========================================================================
  // SYNC OPERATIONS (POST)
  // ===========================================================================

  // 1. Sync Stock Counts
  Future<bool> syncStockCounts(List<Map<String, dynamic>> counts) async {
    try {
      final cleanedCounts = counts.map((c) {
        final clean = Map<String, dynamic>.from(c);
        if (clean['stock_id'] == null && clean['id'] != null) {
          clean['stock_id'] = clean['id'];
        }
        clean['deleted'] = c['syncStatus'] == 'deleted';
        return clean;
      }).toList();

      final body = json.encode({'data': cleanedCounts}); // Default endpoint
      return _sendPostRequest(body);
    } catch (e) {
      print('Sync exception: $e');
      return false;
    }
  }

  // 2. Sync New Products
  Future<bool> syncNewProducts(List<Map<String, dynamic>> products) async {
    try {
      final body = json.encode({
        'endpoint': 'syncNewProducts',
        'data': products
      });
      return _sendPostRequest(body);
    } catch (e) {
      print('Sync New Products exception: $e');
      return false;
    }
  }

  // 3. Sync New Locations
  Future<bool> syncNewLocations(List<Map<String, dynamic>> locations) async {
    try {
      final body = json.encode({
        'endpoint': 'syncNewLocations', // We will add this to the script next
        'data': locations
      });
      return _sendPostRequest(body);
    } catch (e) {
      print('Sync New Locations exception: $e');
      return false;
    }
  }

  // Helper for POST requests
  Future<bool> _sendPostRequest(String body) async {
    final client = http.Client();
    final request = http.Request('POST', Uri.parse(scriptUrl));
    request.headers['Content-Type'] = 'application/json';
    request.body = body;
    request.followRedirects = false;

    final streamedResponse = await client.send(request);
    var response = await http.Response.fromStream(streamedResponse);

    // Handle 302 Redirect manually to keep cookies (Fixes 401 error)
    if (response.statusCode == 302 || response.statusCode == 307) {
      final location = response.headers['location'];
      if (location != null && location.isNotEmpty) {
        final getRequest = http.Request('GET', Uri.parse(location));
        final cookies = response.headers['set-cookie'];
        if (cookies != null) getRequest.headers['cookie'] = cookies;

        final getStreamedResponse = await client.send(getRequest);
        response = await http.Response.fromStream(getStreamedResponse);
      }
    }

    if (response.statusCode == 200) {
      if (response.body.trim().toUpperCase().startsWith('<HTML')) {
        print('Error: Received HTML instead of JSON.');
        return false;
      }
      try {
        final result = json.decode(response.body);
        if (result['debug'] != null) {
          print('--- SERVER LOGS ---');
          for (var log in result['debug']) print(log);
          print('-------------------');
        }
        return result['status'] == 'success' || result['success'] == true;
      } catch (e) {
        print('JSON Parse Error: $e');
        return false;
      }
    }
    return false;
  }

  // ===========================================================================
  // FETCH OPERATIONS (GET)
  // ===========================================================================

  // Standard Store Data
  Future<List<Map<String, dynamic>>> fetchLocations() async => _fetchTable('Locations');
  Future<List<Map<String, dynamic>>> fetchInventory() async => _fetchTable('Inventory');
  Future<List<Map<String, dynamic>>> fetchAudits() async => _fetchTable('AuditCalendar');
  Future<List<Map<String, dynamic>>> fetchStockCounts() async => _fetchTable('StockCounts');

  // --- NEW: Master Data Methods ---
  Future<List<Map<String, dynamic>>> fetchMasterProducts() async => _fetchTable('MasterProducts');
  Future<List<Map<String, dynamic>>> fetchMasterBarcodes() async => _fetchTable('MasterBarcodes');
  Future<List<Map<String, dynamic>>> fetchMasterCosts() async => _fetchTable('MasterCosts');

  // --- ADDED: Fetch Computed Costs (Latest Average Logic) ---
  Future<List<Map<String, dynamic>>> fetchComputedCosts() async => _fetchTable('MasterCostsComputed');

  Future<List<Map<String, dynamic>>> fetchPurchases() async => _fetchTable('Purchases');
  Future<List<Map<String, dynamic>>> fetchStoreSalesData() async {
    // This matches the 'StoreSalesData' key we added to the App Script Config
    return _fetchTable('StoreSalesData');
  }

  Future<List<Map<String, dynamic>>> fetchItemSales() async {
    // This matches the 'ItemSales' key we added to the App Script Config
    return _fetchTable('ItemSales');
  }

  // Generic Fetch Helper
  Future<List<Map<String, dynamic>>> _fetchTable(String tableName) async {
    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse('$scriptUrl?table=$tableName'));
      request.followRedirects = false;

      final streamedResponse = await client.send(request);
      var response = await http.Response.fromStream(streamedResponse);

      // Handle Redirects
      if (response.statusCode == 302 || response.statusCode == 307) {
        final location = response.headers['location'];
        if (location != null) {
          final getRequest = http.Request('GET', Uri.parse(location));
          if (response.headers['set-cookie'] != null) {
            getRequest.headers['cookie'] = response.headers['set-cookie']!;
          }
          final getStreamedResponse = await client.send(getRequest);
          response = await http.Response.fromStream(getStreamedResponse);
        }
      }

      if (response.statusCode == 200) {
        if (response.body.trim().startsWith('<')) {
          print('Fetch $tableName FAILED: Received HTML');
          return [];
        }

        final dynamic decoded = json.decode(response.body);

        // Safe List mapping
        if (decoded is List) {
          return decoded.map((item) {
            if (item is Map) return Map<String, dynamic>.from(item);
            return <String, dynamic>{};
          }).toList();
        }

        if (decoded is Map && decoded['data'] is List) {
          return (decoded['data'] as List).map((item) {
            if (item is Map) return Map<String, dynamic>.from(item);
            return <String, dynamic>{};
          }).toList();
        }
      }
      return [];
    } catch (e) {
      print('Fetch $tableName EXCEPTION: $e');
      return [];
    }
  }

}