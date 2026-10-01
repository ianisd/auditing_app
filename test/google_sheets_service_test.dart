import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/services/google_sheets_service.dart';

void main() {
  const masterUrl = 'https://script.google.com/macros/s/TEST_DEPLOYMENT/exec';
  const testStore = 'store_001';

  // ===========================================================================
  // 1. SafeDateUtils Tests
  // ===========================================================================
  group('SafeDateUtils', () {
    test('parseDate handles ISO strings, timestamps, and nulls', () {
      expect(SafeDateUtils.parseDate(null), isNull);
      expect(SafeDateUtils.parseDate('invalid-date'), isNull);

      final date = DateTime.utc(2026, 9, 22, 19, 30);
      expect(SafeDateUtils.parseDate(date), equals(date));
      expect(SafeDateUtils.parseDate('2026-09-22T19:30:00Z'), isNotNull);

      final parsedFromMs = SafeDateUtils.parseDate(date.millisecondsSinceEpoch);
      expect(parsedFromMs?.toUtc(), equals(date));
    });

    test('sortByDate sorts correctly placing nulls last', () {
      final list = [
        {'id': 1, 'date': '2026-09-20'},
        {'id': 2, 'date': null},
        {'id': 3, 'date': '2026-09-10'},
      ];

      SafeDateUtils.sortByDate(
        list,
            (item) => SafeDateUtils.parseDate(item['date']),
      );

      expect(list[0]['id'], 3); // 2026-09-10
      expect(list[1]['id'], 1); // 2026-09-20
      expect(list[2]['id'], 2); // null last
    });

    test('getDateRangeString outputs correct format', () {
      final items = [
        DateTime(2026, 1, 1),
        DateTime(2026, 1, 15),
      ];

      final range = SafeDateUtils.getDateRangeString(
        items,
            (d) => d,
        format: 'yyyy-MM-dd',
      );
      expect(range, '2026-01-01 - 2026-01-15');
    });
  });

  // ===========================================================================
  // 2. HTTP Redirects (GAS Specific 302 -> 200 flow)
  // ===========================================================================
  group('GoogleSheetsService - Redirect Handling', () {
    test('Follows 302 redirect from script.google.com to googleusercontent.com',
            () async {
          int requestCount = 0;
          final service = GoogleSheetsService(
            masterScriptUrl: masterUrl,
            storeIdentifier: testStore,
            clientFactory: () => MockClient((request) async {
              requestCount++;
              if (request.url.host == 'script.google.com') {
                return http.Response(
                  '',
                  302,
                  headers: {
                    'location':
                    'https://script.googleusercontent.com/macros/echo?user=123'
                  },
                );
              } else if (request.url.host == 'script.googleusercontent.com') {
                return http.Response(
                  json.encode({'count': 42}),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('Not Found', 404);
            }),
          );

          final count = await service.getTableRowCount('Inventory');
          expect(count, 42);
          expect(requestCount, 2); // 1 initial + 1 redirected hop
          service.dispose();
        });

    test('Throws Exception if redirect exceeds maxRedirects', () async {
      final service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
        clientFactory: () => MockClient((request) async {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://script.google.com/loop'},
          );
        }),
      );

      await expectLater(
        service.getTableRowCount('Inventory'),
        throwsA(isA<Exception>()),
      );
      service.dispose();
    });
  });

  // ===========================================================================
  // 3. Table Fetching & Pagination
  // ===========================================================================
  group('GoogleSheetsService - Pagination & Batches', () {
    test('fetchTableWithPagination fetches multi-page data sequentially',
            () async {
          final service = GoogleSheetsService(
            masterScriptUrl: masterUrl,
            storeIdentifier: testStore,
            clientFactory: () => MockClient((request) async {
              final uri = request.url;

              if (uri.queryParameters['table'] == '_count') {
                return http.Response(json.encode({'count': 3}), 200);
              }

              final offset = int.parse(uri.queryParameters['offset'] ?? '0');
              if (offset == 0) {
                return http.Response(
                  json.encode({
                    'data': [
                      {'id': 'row_1'},
                      {'id': 'row_2'}
                    ],
                    'total': 3,
                    'hasMore': true,
                    'offset': 0,
                  }),
                  200,
                );
              } else if (offset == 2) {
                return http.Response(
                  json.encode({
                    'data': [
                      {'id': 'row_3'}
                    ],
                    'total': 3,
                    'hasMore': false,
                    'offset': 2,
                  }),
                  200,
                );
              }

              return http.Response('Not Found', 404);
            }),
          );

          final rows = await service.fetchTableWithPagination(
            'Inventory',
            batchSize: 2,
          );

          expect(rows.length, 3);
          expect(rows[0]['id'], 'row_1');
          expect(rows[2]['id'], 'row_3');
          service.dispose();
        });

    test('fetchTableWithPagination handles empty sheet headers gracefully',
            () async {
          final service = GoogleSheetsService(
            masterScriptUrl: masterUrl,
            storeIdentifier: testStore,
            clientFactory: () => MockClient((request) async {
              if (request.url.queryParameters['table'] == '_count') {
                return http.Response(json.encode({'count': 0}), 200);
              }
              return http.Response(
                json.encode({'total': 0, 'offset': 0}),
                200,
              );
            }),
          );

          final rows = await service.fetchTableWithPagination('Inventory');
          expect(rows, isEmpty);
          service.dispose();
        });

    test('fetchBundledTables fetches multiple tables in a single payload',
            () async {
          final service = GoogleSheetsService(
            masterScriptUrl: masterUrl,
            storeIdentifier: testStore,
            clientFactory: () => MockClient((request) async {
              expect(request.url.queryParameters['table'], equals('_bundle'));
              expect(
                request.url.queryParameters['tables'],
                equals('AuditCalendar,StockIssues'),
              );

              // Must return protocol: 1 and errors: {} matching downloadSafeBundle_ in Code.gs
              return http.Response(
                json.encode({
                  'protocol': 1,
                  'success': true,
                  'data': {
                    'AuditCalendar': [
                      {'Audit ID': 'AUD-001'}
                    ],
                    'StockIssues': [
                      {'Issue No': '101', 'Item': 'Vodka'}
                    ],
                  },
                  'errors': {},
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          );

          final bundle = await service.fetchBundledTables(
            ['AuditCalendar', 'StockIssues'],
          );

          expect(bundle['AuditCalendar']?.length, equals(1));
          expect(bundle['AuditCalendar']?[0]['Audit ID'], equals('AUD-001'));
          expect(bundle['StockIssues']?.length, equals(1));
          expect(bundle['StockIssues']?[0]['Item'], equals('Vodka'));

          service.dispose();
        });

  });

  // ===========================================================================
  // 4. Stock Counts Sync (Version 2 Receipt Handling)
  // ===========================================================================
  group('GoogleSheetsService - Stock Counts Sync', () {
    test('syncStockCountsWithChunking succeeds with valid V2 receipts',
            () async {
          final countsToSync = [
            {'id': 'stock_001', 'quantity': 10},
            {'id': 'stock_002', 'quantity': 5},
          ];

          final service = GoogleSheetsService(
            masterScriptUrl: masterUrl,
            storeIdentifier: testStore,
            clientFactory: () => MockClient((request) async {
              final payload = json.decode(request.body);
              expect(payload['endpoint'], 'syncStockCounts');

              return http.Response(
                json.encode({
                  'receiptVersion': 2,
                  'status': 'success',
                  'success': true,
                  'syncedIds': ['stock_001', 'stock_002'],
                  'outcomes': {
                    'stock_001': 'inserted',
                    'stock_002': 'updated',
                  },
                }),
                200,
              );
            }),
          );

          final result = await service.syncStockCountsWithChunking(countsToSync);

          expect(result['success'], isTrue);
          expect(result['count'], 1);
          expect(result['updated'], 1);
          expect(result['syncedIds'], containsAll(['stock_001', 'stock_002']));
          expect(result['failedIds'], isEmpty);
          service.dispose();
        });

    test('syncStockCounts fails if IDs are repeated or missing', () async {
      final service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
      );

      final duplicateCounts = [
        {'id': 'dup_1', 'quantity': 5},
        {'id': 'dup_1', 'quantity': 10},
      ];

      final result = await service.syncStockCountsWithChunking(duplicateCounts);
      expect(result['success'], isFalse);
      expect(result['message'], contains('repeated'));
      service.dispose();
    });

    test('syncStockCounts rejects non-V2 receipts', () async {
      final service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
        clientFactory: () => MockClient((request) async {
          return http.Response(
            json.encode({
              'status': 'success',
              'success': true,
              'count': 1,
            }),
            200,
          );
        }),
      );

      final result = await service.syncStockCountsWithChunking([
        {'id': 'stock_001', 'quantity': 10}
      ]);

      expect(result['success'], isFalse);
      expect(result['message'], contains('version-2 stock acknowledgements'));
      service.dispose();
    });
  });

  // ===========================================================================
  // 5. Circuit Breaker & Retries
  // ===========================================================================
  group('GoogleSheetsService - Circuit Breaker', () {
    test('Trips circuit breaker after consecutive failures and resets cleanly',
            () async {
          int requestCount = 0;
          final service = GoogleSheetsService(
            masterScriptUrl: masterUrl,
            storeIdentifier: testStore,
            clientFactory: () => MockClient((request) async {
              requestCount++;
              if (requestCount <= 5) {
                return http.Response('Server Error', 500);
              }
              return http.Response(json.encode({'status': 'ok'}), 200);
            }),
          );

          for (int i = 0; i < 5; i++) {
            final healthy = await service.checkGASHealth();
            expect(healthy, isFalse);
          }

          service.resetCircuitBreaker();
          final healthyAfterReset = await service.checkGASHealth();
          expect(healthyAfterReset, isTrue);

          service.dispose();
        });
  });

  // ===========================================================================
  // 6. Cancellation Support
  // ===========================================================================
  group('GoogleSheetsService - Cancellation', () {
    test('cancelFetch halts pagination and throws StateError', () async {
      late GoogleSheetsService service;

      service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
        clientFactory: () => MockClient((request) async {
          service.cancelFetch();
          return http.Response(json.encode({'count': 100}), 200);
        }),
      );

      await expectLater(
        service.fetchTableWithPagination('Inventory'),
        throwsA(isA<StateError>().having(
              (e) => e.message,
          'message',
          contains('Download cancelled'),
        )),
      );

      service.dispose();
    });
  });

  // ===========================================================================
  // 7. Client Pool Mechanics (Keep-Alive & Failure Discard)
  // ===========================================================================
  group('GoogleSheetsService - Client Pool Mechanics', () {
    test('Sequential requests reuse the warm pooled client', () async {
      int clientsCreated = 0;

      final service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
        clientFactory: () {
          clientsCreated++;
          return MockClient((request) async {
            return http.Response(json.encode({'count': 1}), 200);
          });
        },
      );

      // Two sequential requests
      await service.getTableRowCount('Inventory');
      await service.getTableRowCount('Inventory');

      // Reused the same client instance without re-instantiating
      expect(clientsCreated, equals(1));
      service.dispose();
    });

    test('Transport failure discards client and leases a fresh one', () async {
      int clientsCreated = 0;
      bool failNext = true;

      final service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
        clientFactory: () {
          clientsCreated++;
          return MockClient((request) async {
            if (failNext) {
              failNext = false;
              throw http.ClientException('Connection reset by peer');
            }
            return http.Response(json.encode({'count': 10}), 200);
          });
        },
      );

      // First call fails with ClientException
      try {
        await service.getTableRowCount('Inventory');
      } catch (_) {}

      // Second call succeeds
      final count = await service.getTableRowCount('Inventory');
      expect(count, equals(10));
      // First client was discarded, so a second was instantiated
      expect(clientsCreated, equals(2));

      service.dispose();
    });

    test('Client creation failure releases the semaphore permit', () async {
      bool shouldThrow = true;

      final service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
        clientFactory: () {
          if (shouldThrow) {
            throw StateError('OS out of file descriptors');
          }
          return MockClient((request) async {
            return http.Response(json.encode({'count': 5}), 200);
          });
        },
      );

      // First attempt crashes during client leasing
      await expectLater(
        service.getTableRowCount('Inventory'),
        throwsA(isA<StateError>()),
      );

      // Recover factory
      shouldThrow = false;

      // Next attempt must acquire the permit without deadlocking
      final count = await service.getTableRowCount('Inventory');
      expect(count, equals(5));

      service.dispose();
    });

    test('Simultaneous requests are serialized by semaphore and reuse the warm client', () async {
      int totalCreated = 0;

      final service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
        clientFactory: () {
          totalCreated++;
          return MockClient((request) async {
            await Future.delayed(const Duration(milliseconds: 20));
            return http.Response(json.encode({'count': 1}), 200);
          });
        },
      );

      // Launch two requests simultaneously
      await Future.wait([
        service.getTableRowCount('Inventory'),
        service.getTableRowCount('Inventory'),
      ]);

      // Under _Semaphore(1), the second request waits and reuses the warm client from the pool
      expect(totalCreated, equals(1));

      service.dispose();
    });

  });

  // ===========================================================================
  // 8. Server ID Validation (Base62 & UUID support)
  // ===========================================================================
  group('GoogleSheetsService - Server ID Validation', () {
    test('isValidServerId accepts GAS Base62 IDs, 32-char hex, and UUIDs', () {
      final service = GoogleSheetsService(
        masterScriptUrl: masterUrl,
        storeIdentifier: testStore,
      );

      // GAS Base62 IDs (generated by generateShortId())
      expect(service.isValidServerId('T7xK2p9Q'), isTrue);
      expect(service.isValidServerId('aB3dE8zY'), isTrue);
      expect(service.isValidServerId('01234567'), isTrue);

      // 32-char hex IDs
      expect(
        service.isValidServerId('4a8b1c2d3e4f5a6b7c8d9e0f1a2b3c4d'),
        isTrue,
      );

      // Standard UUID format
      expect(
        service.isValidServerId('123e4567-e89b-12d3-a456-426614174000'),
        isTrue,
      );

      // Invalid IDs
      expect(service.isValidServerId(''), isFalse);
      expect(service.isValidServerId('short'), isFalse); // Less than 8 chars
      expect(service.isValidServerId('has spaces'), isFalse);
      expect(service.isValidServerId('has!special#char'), isFalse);

      service.dispose();
    });
  });
  // ===========================================================================
  // 9. Date Formatting & ID Idempotency Tests
  // ===========================================================================
  group('GoogleSheetsService - Dates & ID Idempotency', () {
    test('SafeDateUtils parses dd/MM/yyyy and ISO strings accurately', () {
      final date1 = SafeDateUtils.parseDate('25/12/2026');
      expect(date1?.year, equals(2026));
      expect(date1?.month, equals(12));
      expect(date1?.day, equals(25));

      final date2 = SafeDateUtils.parseDate('2026-05-06');
      expect(date2?.year, equals(2026));
      expect(date2?.month, equals(5));
      expect(date2?.day, equals(6));
    });

    test('syncInvoiceDetails preserves generated IDs on source items across retries',
            () async {
          final invoices = [
            {
              'Invoice Number': 'INV-1001',
              'Date of Purchase': '25/12/2026',
            }
          ];

          final service = GoogleSheetsService(
            masterScriptUrl: masterUrl,
            storeIdentifier: testStore,
            clientFactory: () => MockClient((request) async {
              final payload = json.decode(request.body);
              final rows = payload['data'] as List;
              // Verify calendar date was converted from dd/MM/yyyy to yyyy-MM-dd
              expect(rows[0]['Date of Purchase'], equals('2026-12-25'));
              return http.Response(
                json.encode({'status': 'success', 'success': true}),
                200,
              );
            }),
          );

          await service.syncInvoiceDetails(invoices);

          // Verify ID was generated and written back to the source map
          final firstGeneratedId = invoices[0]['invoiceDetailsID'];
          expect(firstGeneratedId, isNotNull);
          expect(service.isValidServerId(firstGeneratedId.toString()), isTrue);

          // Second sync must keep the EXACT same ID (idempotent retry)
          await service.syncInvoiceDetails(invoices);
          expect(invoices[0]['invoiceDetailsID'], equals(firstGeneratedId));

          service.dispose();
        });

    test('syncPurchases preserves generated IDs on source items across retries',
            () async {
          final purchases = [
            {
              'Purchased Product Name': 'Whiskey',
              'Date': '05/06/2026',
            }
          ];

          final service = GoogleSheetsService(
            masterScriptUrl: masterUrl,
            storeIdentifier: testStore,
            clientFactory: () => MockClient((request) async {
              final payload = json.decode(request.body);
              final rows = payload['data'] as List;
              // Verify calendar date is formatted to yyyy-MM-dd
              expect(rows[0]['Date'], equals('2026-06-05'));
              return http.Response(
                json.encode({'status': 'success', 'success': true}),
                200,
              );
            }),
          );

          await service.syncPurchases(purchases);

          final firstGeneratedId = purchases[0]['purchases_ID'];
          expect(firstGeneratedId, isNotNull);
          expect(service.isValidServerId(firstGeneratedId.toString()), isTrue);

          // Second sync must keep the EXACT same ID
          await service.syncPurchases(purchases);
          expect(purchases[0]['purchases_ID'], equals(firstGeneratedId));

          service.dispose();
        });
  });
}

