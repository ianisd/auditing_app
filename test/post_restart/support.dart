import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import '../../lib/services/offline_storage.dart';
import '../../lib/services/google_sheets_service.dart';
import '../../lib/services/sync_service.dart';

const sampleStore = '1c9O_bUJ9wjg-hfgBJH5oLzElV5-YABpFWg_C2NcuCjU';
const deployment =
    'https://script.google.com/macros/s/AKfycbwDig4I_CWjbZTASOn40nhRfaAkfoCjCgqYjOT-i3EkiB-ac8LnqefXHTrVolCkzso/exec';
typedef Row = Map<String, dynamic>;
void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

String rowId(Row row) =>
    '${row['id'] ?? row['stock_id'] ?? row['stockTake_ID'] ?? ''}';
num quantity(Row row) => num.parse('${row['count'] ?? row['Count']}');

class ProbeConnectivity implements Connectivity {
  bool online = false;
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    online ? ConnectivityResult.wifi : ConnectivityResult.none,
  ];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Holds the service result before the real coordinator acknowledges its snapshot.
// No production function is replaced. This is NOT a network-packet proxy.
class ProbeSheets extends GoogleSheetsService {
  Future<void> Function(List<Row>, Row)? afterCommit;
  final void Function(String, Row) log;
  final Set<String> ownedIds;
  ProbeSheets({
    required this.log,
    required this.ownedIds,
    http.Client Function()? clientFactory,
  }) : super(
         masterScriptUrl: deployment,
         storeIdentifier: sampleStore,
         clientFactory: clientFactory,
       );
  @override
  Future<Row> syncStockCountsWithChunking(
    List<Row> counts, {
    Function(int processed, int total)? onProgress,
    int chunkSize = 200,
  }) async {
    check(
      counts.every((r) => ownedIds.contains(rowId(r))),
      'Refusing an unowned record',
    );
    log('submitted', {'rows': counts});
    final result = await super.syncStockCountsWithChunking(
      counts,
      onProgress: onProgress,
      chunkSize: chunkSize,
    );
    log('service_receipt', result);
    final hook = afterCommit;
    if (hook != null && result['success'] == true) {
      afterCommit = null;
      await hook(counts, result);
    }
    return result;
  }
}

