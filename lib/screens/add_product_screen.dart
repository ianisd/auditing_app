import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../widgets/barcode_scanner.dart';

class AddProductScreen extends StatefulWidget {
  final String? initialBarcode;
  final String? initialName;

  const AddProductScreen({super.key, this.initialBarcode, this.initialName});

  @override
  State<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends State<AddProductScreen> {
  final _formKey = GlobalKey<FormState>();
  final _barcodeController = TextEditingController();
  final _nameController = TextEditingController();
  final _volumeController = TextEditingController();
  final _costController = TextEditingController();

  String _uom = 'ml';
  String? _selectedCategory;

  // --- UPDATED: Includes Food Groups ---
  final List<String> _categories = [
    // Group 1: Drinks
    "Beer", "Cider", "Cooler", "Coolers",
    "Champagne", "White Wine", "Sparkling Wine", "Rose", "Red wine", "Sparkling White Wine", "Champagne XL",
    "Soft Drinks", "Still Water", "Sparkling Water",
    "Whiskey", "Vodka", "Tequila", "Liqueurs", "Gin", "Aperatif", "Cognac", "Bourbon", "Rum", "Brandy", "Cordials", "Schnapps",

    // Group 2: Food & Solids
    "Meat", "Poultry", "Seafood",
    "Dairy", "Vegetables", "Fruit",
    "Dry Goods", "Spices", "Bakery",
    "Prepared Food", "Consumables"
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialBarcode != null) _barcodeController.text = widget.initialBarcode!;
    if (widget.initialName != null) _nameController.text = widget.initialName!;

    // Sort categories alphabetically for easier finding
    _categories.sort();
  }

  @override
  void dispose() {
    _barcodeController.dispose();
    _nameController.dispose();
    _volumeController.dispose();
    _costController.dispose();
    super.dispose();
  }

  // --- UPDATED LOGIC: Handle Food Groups ---
  String _deriveMainCategory(String category) {
    // Food Mappings
    if (["Meat", "Poultry", "Seafood"].contains(category)) return "Proteins";
    if (["Dairy", "Vegetables", "Fruit"].contains(category)) return "Perishables";
    if (["Dry Goods", "Spices", "Bakery"].contains(category)) return "Pantry";
    if (["Consumables"].contains(category)) return "Non-Food";

    // Drink Mappings
    if (["Coolers", "Cider", "Beer", "Cooler"].contains(category)) {
      return "Beer/Ciders/Coolers";
    }
    if (["Champagne", "White Wine", "Sparkling Wine", "Rose", "Red wine", "Sparkling White Wine", "Champagne XL"].contains(category)) {
      return "Wine/Champagne/Sparkling Wine";
    }
    if (["Soft Drinks", "Still Water", "Sparkling Water"].contains(category)) {
      return "Soft Drinks/Water";
    }
    if (["Whiskey", "Vodka", "Tequila", "Liqueurs", "Gin", "Aperatif", "Cognac", "Bourbon", "Rum", "Brandy", "Cordials", "Schnapps"].contains(category)) {
      return "Spirits";
    }

    return "Other";
  }

  Future<void> _scanBarcode() async {
    final barcode = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const BarcodeScannerModal(),
    );

    if (barcode != null) {
      setState(() {
        _barcodeController.text = barcode;
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // Logic to set Main Category
    final mainCategory = _selectedCategory != null
        ? _deriveMainCategory(_selectedCategory!)
        : 'Other';

    final newItem = {
      'Barcode': _barcodeController.text.trim(),
      'Inventory Product Name': _nameController.text.trim(),
      'Product Name': _nameController.text.trim(), // Keep sync
      'Main Category': mainCategory, // AUTOMATED
      'Category': _selectedCategory ?? 'Other',
      'Single Unit Volume': double.tryParse(_volumeController.text) ?? 0.0,
      'UoM': _uom,
      'Cost Price': double.tryParse(_costController.text) ?? 0.0,
      'Pack Size': 'Single',
      'Gradient': 0.0,
      'Intercept': 0.0,
    };

    // Save to Local Offline Storage
    await context.read<OfflineStorage>().saveNewLocalProduct(newItem);

    if (mounted) {
      Navigator.pop(context, newItem);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Product')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // BARCODE
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _barcodeController,
                      decoration: const InputDecoration(
                        labelText: 'Barcode *',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => v!.isEmpty ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _scanBarcode,
                    icon: const Icon(Icons.qr_code),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // NAME
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Inventory Product Name *',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              // CATEGORY DROPDOWN
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Category *',
                  border: OutlineInputBorder(),
                ),
                value: _selectedCategory,
                items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (val) => setState(() => _selectedCategory = val),
                validator: (v) => v == null ? 'Required' : null,
              ),

              const SizedBox(height: 16),

              // VOLUME/WEIGHT & UOM
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _volumeController,
                      decoration: const InputDecoration(
                        labelText: 'Unit Size (Vol/Weight)', // Generic Label
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 100,
                    child: DropdownButtonFormField<String>(
                      decoration: const InputDecoration(
                        labelText: 'UoM',
                        border: OutlineInputBorder(),
                      ),
                      value: _uom,
                      // Updated UoM List
                      items: ['ml', 'Ltr', 'cl', 'kg', 'g', 'lb', 'oz', 'each']
                          .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                          .toList(),
                      onChanged: (v) => setState(() => _uom = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // COST
              TextFormField(
                controller: _costController,
                decoration: const InputDecoration(
                  labelText: 'Cost Price',
                  border: OutlineInputBorder(),
                  prefixText: '\$ ',
                ),
                keyboardType: TextInputType.number,
              ),

              const SizedBox(height: 32),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save & Add to Inventory'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}