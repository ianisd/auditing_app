import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support.dart';

// A deterministic server model. Passing this suite does not validate live GAS.
class MemoryServer {
  final rows = <String, Row>{};
  final requests = <Row>[];
  http.Client client(LocalProbe probe) => MockClient((request) async {
    check(probe.connectivity.online, 'Transport called while offline');
    check(request.method == 'POST', 'Unexpected HTTP method');
    final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
    check(
      body['storeIdentifier'] == sampleStore &&
          body['endpoint'] == 'syncStockCounts',
      'Wrong route',
    );
    requests.add(body);
    probe.log('mock_request', body);
    final outcomes = <String, String>{};
    for (final item in body['data'] as List) {
      final row = Map<String, dynamic>.from(item as Map);
      final id = rowId(row);
      if (row['deleted'] == true || row['syncStatus'] == 'deleted') {
        outcomes[id] = rows.remove(id) == null ? 'already_absent' : 'deleted';
      } else {
        outcomes[id] = rows.containsKey(id) ? 'updated' : 'inserted';
        rows[id] = row;
      }
    }
    return http.Response(
      jsonEncode({
        'status': 'success',
        'success': true,
        'receiptVersion': 2,
        'syncedIds': outcomes.keys.toList(),
        'failedIds': [],
        'outcomes': outcomes,
      }),
      200,
    );
  });
  Future<List<Row>> read(String id) async =>
      rows.containsKey(id) ? [Map<String, dynamic>.from(rows[id]!)] : [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late LocalProbe probe;
  late MemoryServer server;
  ProbeSheets sheets() => ProbeSheets(
    log: probe.log,
    ownedIds: probe.ownedIds,
    clientFactory: () => server.client(probe),
  );
  Future<void> upload() async {
    probe.connectivity.online = true;
    expect((await probe.sync(sheets())).success, isTrue);
  }

  setUp(() async {
    final run = Directory(
      'test-results/post-restart/unit-${DateTime.now().microsecondsSinceEpoch}',
    );
    probe = LocalProbe(run, 'unit');
    server = MemoryServer();
    await probe.open();
    // Intentionally retain each isolated Hive directory and log for diagnosis.
    print('POST restart evidence: ${run.absolute.path}');
  });
  tearDown(() async {
    await probe.close();
  });

  test(
    'pending app-generated count survives clean reopen, sync and synced reopen',
    () async {
      final id = await probe.create();
      expect((await probe.sync(sheets())).success, isFalse);
      expect(server.requests, isEmpty);
      await probe.reopen();
      await probe.verifyLocal(id, 2, 'pending');
      await upload();
      await verifyRemote(probe, id, 2, server.read);
      await probe.reopen();
      await probe.verifyLocal(id, 2, 'synced');
      expect(probe.storage.pendingCounts, isEmpty);
    },
  );

  test(
    'offline edit and tombstone survive reopen; deletion stays absent after refresh',
    () async {
      final id = await probe.create();
      await upload();
      probe.connectivity.online = false;
      await probe.edit(id, 3);
      await probe.reopen();
      await probe.verifyLocal(id, 3, 'pending');
      await upload();
      await verifyRemote(probe, id, 3, server.read);
      probe.connectivity.online = false;
      await probe.storage.deleteStockCount(id);
      await probe.reopen();
      await probe.verifyLocal(id, 3, 'deleted');
      await upload();
      await verifyRemote(probe, id, null, server.read);
      await probe.storage.saveRemoteStockCounts(await server.read(id));
      await probe.deletedLocally(id);
      await probe.reopen();
      await probe.deletedLocally(id);
    },
  );

  test(
    'held successful reply cannot acknowledge the newer quantity 3',
    () async {
      final id = await probe.create();
      probe.connectivity.online = true;
      final google = sheets();
      google.afterCommit = (submitted, result) async {
        expect(quantity(submitted.single), 2);
        await verifyRemote(probe, id, 2, server.read);
        await probe.edit(id, 3);
        // Returning releases the old result to the actual SyncService.
      };
      final old = await probe.sync(google);
      expect(old.success, isFalse);
      expect(old.stockCountsSynced, 0);
      await probe.verifyLocal(id, 3, 'pending');
      await upload();
      await verifyRemote(probe, id, 3, server.read);
      await probe.verifyLocal(id, 3, 'synced');
      expect(server.rows.length, 1);
    },
  );

  test(
    'deletion during held upload remains queued until its own receipt',
    () async {
      final id = await probe.create();
      probe.connectivity.online = true;
      final google = sheets();
      google.afterCommit = (_, result) async {
        await probe.storage.deleteStockCount(id);
      };
      expect((await probe.sync(google)).success, isFalse);
      await probe.verifyLocal(id, 2, 'deleted');
      await probe.reopen();
      await upload();
      await verifyRemote(probe, id, null, server.read);
      await probe.deletedLocally(id);
    },
  );

  test(
    'committed but unacknowledged write survives clean reopen and reconciles latest edit',
    () async {
      final id = await probe.create();
      probe.connectivity.online = true;
      final google = sheets();
      google.afterCommit = (_, result) async {
        await verifyRemote(probe, id, 2, server.read);
        throw StateError(
          'Injected loss of completion before local acknowledgement',
        );
      };
      expect((await probe.sync(google)).success, isFalse);
      await probe.verifyLocal(id, 2, 'pending');
      await probe.reopen();
      await probe.verifyLocal(id, 2, 'pending');
      await upload();
      await verifyRemote(probe, id, 2, server.read);
      expect(server.rows.length, 1);
      expect(
        server.requests[0]['transactionId'],
        isNot(server.requests[1]['transactionId']),
      );
      await probe.edit(id, 3);
      await upload();
      await verifyRemote(probe, id, 3, server.read);
      await probe.verifyLocal(id, 3, 'synced');
    },
  );
}
