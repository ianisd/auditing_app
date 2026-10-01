import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/offline_storage.dart';
import '../widgets/barcode_scanner.dart';
import '../services/food_stock_fields.dart';


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
  bool _saving = false;
  bool get _isFood => FoodStockFields.mainCategory(_selectedCategory ?? '') != null;
  String? _selectedCategory;

  // --- UPDATED: Includes Food Groups ---
  final List<String> _categories = [
    // Group 1: Drinks
    "Beer", "Cider", "Cooler", "Coolers",
    "Champagne", "White Wine", "Sparkling Wine", "Rose", "Red wine", "Sparkling White Wine", "Champagne XL",
    "Soft Drinks", "Still Water", "Sparkling Water",
    "Whiskey", "Vodka", "Tequila", "Liqueurs", "Gin", "Aperatif", "Cognac", "Bourbon", "Rum", "Brandy", "Cordials", "Schnapps",

    ...FoodStockFields.groups.values.expand((categories) => categories),
    'Consumables',
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
    final foodGroup = FoodStockFields.mainCategory(category);
    if (foodGroup != null) return foodGroup;
    if (category == 'Consumables') return 'Non-Food';

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
      return "Spirit";
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
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

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
      'Single Unit Volume': FoodStockFields.number(_volumeController.text) * (_isFood && _uom == 'kg' ? 1000 : 1),
      'UoM': _isFood ? 'g' : _uom,
      'Cost Price': FoodStockFields.number(_costController.text),
      'Pack Size': 'Single',
      'Gradient': 0.0,
      'Intercept': 0.0,
    };

    try {
      await context.read<OfflineStorage>().saveNewLocalProduct(newItem);
      if (mounted) Navigator.pop(context, newItem);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save product: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
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
                initialValue: _selectedCategory,
                items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (val) => setState(() {
                  final wasFood = _isFood;
                  _selectedCategory = val;
                  if (_isFood != wasFood) {
                    _uom = _isFood ? 'g' : 'ml';
                    _volumeController.clear();
                  }
                }),
                validator: (v) => v == null ? 'Required' : null,
              ),

              const SizedBox(height: 16),

              if (_selectedCategory != null) ...[
                Text('Main category: ${_deriveMainCategory(_selectedCategory!)}'),
                const SizedBox(height: 12),
              ],
              // VOLUME/WEIGHT & UOM
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _volumeController,
                      validator: (v) {
                        if (!_isFood) return null;
                        final size = FoodStockFields.number(v);
                        final grams = size * (_uom == 'kg' ? 1000 : 1);
                        return grams.isFinite && grams > 0 ? null : 'Enter a portion weight greater than zero';
                      },
                      decoration: InputDecoration(
                        labelText: _isFood ? 'Portion weight *' : 'Unit Size (Vol/Weight)',
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                      key: ValueKey(_isFood),
                      initialValue: _uom,
                      // Updated UoM List
                      items: (_isFood ? ['g', 'kg'] : ['ml', 'Ltr', 'cl', 'kg', 'g', 'lb', 'oz', 'each'])
                          .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                          .toList(),
                      onChanged: (v) => setState(() {
                        if (v == null) return;
                        if (_isFood && v != _uom && _volumeController.text.trim().isNotEmpty) {
                          final size = FoodStockFields.number(_volumeController.text);
                          _volumeController.text = (_uom == 'kg' ? size * 1000 : size / 1000).toString();
                        }
                        _uom = v;
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_isFood) ...[
                const Text('Enter the weight of one portion, not the delivery pack. For example: 200 g. Counts are saved in grams; portions = weight ÷ portion weight.'),
                const SizedBox(height: 16),
              ],
              // COST
              TextFormField(
                controller: _costController,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  final cost = double.tryParse(v.trim().replaceAll(',', '.'));
                  return cost != null && cost.isFinite && cost >= 0 ? null : 'Enter a valid non-negative cost';
                },
                decoration: InputDecoration(
                  labelText: _isFood ? 'Cost per portion (R)' : 'Cost Price',
                  border: const OutlineInputBorder(),
                  prefixText: 'R ',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),

              const SizedBox(height: 32),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
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