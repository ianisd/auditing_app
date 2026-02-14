import 'dart:convert';
import 'package:http/http.dart' as http;
import 'logger_service.dart';

class GoogleSheetsService {
  final http.Client _client = http.Client();
  final String masterScriptUrl; // Single master script
  final String storeIdentifier; // Either store ID or sheet ID from URL
  final LoggerService? logger;

  GoogleSheetsService({
    required this.masterScriptUrl,
    required this.storeIdentifier, // Extracted from original URL
    this.logger,
  });

  void dispose() {
    _client.close();
  }

  // Send request to master script with store identifier
  Future<bool> _sendPostRequest(String tag, Map<String, dynamic> jsonData) async {
    try {
      final payload = {
        'data': jsonData['data'],
        'storeIdentifier': storeIdentifier, // Critical: pass store identifier
        'operation': jsonData['endpoint'] ?? tag,
      };

      final body = json.encode(payload);
      final request = http.Request('POST', Uri.parse(masterScriptUrl));
      request.headers['Content-Type'] = 'application/json';
      request.body = body;

      final streamedResponse = await _client.send(request);
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        if (response.body.trim().toUpperCase().startsWith('<HTML')) {
          logger?.error('POST Failed: Received HTML (Script Error/Auth Page)');
          return false;
        }

        try {
          final result = json.decode(response.body);
          return result['status'] == 'success' || result['success'] == true;
        } catch (e) {
          logger?.error('POST Parse Error', e);
          return false;
        }
      } else {
        logger?.error('POST HTTP Error: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      logger?.error('POST Exception', e);
      return false;
    }
  }

  // GET request with store identifier
  Future<List<Map<String, dynamic>>> _fetchTable(String tableName) async {
    try {
      final url = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': tableName,
          'storeIdentifier': storeIdentifier, // Critical: specify store
        },
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        if (response.body.trim().startsWith('<')) {
          logger?.error('GET $tableName Failed: Received HTML');
          return [];
        }

        final dynamic decoded = json.decode(response.body);
        if (decoded is List) {
          return decoded.map((item) {
            if (item is Map) return Map<String, dynamic>.from(item);
            return <String, dynamic>{};
          }).toList();
        }
      }
      return [];
    } catch (e) {
      logger?.error('GET $tableName Exception', e);
      return [];
    }
  }

  // SYNC OPERATIONS - All route through master script
  Future<bool> syncStockCounts(List<Map<String, dynamic>> counts) async {
    final payload = counts.map((c) {
      final item = Map<String, dynamic>.from(c);
      item['deleted'] = (c['syncStatus'] == 'deleted');
      if (item['stock_id'] == null && item['id'] != null) {
        item['stock_id'] = item['id'];
      }
      return item;
    }).toList();

    return _sendPostRequest('syncStockCounts', {'data': payload, 'endpoint': 'syncStockCounts'});
  }

  Future<bool> syncNewProducts(List<Map<String, dynamic>> products) async {
    return _sendPostRequest('syncNewProducts', {'data': products, 'endpoint': 'syncNewProducts'});
  }

  Future<bool> syncNewLocations(List<Map<String, dynamic>> locations) async {
    return _sendPostRequest('syncNewLocations', {'data': locations, 'endpoint': 'syncNewLocations'});
  }

  Future<bool> syncInvoiceDetails(List<Map<String, dynamic>> invoices) async {
    return _sendPostRequest('syncInvoiceDetails', {'data': invoices, 'endpoint': 'syncInvoiceDetails'});
  }

  // FETCH OPERATIONS - All route through master script
  Future<List<Map<String, dynamic>>> fetchLocations() async => _fetchTable('Locations');
  Future<List<Map<String, dynamic>>> fetchInventory() async => _fetchTable('Inventory');
  Future<List<Map<String, dynamic>>> fetchAudits() async => _fetchTable('AuditCalendar');
  Future<List<Map<String, dynamic>>> fetchStockCounts() async => _fetchTable('StockCounts');
  Future<List<Map<String, dynamic>>> fetchPurchases() async => _fetchTable('Purchases');
  Future<List<Map<String, dynamic>>> fetchStoreSalesData() async => _fetchTable('StoreSalesData');
  Future<List<Map<String, dynamic>>> fetchItemSales() async => _fetchTable('ItemSales');
  Future<List<Map<String, dynamic>>> fetchMasterProducts() async => _fetchTable('MasterProducts');
  Future<List<Map<String, dynamic>>> fetchMasterBarcodes() async => _fetchTable('MasterBarcodes');
  Future<List<Map<String, dynamic>>> fetchComputedCosts() async => _fetchTable('MasterCostsComputed');

  // Master suppliers come from master sheet (not store-specific)
  Future<List<Map<String, dynamic>>> fetchMasterSuppliers() async {
    try {
      final url = Uri.parse(masterScriptUrl).replace(
        queryParameters: {
          'table': 'MasterSuppliers',
          'storeIdentifier': 'MASTER', // Use master sheet for suppliers
        },
      );

      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) {
          return data.cast<Map<String, dynamic>>();
        }
      }
      return [];
    } catch (e) {
      print('ERROR fetching master suppliers: $e');
      return [];
    }
  }
}