import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

class EncryptionService {
  static const String _keyName = 'hive_encryption_key';
  static final _storage = const FlutterSecureStorage();
  
  static Uint8List? _cachedKey;

  /// Get the existing encryption key or generate a new one if it doesn't exist.
  /// This key is stored securely in the device's Keychain/Keystore.
  static Future<Uint8List> getEncryptionKey() async {
    if (_cachedKey != null) return _cachedKey!;

    // 1. Check if we already have a key stored
    final String? base64Key = await _storage.read(key: _keyName);
    
    if (base64Key == null) {
      // 2. Generate a new key if none exists
      final List<int> key = Hive.generateSecureKey();
      final String encodedKey = base64.encode(key);
      
      // 3. Store it securely
      await _storage.write(key: _keyName, value: encodedKey);
      
      _cachedKey = Uint8List.fromList(key);
      return _cachedKey!;
    } else {
      // 4. Decode and return the existing key
      _cachedKey = base64.decode(base64Key);
      return _cachedKey!;
    }
  }
}