class LocalProbe {
  final Directory root;
  final String stage;
  late OfflineStorage storage;
  final connectivity = ProbeConnectivity();
  final ownedIds = <String>{};
  LocalProbe(this.root, this.stage);
  void log(String event, Row data) {
    File('${root.path}/events.jsonl').writeAsStringSync(
      '${jsonEncode({'utc': DateTime.now().toUtc().toIso8601String(), 'pid': pid, 'stage': stage, 'event': event, ...data})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> open() async {
    await root.create(recursive: true);
    final hiveDir = Directory('${root.path}/hive');
    await hiveDir.create(recursive: true);
    Hive.init(hiveDir.path);
    storage = OfflineStorage();
    await storage.switchStore(sampleStore);
    final file = File('${root.path}/owned-ids.json');
    if (await file.exists())
      ownedIds.addAll(
        (jsonDecode(await file.readAsString()) as List).cast<String>(),
      );
  }

  void remember(String id) {
    check(id.startsWith('stock_'), 'Expected app-generated stock ID');
    check(
      id != 'codex_post_verify_20260927_6b20ce91',
      'Old test ID must not be reused',
    );
    ownedIds.add(id);
    File(
      '${root.path}/owned-ids.json',
    ).writeAsStringSync(jsonEncode(ownedIds.toList()), flush: true);
  }

  Future<String> create() async {
    // Deliberately omit id and stock_id: production OfflineStorage generates them.
    final row = <String, dynamic>{
      'date': DateTime.now().toIso8601String().split('T').first,
      'productName': 'POST restart probe',
      'location': 'POST test',
      'barcode': '',
      'singleUnitVolume': 750,
      'count': 2,
      'total_bottles': 2,
      'total_ml': 1500,
    };
    await storage.saveStockCount(row);
    final id = rowId(row);
    remember(id);
    await verifyLocal(id, 2, 'pending');
    return id;
  }

  Future<Row> local(String id) async {
    final rows = [
      ...await storage.getStockCounts(),
      ...storage.pendingCounts.where((r) => r['syncStatus'] == 'deleted'),
    ];
    final found = rows.where((r) => rowId(r) == id).toList();
    check(found.length == 1, 'Expected one local $id, got ${found.length}');
    return Map<String, dynamic>.from(found.single);
  }

  Future<void> verifyLocal(String id, num count, String status) async {
    final row = await local(id);
    log('local', {
      'id': id,
      'quantity': quantity(row),
      'status': row['syncStatus'],
    });
    check(
      quantity(row) == count && row['syncStatus'] == status,
      'Local $id expected $count/$status: $row',
    );
  }

  Future<void> edit(String id, num count) async {
    final row = await local(id);
    row.addAll({
      'count': count,
      'total_bottles': count,
      'total_ml': count * 750,
    });
    await storage.updateStockCount(row);
    await verifyLocal(id, count, 'pending');
  }

  Future<void> deletedLocally(String id) async {
    check(
      !(await storage.getStockCounts()).any((r) => rowId(r) == id),
      'Deleted row remains visible',
    );
    check(
      !storage.pendingCounts.any((r) => rowId(r) == id),
      'Deletion is still pending',
    );
    log('local_absent', {'id': id});
  }

  Future<SyncResult> sync(ProbeSheets sheets) async {
    final service = SyncService(
      offlineStorage: storage,
      googleSheets: sheets,
      connectivity: connectivity,
    );
    try {
      final result = await service.syncAll();
      log('sync_result', {
        'success': result.success,
        'synced': result.syncedCount,
        'message': result.message,
      });
      return result;
    } finally {
      service.dispose();
    }
  }

  Future<void> close() async {
    await Hive.close();
    storage.dispose();
    // Let dispose's unawaited box-close task finish before the next instance.
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> reopen() async {
    await close();
    await open();
  }
}

// Fresh GET, independent of the POST result and of all local storage/service caches.
// It uses the deployed serializer, not the authenticated Google Sheets API.
Future<List<Row>> liveRows(String id) async {
  final matches = <Row>[];
  int offset = 0;
  int? expectedTotal;
  final client = http.Client();
  try {
    for (var page = 0; page < 200; page++) {
      final uri = Uri.parse(deployment).replace(
        queryParameters: {
          'table': 'StockCounts',
          'storeIdentifier': sampleStore,
          'offset': '$offset',
          'limit': '500',
          '_t': '${DateTime.now().microsecondsSinceEpoch}',
        },
      );
      final response = await client
          .get(uri)
          .timeout(const Duration(seconds: 90));
      check(
        response.statusCode == 200,
        'Read-back HTTP ${response.statusCode}',
      );
      final value = jsonDecode(response.body);
      check(
        value is Map &&
            value['data'] is List &&
            value['total'] is num &&
            value['hasMore'] is bool,
        'Read-back pagination contract missing',
      );
      final map = value as Map;
      final total = (map['total'] as num).toInt();
      expectedTotal ??= total;
      check(
        total == expectedTotal,
        'Store changed during read-back; rerun at a quiet time',
      );
      if (map.containsKey('offset'))
        check(map['offset'] == offset, 'Wrong page offset');
      final rows = (map['data'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      matches.addAll(rows.where((r) => rowId(r) == id));
      offset += rows.length;
      if (map['hasMore'] == false) {
        check(offset == total, 'Incomplete read-back ($offset/$total)');
        return matches;
      }
      check(rows.isNotEmpty && offset < total, 'Invalid read-back progress');
    }
    throw StateError('Read-back page limit reached');
  } finally {
    client.close();
  }
}

Future<void> verifyRemote(
  LocalProbe probe,
  String id,
  num? expected,
  Future<List<Row>> Function(String) read,
) async {
  final rows = await read(id);
  probe.log('independent_readback', {
    'id': id,
    'expectedQuantity': expected,
    'matches': rows.length,
    'quantities': rows.map(quantity).toList(),
  });
  check(
    rows.length == (expected == null ? 0 : 1),
    'Remote $id: expected ${expected == null ? 0 : 1} rows, got ${rows.length}',
  );
  if (expected != null)
    check(quantity(rows.single) == expected, 'Wrong remote quantity for $id');
}
