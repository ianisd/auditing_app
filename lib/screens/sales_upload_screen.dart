import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/sales_import_model.dart';
import '../services/gaap_sales_parser.dart';

class SalesUploadScreen extends StatefulWidget {
  const SalesUploadScreen({super.key});

  @override
  State<SalesUploadScreen> createState() => _SalesUploadScreenState();
}

class _SalesUploadScreenState extends State<SalesUploadScreen> {
  DateTime? _auditDate;
  ParsedGaapSalesFile? _parsed;
  String? _fileName;
  String? _error;

  bool _isLoading = false;
  bool _isDragging = false;

  bool get _isDesktop =>
      !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.linux);

  // ===========================================================================
  // AUDIT DATE
  // ===========================================================================

  Future<void> _selectAuditDate() async {
    final now = DateTime.now();

    final selected = await showDatePicker(
      context: context,
      initialDate: _auditDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 2, 12, 31),
      helpText: 'Select audit date',
    );

    if (selected != null && mounted) {
      setState(() {
        _auditDate = DateTime(
          selected.year,
          selected.month,
          selected.day,
        );

        _error = null;
      });
    }
  }

  // ===========================================================================
  // AUDIT DATE VALIDATION
  // ===========================================================================

  /// Returns the latest reliable date contained in the GAAP document.
  ///
  /// We intentionally use the later of:
  /// - GAAP report end date
  /// - GAAP generated/export date
  ///
  /// Example:
  /// Report ends: 02/07
  /// File generated: 13/07
  /// Audit: 18/07
  ///
  /// Reference = 13/07, making the audit 5 days later and therefore valid.
  DateTime? _salesReferenceDate(ParsedGaapSalesFile parsed) {
    final reportTo = parsed.reportTo;
    final generated = parsed.generatedDate;

    if (reportTo == null) return generated;
    if (generated == null) return reportTo;

    return generated.isAfter(reportTo)
        ? generated
        : reportTo;
  }

  /// Difference in calendar days between the selected audit date
  /// and the latest reliable date in the GAAP document.
  int? _auditDateGap(ParsedGaapSalesFile parsed) {
    if (_auditDate == null) return null;

    final reference = _salesReferenceDate(parsed);

    if (reference == null) return null;

    final audit = DateTime(
      _auditDate!.year,
      _auditDate!.month,
      _auditDate!.day,
    );

    final ref = DateTime(
      reference.year,
      reference.month,
      reference.day,
    );

    return audit.difference(ref).inDays;
  }

  /// Audit dates are considered suspicious when:
  ///
  /// - the audit occurs before the latest GAAP date; or
  /// - the audit occurs more than 7 days after it.
  ///
  /// This is deliberately a warning rather than a hard validation failure.
  bool _auditDateNeedsWarning(ParsedGaapSalesFile parsed) {
    final gap = _auditDateGap(parsed);

    return gap != null && (gap < 0 || gap > 7);
  }

  // ===========================================================================
  // FILE PICKER
  // ===========================================================================

  Future<void> _pickCsv() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      dialogTitle: 'Select GAAP Sales CSV',
      withData: kIsWeb,
    );

    if (result == null) return;

    final selected = result.files.single;

    if (kIsWeb) {
      final bytes = selected.bytes;

      if (bytes == null) {
        _showError('Could not read the selected file.');
        return;
      }

      await _processBytes(
        bytes,
        selected.name,
      );

      return;
    }

    final path = selected.path;

    if (path == null) {
      _showError('Could not access the selected file.');
      return;
    }

    await _processPath(path);
  }

  Future<void> _processPath(String path) async {
    if (!path.toLowerCase().endsWith('.csv')) {
      _showError('Only CSV files are supported.');
      return;
    }

    final file = File(path);
    final bytes = await file.readAsBytes();

    await _processBytes(
      bytes,
      path.split(Platform.pathSeparator).last,
    );
  }

  // ===========================================================================
  // PARSING
  // ===========================================================================

  Future<void> _processBytes(
      List<int> bytes,
      String fileName,
      ) async {
    if (_auditDate == null) {
      _showError(
        'Select the audit date before uploading the sales file.',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _parsed = null;
      _fileName = null;
    });

    try {
      String content;

      try {
        content = utf8.decode(bytes);
      } on FormatException {
        // GAAP / Excel exports may use Windows-compatible
        // single-byte encodings rather than UTF-8.
        content = latin1.decode(bytes);
      }

      final parser = GaapSalesParser();
      final parsed = parser.parse(content);

      if (!mounted) return;

      setState(() {
        _parsed = parsed;
        _fileName = fileName;
      });
    } on FormatException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError(
        'Could not parse sales file: $e',
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isDragging = false;
        });
      }
    }
  }

  // ===========================================================================
  // ERROR HANDLING
  // ===========================================================================

  void _showError(String message) {
    if (!mounted) return;

    setState(() {
      _error = message;
      _isDragging = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  // ===========================================================================
  // DATE FORMATTING
  // ===========================================================================

  String _date(DateTime? value) {
    if (value == null) return 'Not found';

    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');

    return '$day/$month/${value.year}';
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload Sales'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 700,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'GAAP Sales Import',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Select the audit date first. '
                      'The dates inside the GAAP report are shown '
                      'for validation only.',
                  style: TextStyle(
                    color: Colors.grey[700],
                  ),
                ),

                const SizedBox(height: 24),

                _buildAuditDateCard(),

                const SizedBox(height: 20),

                if (_isDesktop)
                  _buildDropZone(),

                if (_isDesktop)
                  const SizedBox(height: 12),

                FilledButton.icon(
                  onPressed:
                  _isLoading ? null : _pickCsv,
                  icon: const Icon(
                    Icons.upload_file,
                  ),
                  label: Text(
                    _isLoading
                        ? 'Reading file...'
                        : 'Select GAAP Sales CSV',
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.red,
                    ),
                  ),
                ],

                if (_parsed != null) ...[
                  const SizedBox(height: 24),
                  _buildPreview(_parsed!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // AUDIT DATE CARD
  // ===========================================================================

  Widget _buildAuditDateCard() {
    final selected = _auditDate != null;

    return Card(
      child: ListTile(
        leading: Icon(
          Icons.calendar_month,
          color:
          selected ? Colors.green : Colors.orange,
        ),
        title: const Text(
          'Audit Date',
        ),
        subtitle: Text(
          selected
              ? _date(_auditDate)
              : 'Required — this determines which audit '
              'the sales belong to',
        ),
        trailing: OutlinedButton(
          onPressed: _selectAuditDate,
          child: Text(
            selected ? 'Change' : 'Select',
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // DROP ZONE
  // ===========================================================================

  Widget _buildDropZone() {
    return DropTarget(
      onDragEntered: (_) {
        setState(() {
          _isDragging = true;
        });
      },
      onDragExited: (_) {
        setState(() {
          _isDragging = false;
        });
      },
      onDragDone: (details) async {
        if (details.files.isEmpty) return;

        await _processPath(
          details.files.first.path,
        );
      },
      child: AnimatedContainer(
        duration:
        const Duration(milliseconds: 150),
        height: 150,
        decoration: BoxDecoration(
          borderRadius:
          BorderRadius.circular(12),
          border: Border.all(
            width: 2,
            color: _isDragging
                ? Colors.blue
                : Colors.grey.shade400,
          ),
          color: _isDragging
              ? Colors.blue.withOpacity(0.05)
              : null,
        ),
        child: Center(
          child: Column(
            mainAxisSize:
            MainAxisSize.min,
            children: [
              Icon(
                Icons.file_upload_outlined,
                size: 38,
                color: _isDragging
                    ? Colors.blue
                    : Colors.grey[600],
              ),
              const SizedBox(height: 8),
              Text(
                _isDragging
                    ? 'Drop GAAP sales CSV here'
                    : 'Drag & drop GAAP sales CSV',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // IMPORT PREVIEW
  // ===========================================================================

  Widget _buildPreview(
      ParsedGaapSalesFile parsed,
      ) {
    return Card(
      child: Padding(
        padding:
        const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment:
          CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Import Preview',
              style: TextStyle(
                fontSize: 20,
                fontWeight:
                FontWeight.bold,
              ),
            ),

            const SizedBox(height: 16),

            _row(
              'File',
              _fileName ?? '',
            ),

            _row(
              'Audit date',
              _date(_auditDate),
            ),

            _row(
              'Venue',
              parsed.venue ??
                  'Not found',
            ),

            _row(
              'GAAP generated date',
              _date(
                parsed.generatedDate,
              ),
            ),

            _row(
              'GAAP report range',
              '${_date(parsed.reportFrom)} '
                  '→ '
                  '${_date(parsed.reportTo)}',
            ),

            // ---------------------------------------------------------------
            // AUDIT DATE WARNING
            // ---------------------------------------------------------------

            if (_auditDateNeedsWarning(
              parsed,
            )) ...[
              const SizedBox(
                height: 16,
              ),
              _buildAuditDateWarning(
                parsed,
              ),
            ],

            const Divider(
              height: 28,
            ),

            _row(
              'Raw rows preserved',
              '${parsed.rowCount}',
            ),

            _row(
              'Non-blank rows',
              '${parsed.nonBlankRowCount}',
            ),

            _row(
              'Detected sales lines',
              '${parsed.saleLineCount}',
            ),

            const SizedBox(
              height: 16,
            ),

            Container(
              padding:
              const EdgeInsets.all(12),
              decoration:
              BoxDecoration(
                color: Colors.green
                    .withOpacity(0.08),
                borderRadius:
                BorderRadius.circular(8),
              ),
              child: const Text(
                'Parsed successfully. '
                    'Nothing has been uploaded yet.',
                style: TextStyle(
                  fontWeight:
                  FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // AUDIT DATE WARNING
  // ===========================================================================

  Widget _buildAuditDateWarning(
      ParsedGaapSalesFile parsed,
      ) {
    final reference =
    _salesReferenceDate(parsed);

    final gap =
    _auditDateGap(parsed)!;

    final message = gap < 0
        ? 'The selected audit date is '
        '${gap.abs()} day(s) before the '
        'latest date in this GAAP document.'
        : 'The selected audit date is '
        '$gap day(s) after the '
        'latest date in this GAAP document.';

    return Container(
      padding:
      const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:
        Colors.orange.withOpacity(0.10),
        border: Border.all(
          color:
          Colors.orange.shade400,
        ),
        borderRadius:
        BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color:
            Colors.orange.shade800,
          ),

          const SizedBox(
            width: 12,
          ),

          Expanded(
            child: Column(
              crossAxisAlignment:
              CrossAxisAlignment.start,
              children: [
                const Text(
                  'Check audit date',
                  style: TextStyle(
                    fontWeight:
                    FontWeight.bold,
                    fontSize: 16,
                  ),
                ),

                const SizedBox(
                  height: 6,
                ),

                Text(message),

                const SizedBox(
                  height: 6,
                ),

                Text(
                  'Selected audit date: '
                      '${_date(_auditDate)}\n'
                      'Latest GAAP date: '
                      '${_date(reference)}',
                ),

                const SizedBox(
                  height: 8,
                ),

                const Text(
                  'You can still continue, '
                      'but please confirm that '
                      'the selected audit date '
                      'is correct.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // INFO ROW
  // ===========================================================================

  Widget _row(
      String label,
      String value,
      ) {
    return Padding(
      padding:
      const EdgeInsets.symmetric(
        vertical: 4,
      ),
      child: Row(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Text(
              '$label:',
              style:
              const TextStyle(
                fontWeight:
                FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }
}