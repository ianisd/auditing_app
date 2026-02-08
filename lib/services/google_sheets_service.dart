import 'dart:convert';
import 'package:http/http.dart' as http;
import 'logger_service.dart';

class GoogleSheetsService {
  final String scriptUrl;
  final LoggerService? logger; // NEW: Inject Logger

  GoogleSheetsService({
    required this.scriptUrl,
    this.logger,
  });

  // ===========================================================================
  // SYNC OPERATIONS (POST)
  // ===========================================================================

  Future<bool> syncStockCounts(List<Map<String, dynamic>> counts) async {
    return _sendPostRequest('syncStockCounts', {'data': counts});
  }

  Future<bool> syncNewProducts(List<Map<String, dynamic>> products) async {
    return _sendPostRequest('syncNewProducts', {'endpoint': 'syncNewProducts', 'data': products});
  }

  Future<bool> syncNewLocations(List<Map<String, dynamic>> locations) async {
    return _sendPostRequest('syncNewLocations', {'endpoint': 'syncNewLocations', 'data': locations});
  }

  // Helper for POST requests
  Future<bool> _sendPostRequest(String tag, Map<String, dynamic> jsonData) async {
    try {
      final body = json.encode(jsonData);
      logger?.info('POST [$tag]: Sending ${body.length} bytes...');

      final client = http.Client();
      final request = http.Request('POST', Uri.parse(scriptUrl));
      request.headers['Content-Type'] = 'application/json';
      request.body = body;
      request.followRedirects = false;

      final streamedResponse = await client.send(request);
      var response = await http.Response.fromStream(streamedResponse);

      // Handle 302 Redirect
      if (response.statusCode == 302 || response.statusCode == 307) {
        final location = response.headers['location'];
        if (location != null && location.isNotEmpty) {
          logger?.info('POST Redirecting...');
          final getRequest = http.Request('GET', Uri.parse(location));
          if (response.headers['set-cookie'] != null) {
            getRequest.headers['cookie'] = response.headers['set-cookie']!;
          }
          final getStreamedResponse = await client.send(getRequest);
          response = await http.Response.fromStream(getStreamedResponse);
        }
      }

      logger?.info('POST Response: ${response.statusCode}');

      if (response.statusCode == 200) {
        if (response.body.trim().toUpperCase().startsWith('<HTML')) {
          logger?.error('POST Failed: Received HTML (Script Error/Auth Page)');
          return false;
        }
        final result = json.decode(response.body);
        if (result['status'] == 'success' || result['success'] == true) {
          return true;
        } else {
          logger?.error('POST Failed: Server message: ${result['message']}');
          return false;
        }
      } else {
        logger?.error('POST HTTP Error: ${response.statusCode}');
      }
      return false;
    } catch (e) {
      logger?.error('POST Exception', e);
      return false;
    }
  }

  // ===========================================================================
  // FETCH OPERATIONS (GET)
  // ===========================================================================

  Future<List<Map<String, dynamic>>> fetchLocations() async => _fetchTable('Locations');
  Future<List<Map<String, dynamic>>> fetchInventory() async => _fetchTable('Inventory');
  Future<List<Map<String, dynamic>>> fetchAudits() async => _fetchTable('AuditCalendar');
  Future<List<Map<String, dynamic>>> fetchStockCounts() async => _fetchTable('StockCounts');
  Future<List<Map<String, dynamic>>> fetchPurchases() async => _fetchTable('Purchases');
  Future<List<Map<String, dynamic>>> fetchStoreSalesData() async => _fetchTable('StoreSalesData');
  Future<List<Map<String, dynamic>>> fetchItemSales() async => _fetchTable('ItemSales');

  Future<List<Map<String, dynamic>>> fetchMasterProducts() async => _fetchTable('MasterProducts');
  Future<List<Map<String, dynamic>>> fetchMasterBarcodes() async => _fetchTable('MasterBarcodes');

  // Computed Costs
  Future<List<Map<String, dynamic>>> fetchComputedCosts() async => _fetchTable('MasterCostsComputed');

  // Generic Fetch Helper
  Future<List<Map<String, dynamic>>> _fetchTable(String tableName) async {
    try {
      // logger?.info('GET Fetching $tableName...');
      // (Commented out to reduce noise, enable if needed)

      final client = http.Client();
      final request = http.Request('GET', Uri.parse('$scriptUrl?table=$tableName'));
      request.followRedirects = false;

      final streamedResponse = await client.send(request);
      var response = await http.Response.fromStream(streamedResponse);

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
          logger?.error('GET $tableName Failed: Received HTML');
          return [];
        }

        final dynamic decoded = json.decode(response.body);

        // Check for specific error objects returned by script
        if (decoded is Map && decoded['error'] != null) {
          logger?.error('GET $tableName Server Error: ${decoded['error']}');
          return [];
        }

        if (decoded is List) {
          return decoded.map((item) {
            if (item is Map) return Map<String, dynamic>.from(item);
            return <String, dynamic>{};
          }).toList();
        }
      } else {
        logger?.error('GET $tableName HTTP Error: ${response.statusCode}');
      }
      return [];
    } catch (e) {
      logger?.error('GET $tableName Exception', e);
      return [];
    }
  }
}