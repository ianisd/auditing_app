// screens/migrate_store_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/store_manager.dart';

class MigrateStoreScreen extends StatefulWidget {
  final Map<String, dynamic> store;

  const MigrateStoreScreen({super.key, required this.store});

  @override
  State<MigrateStoreScreen> createState() => _MigrateStoreScreenState();
}

class _MigrateStoreScreenState extends State<MigrateStoreScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _updateStore() async {
    final sheetId = _controller.text.trim();
    if (sheetId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a Sheet ID')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final storeManager = context.read<StoreManager>();
      await storeManager.updateStoreSheetId(widget.store['id'], sheetId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ ${widget.store['name']} updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLegacy = widget.store['isLegacy'] == true;
    final hasSheetId = (widget.store['sheetId']?.toString() ?? '').isNotEmpty;
    final hasScriptId = (widget.store['scriptId']?.toString() ?? '').isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text('Update Store: ${widget.store['name']}'),
        backgroundColor: isLegacy ? Colors.orange : null,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isLegacy ? Colors.orange.shade50 : Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isLegacy ? Colors.orange.shade200 : Colors.green.shade200,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isLegacy ? Icons.warning_amber : Icons.check_circle,
                        color: isLegacy ? Colors.orange : Colors.green,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isLegacy ? 'Legacy Store Detected' : 'Store Configuration',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isLegacy ? Colors.orange.shade900 : Colors.green.shade900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (hasSheetId)
                    _buildInfoRow('✅ Sheet ID:', widget.store['sheetId'].toString())
                  else if (hasScriptId)
                    _buildInfoRow('⚠️ Script ID:', widget.store['scriptId'].toString())
                  else
                    const Text('No valid ID found'),
                ],
              ),
            ),

            const SizedBox(height: 24),

            if (isLegacy) ...[
              const Text(
                'This store was created with an older version and needs the Google Sheet ID to work properly.',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),

              const Text(
                'How to find your Sheet ID:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 16),

              _buildStep('1. Open your store Google Sheet'),
              _buildStep('2. Look in the URL - it looks like this:'),

              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: const SelectableText(
                  'https://docs.google.com/spreadsheets/d/bc1q7f49hcm07awcj2y32a5ypzxyekmdr6q66hnn0s/edit',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),

              _buildStep('3. Copy the ID part:'),
              Container(
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(left: 16, top: 4, bottom: 24),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const SelectableText(
                  'bc1q7f49hcm07awcj2y32a5ypzxyekmdr6q66hnn0s',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ),
            ],

            // Sheet ID Input
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                labelText: 'Google Sheet ID',
                hintText: hasSheetId ? widget.store['sheetId'].toString() : 'Paste sheet ID here',
                border: const OutlineInputBorder(),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => _controller.clear(),
                )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
              enabled: !_isLoading,
            ),

            const SizedBox(height: 24),

            // Update Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _updateStore,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.blue,
                ),
                child: _isLoading
                    ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Text('Update Store', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}