// ADAPTIVE FLUTTER POST UNIT TESTS
// Place this file at: <your Flutter project>/test/post_operations_test.dart
// Run: flutter test test/post_operations_test.dart --reporter expanded
// Required dev dependency in pubspec.yaml:
// dev_dependencies:
//   flutter_test:
//     sdk: flutter
// Uses your existing http dependency; no Mockito or code generation needed.
// Assumes the app service is lib/services/google_sheets_service.dart.
// Based on the Drive service snapshot modified 2026-09-25 07:54 UTC.
// That version already has clientFactory; production changes are not needed.
//
// These tests execute the REAL Flutter service with mocked HTTP responses.
// They check outgoing payloads, receipts, error handling, retries and chunking.
// They DO NOT execute code.gs, mutate Google Sheets, or verify offline queues.
// A passing mocked response does not prove a deployed server deleted a row.
// REGRESSION tests assert desired behavior and may fail on the current service.
// Not executed by the author: Flutter/Dart SDK unavailable in authoring runtime.
// References: https://docs.flutter.dev/testing/overview
// https://pub.dev/documentation/http/latest/testing/MockClient-class.html

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/services/google_sheets_service.dart';

const _store = 'TEST_STORE_123456789012345678901';
const _url = 'https://example.invalid/macros/s/TEST/exec';

typedef _Reply = Future<http.Response> Function(http.Request request);

class _Fixture {
  final requests = <http.Request>[];
  late final GoogleSheetsService service;

  _Fixture(_Reply reply) {
    service = GoogleSheetsService(
      masterScriptUrl: _url,
      storeIdentifier: _store,
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return reply(request);
      }),
    );
  }

  List<Map<String, dynamic>> get posts => requests
      .where((r) => r.method == 'POST')
      .map((r) => Map<String, dynamic>.from(jsonDecode(r.body) as Map))
      .toList();
}

