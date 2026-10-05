import 'grv_parser.dart';
import 'offline_storage.dart';

/// Non-UI, read-only GRV preflight.
///
/// This deliberately does not:
/// - create suppliers
/// - save invoices
/// - save PLU mappings
/// - save purchases
/// - make fuzzy matches automatically
///
/// It extracts the deterministic part of the current GRV workflow so the UI
/// and tests can share the same duplicate / PLU / cost resolution rules.
class GrvImportService {
  final OfflineStorage storage;

  GrvImportService({required this.storage});

  Future<GrvPreflightResult> preflight(GrvData grv) async {
    final supplierId = await storage.findSupplierIdByAnyName(
      grv.supplierName,
      allowAutoCreate: false,
    );

    String canonicalSupplierName = grv.supplierName;
    final suppliers = await storage.getMasterSuppliersCached();

    if (supplierId != null) {
      final supplier = suppliers.firstWhere(
        (s) => s['supplierID']?.toString() == supplierId,
        orElse: () => <String, dynamic>{},
      );
      final name = supplier['Supplier']?.toString().trim();
      if (name != null && name.isNotEmpty) canonicalSupplierName = name;
    }

    Map<String, dynamic>? duplicate;
    if (grv.invoiceNumber.trim().isNotEmpty) {
      duplicate = await storage.findInvoiceBySupplierAndNumber(
        supplierName: grv.supplierName,
        invoiceNumber: grv.invoiceNumber,
        grvReference: grv.grvReference,
        supplierId: supplierId,
        deliveryDate: grv.deliveryDate.toIso8601String(),
      );
    }

    final inventory = await storage.getAllInventory();
    final costs = await storage.getMasterCosts();
    final pluLookup = await _buildPluLookup();
    final productByName = <String, Map<String, dynamic>>{
      for (final product in inventory)
        if (_productName(product).isNotEmpty)
          _productName(product).toLowerCase(): product,
    };

    final costLookup = <String, Map<String, dynamic>>{};
    for (final cost in costs) {
      final sid = cost['supplierID']?.toString().trim() ?? '';
      final name = cost['Product Name']?.toString().trim().toLowerCase() ?? '';
      if (sid.isNotEmpty && name.isNotEmpty) {
        costLookup['$sid|$name'] = cost;
      }
    }

    final lines = <GrvPreflightLine>[];
    for (var i = 0; i < grv.lineItems.length; i++) {
      final item = grv.lineItems[i];
      String? productName;
      String? barcode;
      String? supplierBottleId;
      String? matchedBy;
      String? mappedPlu;
      Map<String, dynamic>? product;

      final csvPlu = item.plu.trim();

      // Same first choice as the current screen: supplier-specific saved mapping.
      if (supplierId != null && csvPlu.isNotEmpty) {
        final saved = await storage.getPluMapping(supplierId, csvPlu);
        if (saved != null) {
          mappedPlu = saved.correctPlu;
          product = productByName[saved.productName.trim().toLowerCase()];

          if (product != null) {
            productName = _productName(product);
            barcode = product['Barcode']?.toString();
            matchedBy = 'saved_mapping';
          } else {
            final viaPlu = pluLookup[saved.correctPlu];
            final candidate = viaPlu?['productName']?.toString().trim();
            if (candidate != null && candidate.isNotEmpty) {
              final inventoryProduct = productByName[candidate.toLowerCase()];
              if (inventoryProduct != null) {
                product = inventoryProduct;
                productName = _productName(inventoryProduct);
                barcode = inventoryProduct['Barcode']?.toString();
                matchedBy = 'saved_mapping';
              }
            }
          }
        }
      }

      // Same second deterministic choice as the current screen: direct PLU,
      // but only when the mapped name resolves to a real inventory record.
      if (productName == null && csvPlu.isNotEmpty) {
        final direct = pluLookup[csvPlu];
        final candidate = direct?['productName']?.toString().trim();
        if (candidate != null && candidate.isNotEmpty) {
          final inventoryProduct = productByName[candidate.toLowerCase()];
          if (inventoryProduct != null) {
            product = inventoryProduct;
            productName = _productName(inventoryProduct);
            barcode = inventoryProduct['Barcode']?.toString();
            matchedBy = 'plu_direct';
          }
        }
      }

      double resolvedCost = item.pricePerUnit;
      if (supplierId != null && productName != null) {
        final cost =
            costLookup['$supplierId|${productName.toLowerCase().trim()}'];
        if (cost != null) {
          supplierBottleId = cost['supplierBottleID']?.toString();
          resolvedCost = _extractCost(cost) ?? item.pricePerUnit;
        }
      }

      final fuzzyCandidates = productName == null
          ? _findFuzzyCandidates(item.description, productByName)
          : const <Map<String, dynamic>>[];

      lines.add(
        GrvPreflightLine(
          index: i,
          plu: csvPlu,
          description: item.description,
          quantityCases: item.quantityCases,
          unitsPerCase: item.unitsPerCase,
          csvPricePerUnit: item.pricePerUnit,
          resolvedPricePerUnit: resolvedCost,
          productName: productName,
          barcode: barcode,
          supplierBottleId: supplierBottleId,
          mappedPlu: mappedPlu,
          matchedBy: matchedBy,
          fuzzyCandidates: fuzzyCandidates,
        ),
      );
    }

    return GrvPreflightResult(
      supplierId: supplierId,
      sourceSupplierName: grv.supplierName,
      canonicalSupplierName: canonicalSupplierName,
      invoiceNumber: grv.invoiceNumber,
      grvReference: grv.grvReference,
      deliveryDate: grv.deliveryDate,
      duplicateInvoice: duplicate,
      lines: lines,
    );
  }

