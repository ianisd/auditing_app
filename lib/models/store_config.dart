import 'package:hive/hive.dart';

part 'store_config.g.dart'; // Run: flutter pub run build_runner build

@HiveType(typeId: 2) // Unique TypeID
class StoreConfig {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String scriptUrl;

  StoreConfig({
    required this.id,
    required this.name,
    required this.scriptUrl,
  });
}