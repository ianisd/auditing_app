import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/store_manager.dart';
import '../widgets/barcode_scanner.dart'; // Your existing scanner widget

class SetupStoreScreen extends StatefulWidget {
  const SetupStoreScreen({super.key});

  @override
  State<SetupStoreScreen> createState() => _SetupStoreScreenState();
}

class _SetupStoreScreenState extends State<SetupStoreScreen> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;

  Future<void> _scanQr() async {
    // Navigate to your existing scanner
    final result = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const BarcodeScannerModal(),
    );

    if (result != null && result.startsWith('http')) {
      setState(() {
        _urlController.text = result;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL Scanned Successfully!')),
      );
    } else if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid QR Code. Must be a URL.')),
      );
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final name = _nameController.text.trim();
      final url = _urlController.text.trim();

      // Basic validation
      if (!url.startsWith('http')) {
        throw Exception('Invalid URL format');
      }

      // Add to Store Manager
      await context.read<StoreManager>().addStore(name, url);

      // StoreManager automatically sets it active,
      // Main.dart listener will detect change and route to Home.
      // If we were pushed here from the Drawer (Navigator can pop), then pop.
      // If this is the first launch (Navigator can't pop), RootSwitcher handles it automatically.
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Store')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.store_mall_directory, size: 64, color: Colors.blue),
              const SizedBox(height: 24),
              const Text(
                'Enter your Google Script URL or Scan the Setup QR code provided by your admin.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 32),

              // 1. Store Name
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Store Name (e.g. Cape Town)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.label),
                ),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              // 2. URL Input + Scan Button
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: 'Script URL',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.link),
                      ),
                      validator: (v) => v!.isEmpty ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _scanQr,
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: 'Scan QR',
                    style: IconButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.all(16),
                    ),
                  ),
                ],
              ),

              const Spacer(),

              // 3. Save Button
              ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isSaving
                    ? const CircularProgressIndicator()
                    : const Text('CONNECT STORE'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}