  /// Builds the same PLU hierarchy currently used by GrvLineItemsScreen:
  /// ItemsIssuedMap -> ItemsIssued -> StockIssues.
  Future<Map<String, Map<String, dynamic>>> _buildPluLookup() async {
    final result = <String, Map<String, dynamic>>{};

    final issuedMap = await storage.getItemsIssuedMap();
    for (final row in issuedMap) {
      final plu = row['PLU']?.toString().trim() ?? '';
      final product = row['Product']?.toString().trim();
      final menu = row['Menu Item']?.toString().trim();
      final name = (product != null && product.isNotEmpty) ? product : menu;
      if (plu.isNotEmpty && name != null && name.isNotEmpty) {
        result[plu] = {'productName': name, 'source': 'ItemsIssuedMap'};
      }
    }

    final issued = await storage.getItemsIssued();
    for (final row in issued) {
      final plu = row['PLU']?.toString().trim() ?? '';
      final name = row['Menu Item']?.toString().trim() ?? '';
      if (plu.isNotEmpty && name.isNotEmpty && !result.containsKey(plu)) {
        result[plu] = {'productName': name, 'source': 'ItemsIssued'};
      }
    }

    final stockIssues = await storage.getStockIssues();
    for (final row in stockIssues) {
      final plu = row['Item']?.toString().trim() ?? '';
      final name = row['Name']?.toString().trim() ?? '';
      if (plu.isNotEmpty && name.isNotEmpty && !result.containsKey(plu)) {
        result[plu] = {'productName': name, 'source': 'StockIssues'};
      }
    }

    return result;
  }

  String _productName(Map<String, dynamic> product) =>
      product['Inventory Product Name']?.toString().trim() ?? '';

  double? _extractCost(Map<String, dynamic> row) {
    final value =
        row['Cost Price'] ??
        row['cost'] ??
        row['avgCost'] ??
        row['Unit Cost'] ??
        row['Cost'];
    if (value is num) return value.toDouble();
    if (value is String) {
      final clean = value
          .replaceAll(',', '')
          .replaceAll(RegExp(r'[^\d.-]'), '');
      return double.tryParse(clean);
    }
    return null;
  }

  /// Suggestions only. A fuzzy result is never treated as a confirmed match.
  List<Map<String, dynamic>> _findFuzzyCandidates(
    String description,
    Map<String, Map<String, dynamic>> productByName,
  ) {
    String normalize(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(
          RegExp(r'\b(the|and|yr|yrs|ml|btl|bottle|pack|case|can|glass)\b'),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final wanted = normalize(description);
    if (wanted.isEmpty) return const [];

    final wantedWords = wanted.split(' ').where((w) => w.length >= 2).toList();
    final scored = <MapEntry<Map<String, dynamic>, double>>[];

    for (final entry in productByName.entries) {
      final candidate = normalize(entry.key);
      var score = 0.0;

      if (candidate == wanted) score += 100;
      if (candidate.contains(wanted)) score += 50;
      if (wanted.contains(candidate)) score += 40;

      final candidateWords = candidate.split(' ');
      for (final word in wantedWords) {
        if (candidateWords.contains(word)) {
          score += 10;
        } else if (candidate.contains(word)) {
          score += 5;
        }
      }

      score /= (candidateWords.length + 1);
      if (score > 0.3) scored.add(MapEntry(entry.value, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(10).map((e) => e.key).toList(growable: false);
  }
}

class GrvPreflightResult {
  final String? supplierId;
  final String sourceSupplierName;
  final String canonicalSupplierName;
  final String invoiceNumber;
  final String grvReference;
  final DateTime deliveryDate;
  final Map<String, dynamic>? duplicateInvoice;
  final List<GrvPreflightLine> lines;

  const GrvPreflightResult({
    required this.supplierId,
    required this.sourceSupplierName,
    required this.canonicalSupplierName,
    required this.invoiceNumber,
    required this.grvReference,
    required this.deliveryDate,
    required this.duplicateInvoice,
    required this.lines,
  });

  bool get supplierResolved => supplierId != null && supplierId!.isNotEmpty;
  bool get isDuplicate => duplicateInvoice != null;
  int get deterministicMatches => lines.where((e) => e.isMatched).length;
  int get needsUserResolution => lines.where((e) => !e.isMatched).length;
}

class GrvPreflightLine {
  final int index;
  final String plu;
  final String description;
  final int quantityCases;
  final int unitsPerCase;
  final double csvPricePerUnit;
  final double resolvedPricePerUnit;
  final String? productName;
  final String? barcode;
  final String? supplierBottleId;
  final String? mappedPlu;
  final String? matchedBy;
  final List<Map<String, dynamic>> fuzzyCandidates;

  const GrvPreflightLine({
    required this.index,
    required this.plu,
    required this.description,
    required this.quantityCases,
    required this.unitsPerCase,
    required this.csvPricePerUnit,
    required this.resolvedPricePerUnit,
    required this.productName,
    required this.barcode,
    required this.supplierBottleId,
    required this.mappedPlu,
    required this.matchedBy,
    required this.fuzzyCandidates,
  });

  bool get isMatched =>
      productName != null &&
      productName!.trim().isNotEmpty &&
      (matchedBy == 'saved_mapping' || matchedBy == 'plu_direct');

  bool get needsUserResolution => !isMatched;
}
