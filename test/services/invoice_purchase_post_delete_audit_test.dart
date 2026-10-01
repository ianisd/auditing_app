import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// LIVE integration/regression audit for the Apps Script InvoiceDetails +
/// Purchases POST/delete contract.
///
/// This intentionally talks to the deployed Apps Script and a REAL TEST store
/// spreadsheet. Do not point STORE_ID at a production store.
///
/// Run:
/// flutter test test/integration/invoice_purchase_post_delete_audit_test.dart \
///   --dart-define=APPS_SCRIPT_URL="https://script.google.com/macros/s/.../exec" \
///   --dart-define=STORE_ID="YOUR_TEST_STORE_SPREADSHEET_ID"
///
/// The test creates uniquely prefixed AUDIT_TEST_* rows and removes them in
/// tearDownAll, even if an assertion fails.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const apiUrl = String.fromEnvironment('APPS_SCRIPT_URL');
  const storeId = String.fromEnvironment('STORE_ID');

  late AppsScriptAuditClient api;
  late String runId;
  late String invoiceId;
  late List<String> purchaseIds;

  Map<String, dynamic> invoice({String suffix = ''}) => {
    'invoiceDetailsID': invoiceId,
    'Invoice Number': 'AUDIT-INV-$runId$suffix',
    'GRV Reference': 'AUDIT-GRV-$runId',
    'Supplier Name': 'AUDIT TEST SUPPLIER',
    'supplierID': 'AUDIT_SUPPLIER',
    // Based on sample GRV 6.csv: 17/09/2026.
    'Date of Purchase': '2026-09-17T00:00:00.000',
    'Delivery Date': '2026-09-17T00:00:00.000',
    'Total Cost Ex Vat': 0.0,
    'Total Cost Inc Vat': 0.0,
    'syncStatus': 'pending',
  };

  Map<String, dynamic> purchase(
      int index, {
        String? name,
        double? qtyCases,
        double? packSize,
        double? unitCost,
      }) {
    final q = qtyCases ?? [10.0, 10.0, 6.0][index];
    final pack = packSize ?? [24.0, 24.0, 1.0][index];
    final cost = unitCost ?? [14.4792, 16.5833, 812.2634][index];
    final bottles = q * pack;

    return {
      'Date': '2026-09-17T00:00:00.000',
      'purchases_ID': purchaseIds[index],
      'Invoice Nr.': 'AUDIT-INV-$runId',
      'invoiceDetailsID': invoiceId,
      'GRV Reference': 'AUDIT-GRV-$runId',
      'supplierID': 'AUDIT_SUPPLIER',
      'Supplier': 'AUDIT TEST SUPPLIER',
      'Barcode': 'AUDIT_BARCODE_${index + 1}_$runId',
      // Realistic product/quantity/cost shapes from the supplied GRV.
      'Purchased Product Name':
      name ?? ['BRUTAL FRUIT', 'CCORONA', 'DON JULIO'][index],
      'purSupplierBottleID': 'AUDIT_PLU_${index + 1}',
      'Main Category': 'AUDIT',
      'Category': 'AUDIT',
      'Single Unit Volume': index == 2 ? 750.0 : 330.0,
      'UoM': 'ml',
      'Cost Per Bottle': cost,
      'Inv. Date of Purchase': '2026-09-17T00:00:00.000',
      'Stock Delivery Date': '2026-09-17T00:00:00.000',
      'Case/Pack Size': pack.toString(),
      'Qty Purchased': q,
      'Purchases Bottles': bottles,
      'Purchase Units': bottles,
      'Cost of Purchases': bottles * cost,
      'Complementary Bottles': 0,
      'Complementary Units': 0,
      'Total Stock In Bottles': bottles,
      'Total Stock In Units': bottles,
      'syncStatus': 'pending',
    };
  }

  setUpAll(() {
    expect(
      apiUrl,
      isNotEmpty,
      reason: 'Pass --dart-define=APPS_SCRIPT_URL=<deployed Apps Script URL>',
    );
    expect(
      storeId,
      isNotEmpty,
      reason: 'Pass --dart-define=STORE_ID=<TEST store spreadsheet ID>',
    );

    runId = DateTime.now().microsecondsSinceEpoch.toString();
    invoiceId = 'AUDIT_TEST_INV_$runId';
    purchaseIds = List.generate(4, (i) => 'AUDIT_TEST_PUR_${i + 1}_$runId');
    api = AppsScriptAuditClient(apiUrl: apiUrl, storeId: storeId);
  });

  tearDownAll(() async {
    // Idempotent cleanup: server deleteInvoice also removes child purchases.
    try {
      await api.post(
        'deleteInvoice',
        {'invoiceDetailsID': invoiceId},
        transactionId: 'cleanup_invoice_$runId',
      );
    } catch (_) {}

    // Extra safety if invoice creation failed but purchase creation succeeded.
    try {
      await api.post(
        'deletePurchases',
        {'purchaseIds': purchaseIds},
        transactionId: 'cleanup_purchases_$runId',
      );
    } catch (_) {}

    api.close();
  });

  group('InvoiceDetails + Purchases live POST/delete audit', () {
    test('01 CREATE invoice, verify server row and date fields', () async {
      final result = await api.post(
        'syncInvoiceDetails',
        [invoice()],
        transactionId: 'create_invoice_$runId',
      );
      expectSuccess(result);

      final rows = await api.findRows(
        'InvoiceDetails',
        'invoiceDetailsID',
        invoiceId,
      );
      expect(rows, hasLength(1));
      expect(rows.single['Invoice Number'], 'AUDIT-INV-$runId');
      expect(rows.single['GRV Reference'], 'AUDIT-GRV-$runId');
      expect(dateOnly(rows.single['Date of Purchase']), '2026-09-17');
      expect(dateOnly(rows.single['Delivery Date']), '2026-09-17');
    });

    test('02 replay same transaction is idempotent', () async {
      const txPrefix = 'replay_invoice_';
      final payload = [invoice()];

      final first = await api.post(
        'syncInvoiceDetails',
        payload,
        transactionId: '$txPrefix$runId',
      );
      expectSuccess(first);

      final second = await api.post(
        'syncInvoiceDetails',
        payload,
        transactionId: '$txPrefix$runId',
      );
      expectSuccess(second);

      final rows = await api.findRows(
        'InvoiceDetails',
        'invoiceDetailsID',
        invoiceId,
      );
      expect(rows, hasLength(1), reason: 'Replay must not duplicate invoice');
    });

    test('03 EDIT invoice updates same row instead of inserting duplicate',
            () async {
          final result = await api.post(
            'syncInvoiceDetails',
            [invoice(suffix: '-EDITED')],
            transactionId: 'edit_invoice_$runId',
          );
          expectSuccess(result);

          final rows = await api.findRows(
            'InvoiceDetails',
            'invoiceDetailsID',
            invoiceId,
          );
          expect(rows, hasLength(1));
          expect(rows.single['Invoice Number'], 'AUDIT-INV-$runId-EDITED');
        });

    test('04 CREATE three purchases linked to invoice', () async {
      final result = await api.post(
        'syncPurchases',
        [purchase(0), purchase(1), purchase(2)],
        transactionId: 'create_purchases_$runId',
      );
      expectSuccess(result);

      final rows =
      await api.findRows('Purchases', 'invoiceDetailsID', invoiceId);
      expect(rows, hasLength(3));
      expect(rows.map((e) => e['purchases_ID']).toSet(),
          containsAll(purchaseIds.take(3)));
    });

    test('05 purchase values survive POST correctly', () async {
      final rows =
      await api.findRows('Purchases', 'invoiceDetailsID', invoiceId);
      final brutal =
      rows.singleWhere((e) => e['purchases_ID'] == purchaseIds[0]);

      expect(asDouble(brutal['Qty Purchased']), closeTo(10, 0.0001));
      expect(asDouble(brutal['Purchases Bottles']), closeTo(240, 0.0001));
      expect(asDouble(brutal['Cost Per Bottle']), closeTo(14.4792, 0.0001));
      expect(
        asDouble(brutal['Cost of Purchases']),
        closeTo(240 * 14.4792, 0.02),
      );
      expect(dateOnly(brutal['Inv. Date of Purchase']), '2026-09-17');
      expect(dateOnly(brutal['Stock Delivery Date']), '2026-09-17');
    });

    test('06 EDIT one purchase does not duplicate or alter siblings', () async {
      final edited = purchase(
        1,
        name: 'CCORONA - AUDIT EDITED',
        qtyCases: 11,
      );

      final result = await api.post(
        'syncPurchases',
        [edited],
        transactionId: 'edit_purchase_$runId',
      );
      expectSuccess(result);

      final rows =
      await api.findRows('Purchases', 'invoiceDetailsID', invoiceId);
      expect(rows, hasLength(3));

      final p1 = rows.singleWhere((e) => e['purchases_ID'] == purchaseIds[0]);
      final p2 = rows.singleWhere((e) => e['purchases_ID'] == purchaseIds[1]);
      final p3 = rows.singleWhere((e) => e['purchases_ID'] == purchaseIds[2]);

      expect(p1['Purchased Product Name'], 'BRUTAL FRUIT');
      expect(p2['Purchased Product Name'], 'CCORONA - AUDIT EDITED');
      expect(asDouble(p2['Qty Purchased']), closeTo(11, 0.0001));
      expect(p3['Purchased Product Name'], 'DON JULIO');
    });

    test('07 DELETE one purchase leaves invoice and siblings intact', () async {
      final result = await api.post(
        'deletePurchase',
        {'purchases_ID': purchaseIds[1]},
        transactionId: 'delete_purchase_$runId',
      );
      expectSuccess(result);

      final purchases =
      await api.findRows('Purchases', 'invoiceDetailsID', invoiceId);
      expect(purchases, hasLength(2));
      expect(
        purchases.any((e) => e['purchases_ID'] == purchaseIds[1]),
        isFalse,
      );

      final invoices = await api.findRows(
        'InvoiceDetails',
        'invoiceDetailsID',
        invoiceId,
      );
      expect(invoices, hasLength(1));
    });

    test('08 ADD a new purchase after deletion', () async {
      final p4 = {
        ...purchase(0),
        'purchases_ID': purchaseIds[3],
        'Barcode': 'AUDIT_BARCODE_4_$runId',
        'Purchased Product Name': 'DRY LEMON 1LT',
        'purSupplierBottleID': 'AUDIT_PLU_4',
        'Single Unit Volume': 1000.0,
        'Cost Per Bottle': 18.3333,
        'Case/Pack Size': '12.0',
        'Qty Purchased': 4.0,
        'Purchases Bottles': 48.0,
        'Purchase Units': 48.0,
        'Cost of Purchases': 879.9984,
        'Total Stock In Bottles': 48.0,
        'Total Stock In Units': 48.0,
      };

      final result = await api.post(
        'syncPurchases',
        [p4],
        transactionId: 'add_purchase_4_$runId',
      );
      expectSuccess(result);

      final rows =
      await api.findRows('Purchases', 'invoiceDetailsID', invoiceId);
      expect(rows, hasLength(3));
      expect(
        rows.where((e) => e['purchases_ID'] == purchaseIds[3]),
        hasLength(1),
      );
    });

    test('09 DELETE invoice cascades all remaining purchases', () async {
      final result = await api.post(
        'deleteInvoice',
        {'invoiceDetailsID': invoiceId},
        transactionId: 'delete_invoice_$runId',
      );
      expectSuccess(result);

      final invoices = await api.findRows(
        'InvoiceDetails',
        'invoiceDetailsID',
        invoiceId,
      );
      final purchases =
      await api.findRows('Purchases', 'invoiceDetailsID', invoiceId);

      expect(invoices, isEmpty);
      expect(purchases, isEmpty);
    });

    test('10 repeated DELETE is safe and records do not resurrect', () async {
      final result = await api.post(
        'deleteInvoice',
        {'invoiceDetailsID': invoiceId},
        transactionId: 'delete_invoice_retry_$runId',
      );
      expectSuccess(result);

      expect(
        await api.findRows('InvoiceDetails', 'invoiceDetailsID', invoiceId),
        isEmpty,
      );
      expect(
        await api.findRows('Purchases', 'invoiceDetailsID', invoiceId),
        isEmpty,
      );
    });
  });
}