http.Response _json(Map<String, dynamic> body, {int status = 200}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _body(http.Request request) =>
    Map<String, dynamic>.from(jsonDecode(request.body) as Map);

Map<String, dynamic> _invoice() => {
  'invoiceDetailsID': 'INV00001',
  'Invoice Number': '000123',
  'GRV Reference': 'GRV00001',
  'supplierID': 'SUP00001',
  'Supplier Name': 'Test Supplier',
  'Date of Purchase': '2026-09-25',
  'Delivery Date': '2026-09-25',
  'Total Cost Ex Vat': 200,
  'Total Cost Inc Vat': 230,
};

Map<String, dynamic> _purchase() => {
  'purchases_ID': 'PUR00001',
  'invoiceDetailsID': 'INV00001',
  'Invoice Nr.': '000123',
  'GRV Reference': 'GRV00001',
  'Barcode': '600000000001',
  'Purchased Product Name': 'Test Gin',
  'Date': '2026-09-25',
  'Cost Per Bottle': 100,
  'Purchases Bottles': 2,
  'Qty Purchased': 2,
  'Cost of Purchases': 200,
};

Map<String, dynamic> _count(String id) => {
  'id': id,
  'date': '2026-09-25',
  'productName': 'Test Gin',
  'barcode': '600000000001',
  'location': 'Main Bar',
  'count': 2,
  'total_bottles': 2,
  'singleUnitVolume': 750,
};

http.Response _stockReceipt(http.Request request, String outcome) {
  final data = _body(request)['data'] as List;
  final ids = data.map((r) => (r as Map)['id'] as String).toList();
  return _json({
    'status': 'success',
    'success': true,
    'receiptVersion': 2,
    'syncedIds': ids,
    'outcomes': {for (final id in ids) id: outcome},
  });
}

void main() {
  // Plain unit tests: no widget binding, Firebase initialization, or real HTTP.
  _Fixture make(_Reply reply) {
    final f = _Fixture(reply);
    addTearDown(f.service.dispose);
    return f;
  }

  _Fixture success() => make((_) async => _json({'status': 'success'}));

  group('Purchases', () {
    test('add sends mapped purchase and correct store', () async {
      final f = success();
      expect(await f.service.syncPurchases([_purchase()]), isTrue);
      final post = f.posts.single;
      expect(post['endpoint'], 'syncPurchases');
      expect(post['storeIdentifier'], _store);
      final row = (post['data'] as List).single as Map;
      expect(row['purchases_ID'], 'PUR00001');
      expect(row['invoiceDetailsID'], 'INV00001');
      expect(row['syncStatus'], 'synced');
      expect(row['Purchases Bottles'], 2);
      expect(f.requests.single.headers['content-type'], contains('application/json'));
    });

    test('generated purchase ID survives a second submission', () async {
      final f = success();
      final row = _purchase()..remove('purchases_ID');
      expect(await f.service.syncPurchases([row]), isTrue);
      final id = row['purchases_ID'];
      expect(id, isA<String>());
      expect((id as String).isNotEmpty, isTrue);
      expect(await f.service.syncPurchases([row]), isTrue);
      expect((f.posts.last['data'] as List).single['purchases_ID'], id);
    });

    test('edit retains ID, invoice link and changed quantity', () async {
      final f = success();
      final row = _purchase()..['Purchases Bottles'] = 5;
      expect(await f.service.updatePurchase(row), isTrue);
      expect(f.posts.single['endpoint'], 'updatePurchase');
      expect(f.posts.single['data'], row);
    });

    test('negative credit-note quantity is not converted to positive', () async {
      final f = success();
      final row = _purchase()..['Purchases Bottles'] = -2;
      expect(await f.service.syncPurchases([row]), isTrue);
      expect((f.posts.single['data'] as List).single['Purchases Bottles'], -2);
    });

    test('single delete sends purchaseId, not invoiceId', () async {
      final f = success();
      expect(await f.service.deletePurchase('PUR00001'), isTrue);
      expect(f.posts.single['endpoint'], 'deletePurchase');
      expect(f.posts.single['storeIdentifier'], _store);
      expect(f.posts.single['data'], {'purchaseId': 'PUR00001'});
    });

    test('batch delete sends purchaseIds array', () async {
      final f = success();
      expect(await f.service.deletePurchases(['PUR00001', 'PUR00002']), isTrue);
      expect(f.posts.single['endpoint'], 'deletePurchases');
      expect(f.posts.single['data'], {'purchaseIds': ['PUR00001', 'PUR00002']});
    });

    test('empty delete list makes no HTTP request', () async {
      final f = success();
      expect(await f.service.deletePurchases([]), isTrue);
      expect(f.requests, isEmpty);
    });

    for (final size in [100, 101, 205]) {
      test('$size deletes preserve every ID and chunk at 100', () async {
        final f = success();
        final ids = List.generate(size, (i) => 'PUR${i.toString().padLeft(5, '0')}');
        expect(await f.service.deletePurchases(ids), isTrue);
        final chunks = f.posts
            .map((p) => (p['data'] as Map)['purchaseIds'] as List)
            .toList();
        expect(chunks.length, (size / 100).ceil());
        expect(chunks.every((c) => c.length <= 100), isTrue);
        expect(chunks.expand((c) => c).toList(), ids);
        expect(f.posts.every((p) => p['storeIdentifier'] == _store), isTrue);
      });
    }

    test('one failed deletion chunk makes whole operation fail', () async {
      var calls = 0;
      final f = make((_) async {
        calls++;
        return _json(calls == 2
            ? {'status': 'error', 'message': 'Injected delete failure'}
            : {'status': 'success'});
      });
      expect(await f.service.deletePurchases(List.generate(205, (i) => 'PUR$i')), isFalse);
      expect(f.posts.length, 3);
    });

    test('already absent IDs are accepted as idempotent success', () async {
      final f = make((_) async => _json({
        'status': 'success', 'deletedCount': 0, 'notFoundCount': 1,
      }));
      expect(await f.service.deletePurchases(['ABSENT01']), isTrue);
    });

    test('REGRESSION: deletion errorCount must not be reported as success', () async {
      final f = make((_) async => _json({
        'status': 'success',
        'deletedCount': 1,
        'errorCount': 1,
        'errors': ['Second row was not deleted'],
      }));
      expect(await f.service.deletePurchases(['PUR00001', 'PUR00002']), isFalse,
          reason: 'A batch with a failed deletion cannot confirm the entire operation.');
    });
  });

  group('Invoices', () {
    test('add preserves leading-zero invoice number and link ID', () async {
      final f = success();
      expect(await f.service.syncInvoiceDetails([_invoice()]), isTrue);
      expect(f.posts.single['endpoint'], 'syncInvoiceDetails');
      final row = (f.posts.single['data'] as List).single as Map;
      expect(row['Invoice Number'], '000123');
      expect(row['invoiceDetailsID'], 'INV00001');
      expect(row['syncStatus'], 'synced');
    });

    test('generated invoice ID is stable across submissions', () async {
      final f = success();
      final invoice = _invoice()..remove('invoiceDetailsID');
      expect(await f.service.syncInvoiceDetails([invoice]), isTrue);
      final id = invoice['invoiceDetailsID'];
      expect(id, isA<String>());
      expect((id as String).isNotEmpty, isTrue);
      expect(await f.service.syncInvoiceDetails([invoice]), isTrue);
      expect((f.posts.last['data'] as List).single['invoiceDetailsID'], id);
    });

    test('edit uses updateInvoice and preserves invoice ID', () async {
      final f = success();
      final row = _invoice()..['Delivery Date'] = '2026-09-26';
      expect(await f.service.updateInvoice(row), isTrue);
      expect(f.posts.single['endpoint'], 'updateInvoice');
      final data = f.posts.single['data'] as Map;
      expect(data['invoiceDetailsID'], 'INV00001');
      expect(data['Delivery Date'], '2026-09-26');
    });

    test('delete sends invoiceId', () async {
      final f = success();
      expect(await f.service.deleteInvoice('INV00001'), isTrue);
      expect(f.posts.single['endpoint'], 'deleteInvoice');
      expect(f.posts.single['data'], {'invoiceId': 'INV00001'});
    });

    test('multiple invoice deletions preserve each ID', () async {
      final f = success();
      expect(await f.service.deleteInvoices(['INV00001', 'INV00002']), isTrue);
      expect(f.posts.map((p) => (p['data'] as Map)['invoiceId']).toList(),
          ['INV00001', 'INV00002']);
    });

    test('invoice deletion failure propagates', () async {
      final f = make((_) async => _json({'status': 'error', 'message': 'Delete failed'}));
      expect(await f.service.deleteInvoice('INV00001'), isFalse);
    });
  });

  group('Stock counts', () {
    for (final outcome in ['inserted', 'updated', 'deleted']) {
      test('$outcome maps payload and honours per-ID receipt', () async {
        final f = make((r) async => _stockReceipt(r, outcome));
        final row = _count('COUNT001');
        if (outcome == 'updated') row['count'] = 0;
        if (outcome == 'deleted') row['syncStatus'] = 'deleted';
        final result = await f.service.syncStockCountsWithChunking([row]);
        expect(result['success'], isTrue);
        expect(result['syncedIds'], ['COUNT001']);
        final post = f.posts.single;
        expect(post['endpoint'], 'syncStockCounts');
        expect(post['storeIdentifier'], _store);
        expect(post['transactionId'], isNotEmpty);
        expect(post['chunkIndex'], 0);
        final sent = (post['data'] as List).single as Map;
        expect(sent['id'], 'COUNT001');
        expect(sent['stock_id'], 'COUNT001');
        expect(sent['deleted'], outcome == 'deleted');
        if (outcome == 'updated') expect(sent['count'], 0);
        final key = outcome == 'inserted' ? 'count' : outcome;
        expect(result[key], 1);
      });
    }

    test('boolean convenience method accepts version-2 acknowledgement', () async {
      final f = make((r) async => _stockReceipt(r, 'inserted'));
      expect(await f.service.syncStockCounts([_count('COUNT001')]), isTrue);
    });

    test('aggregate success without per-ID receipt is not confirmation', () async {
      final f = success();
      final r = await f.service.syncStockCountsWithChunking([_count('COUNT001')]);
      expect(r['success'], isFalse);
      expect(r['failedIds'], ['COUNT001']);
      expect(f.posts.length, 1);
    });

    test('receipt containing an unexpected ID is rejected', () async {
      final f = make((_) async => _json({
        'status': 'success', 'success': true,
        'receiptVersion': 2, 'syncedIds': ['NOT_SENT'],
      }));
      final r = await f.service.syncStockCountsWithChunking([_count('COUNT001')]);
      expect(r['success'], isFalse);
      expect(r['syncedIds'], isEmpty);
    });

    test('partial receipt retains confirmed IDs without claiming full success', () async {
      final f = make((_) async => _json({
        'status': 'error', 'success': false, 'receiptVersion': 2,
        'syncedIds': ['COUNT001'], 'code': 'INVALID_INPUT',
        'outcomes': {'COUNT001': 'inserted'},
      }));
      final r = await f.service.syncStockCountsWithChunking([
        _count('COUNT001'), _count('COUNT002'),
      ]);
      expect(r['success'], isFalse);
      expect(r['syncedIds'], ['COUNT001']);
      expect(r['failedIds'], ['COUNT002']);
      expect(f.posts.length, 1);
    });

    test('duplicate count IDs rejected before HTTP', () async {
      final f = success();
      expect(await f.service.syncStockCounts([_count('COUNT001'), _count('COUNT001')]), isFalse);
      expect(f.requests, isEmpty);
    });

    test('missing count ID rejected before HTTP', () async {
      final f = success();
      expect(await f.service.syncStockCounts([_count('')]), isFalse);
      expect(f.requests, isEmpty);
    });

    test('401 counts split into 200, 200, 1 with one transaction', () async {
      final f = make((r) async => _stockReceipt(r, 'inserted'));
      final rows = List.generate(401, (i) => _count('COUNT$i'));
      final r = await f.service.syncStockCountsWithChunking(rows);
      expect(r['success'], isTrue);
      expect((r['syncedIds'] as List).length, 401);
      expect(f.posts.map((p) => (p['data'] as List).length).toList(), [200, 200, 1]);
      expect(f.posts.map((p) => p['chunkIndex']).toList(), [0, 1, 2]);
      expect(f.posts.map((p) => p['transactionId']).toSet().length, 1);
    });
  });

  group('Error responses and transport', () {
    for (final response in <Map<String, dynamic>>[
      {'status': 'error', 'message': 'Failure'},
      {'status': 'partial_success', 'deletedCount': 1},
      {'status': 'success', 'success': false},
    ]) {
      test('purchase deletion rejects ${jsonEncode(response)}', () async {
        final f = make((_) async => _json(response));
        expect(await f.service.deletePurchase('PUR00001'), isFalse);
      });
    }

    for (final body in ['<HTML>Sign in</HTML>', '{invalid json', '[]']) {
      test('purchase deletion rejects non-object/invalid response $body', () async {
        final f = make((_) async => http.Response(body, 200));
        expect(await f.service.deletePurchase('PUR00001'), isFalse);
      });
    }

    test('HTTP 403 does not mark deletion successful', () async {
      final f = make((_) async => http.Response('Forbidden', 403));
      expect(await f.service.deletePurchases(['PUR00001']), isFalse);
      expect(f.posts.length, 1);
    });

    test('HTTP 500 then success retries identical deletion payload', () async {
      var calls = 0;
      final f = make((_) async {
        calls++;
        return calls == 1
            ? http.Response('Temporary failure', 500)
            : _json({'status': 'success'});
      });
      expect(await f.service.deletePurchase('PUR00001'), isTrue);
      expect(f.posts.length, 2);
      expect(f.posts.first, f.posts.last);
    });

    test('302 response follows GET without resending deletion body', () async {
      final f = make((r) async => r.method == 'POST'
          ? http.Response('', 302, headers: {'location': 'https://example.invalid/result'})
          : _json({'status': 'success'}));
      expect(await f.service.deletePurchase('PUR00001'), isTrue);
      expect(f.requests.map((r) => r.method).toList(), ['POST', 'GET']);
      expect(f.requests.last.body, isEmpty);
      expect(f.posts.length, 1);
    });
  });
}