class AppsScriptAuditClient {
  AppsScriptAuditClient({required this.apiUrl, required this.storeId});

  final String apiUrl;
  final String storeId;
  final http.Client _client = http.Client();

  // Match GoogleSheetsService's current transport constants.
  static const int _maxRedirects = 7;
  static const int _timeoutSeconds = 45;

  /// Test transport intentionally mirrors GoogleSheetsService
  /// _executeWithBoundedRedirects rather than using http.post/http.get.
  Future<http.Response> _sendBounded({
    required String method,
    required Uri uri,
    Map<String, String>? headers,
    String? body,
    required String label,
  }) async {
    var current = uri;
    var hop = 0;
    var currentMethod = method.toUpperCase();
    final watch = Stopwatch()..start();
    const budget = Duration(seconds: _timeoutSeconds);
    final trace = <String>[];

    for (;;) {
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) {
        fail('$currentMethod $label timed out; redirects=[${trace.join("; ")}]');
      }

      final request = http.Request(currentMethod, current)
        ..followRedirects = false;

      if (headers != null) request.headers.addAll(headers);

      // Exact production behavior: Content-Type is set here only for POST.
      if (currentMethod == 'POST' && body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = body;
      }

      final response = await (() async {
        final streamed = await _client.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(remaining);

      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          fail(
            '\n════════════════ HTTP FAILURE ════════════════\n'
                'Label: $label\n'
                'Method: $currentMethod\n'
                'Status: ${response.statusCode}\n'
                'URL: $current\n'
                'Headers: ${response.headers}\n'
                'Redirects: [${trace.join("; ")}]\n'
                'BODY:\n${response.body}\n'
                '══════════════════════════════════════════════',
          );
        }
        return response;
      }

      hop++;
      trace.add('${response.statusCode} from ${current.host}');
      if (hop > _maxRedirects) {
        fail(
          'Redirect limit exceeded ($_maxRedirects hops) for $label; '
              'redirects=[${trace.join("; ")}]',
        );
      }

      final location = response.headers['location'];
      if (location == null || location.trim().isEmpty) {
        fail(
          'Redirect has no Location header for $label; '
              'redirects=[${trace.join("; ")}]',
        );
      }

      final next = current.resolve(location);
      if (next.scheme != 'https' && next.scheme != 'http') {
        fail('Unsupported redirect scheme for $label: $next');
      }

      trace.add('to ${next.host}');
      current = next;

      // Exact production redirect semantics:
      // 303 (except HEAD) -> GET
      // 301/302 POST -> GET
      // 307/308 preserve method/body.
      if ((response.statusCode == 303 && currentMethod != 'HEAD') ||
          ((response.statusCode == 301 || response.statusCode == 302) &&
              currentMethod == 'POST')) {
        currentMethod = 'GET';
      }
    }
  }

  Future<Map<String, dynamic>> post(
      String endpoint,
      dynamic data, {
        required String transactionId,
      }) async {
    final payload = jsonEncode({
      'endpoint': endpoint,
      'table': endpoint,
      'storeIdentifier': storeId,
      'data': data,
      'retry': 0,
      'transactionId': transactionId,
      'chunkIndex': 0,
      'chunkTotal': 1,
    });

    final response = await _sendBounded(
      method: 'POST',
      uri: Uri.parse(apiUrl),
      headers: const {'Accept': 'application/json'},
      body: payload,
      label: endpoint,
    );

    final body = response.body.trim();
    if (body.isEmpty) {
      fail('$endpoint returned an empty HTTP ${response.statusCode} response');
    }
    if (body.startsWith('<')) {
      fail('$endpoint returned HTML instead of JSON:\n$body');
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      fail('$endpoint returned non-object JSON: $body');
    }
    final result = Map<String, dynamic>.from(decoded as Map);
    if (result['status'] == 'error' || result['success'] == false) {
      fail('$endpoint server error: $body');
    }
    return result;
  }

  /// Reads every page because an AUDIT_TEST row may be anywhere in the sheet.
  Future<List<Map<String, dynamic>>> fetchTable(String table) async {
    const pageSize = 1000;
    var offset = 0;
    final all = <Map<String, dynamic>>[];

    while (true) {
      final uri = Uri.parse(apiUrl).replace(queryParameters: {
        ...Uri.parse(apiUrl).queryParameters,
        'table': table,
        'storeIdentifier': storeId,
        'offset': '$offset',
        'limit': '$pageSize',
        '_t': '${DateTime.now().microsecondsSinceEpoch}',
      });

      final response = await _sendBounded(
        method: 'GET',
        uri: uri,
        headers: const {
          'Accept': 'application/json',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
        },
        label: '$table offset=$offset',
      );

      final body = response.body.trim();
      if (body.isEmpty) {
        fail('GET $table returned an empty HTTP ${response.statusCode} response');
      }
      if (body.startsWith('<')) {
        fail('GET $table returned HTML instead of JSON:\n$body');
      }

      final decoded = jsonDecode(body);
      if (decoded is List) {
        all.addAll(
          decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
        );
        break;
      }

      if (decoded is! Map) {
        fail('GET $table returned unexpected JSON: $body');
      }

      final map = Map<String, dynamic>.from(decoded as Map);
      if (map['error'] != null ||
          map['status'] == 'error' ||
          map['success'] == false) {
        fail('GET $table failed: $body');
      }

      final data = map['data'];
      if (data is List) {
        all.addAll(
          data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
        );
      } else if (map['total'] == 0 && offset == 0) {
        break;
      } else if (data == null) {
        fail('GET $table returned no data array: $body');
      }

      if (map['hasMore'] != true) break;
      offset += pageSize;
    }

    return all;
  }

  Future<List<Map<String, dynamic>>> findRows(
      String table,
      String key,
      String value,
      ) async {
    final rows = await fetchTable(table);
    return rows
        .where((row) => row[key]?.toString().trim() == value.trim())
        .toList();
  }

  void close() => _client.close();
}

// ---------------------------------------------------------------------------
// Test assertion helpers
// ---------------------------------------------------------------------------
void expectSuccess(Map<String, dynamic> result) {
  expect(result['status'], isNot(equals('error')),
      reason: 'Server returned an error result: $result');
  expect(result['success'], isNot(equals(false)),
      reason: 'Server reported success=false: $result');
}

String dateOnly(dynamic value) {
  if (value == null) return '';
  final text = value.toString().trim();
  if (text.isEmpty) return '';
  final parsed = DateTime.tryParse(text);
  if (parsed != null) {
    final y = parsed.year.toString().padLeft(4, '0');
    final m = parsed.month.toString().padLeft(2, '0');
    final d = parsed.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(text);
  return match == null ? text : '${match.group(1)}-${match.group(2)}-${match.group(3)}';
}

double asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString().trim() ?? '') ?? double.nan;
}
