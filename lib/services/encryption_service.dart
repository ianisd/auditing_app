import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

class EncryptionService {
  static Future<Uint8List>? _keyLoad;
  static Future<Uint8List> _loadEncryptionKey() async {
    final stored = await _storage.read(key: _keyName);
    final key = stored == null ? Uint8List.fromList(Hive.generateSecureKey())
        : base64.decode(stored);
    if (key.length != 32) throw StateError('Invalid saved Hive encryption key; recovery required.');
    if (stored == null) await _storage.write(key: _keyName, value: base64.encode(key));
    _cachedKey = Uint8List.fromList(key);
    return Uint8List.fromList(key);
  }
  static const String _keyName = 'hive_encryption_key';
  static final _storage = const FlutterSecureStorage();
  
  static Uint8List? _cachedKey;

  /// Get the existing encryption key or generate a new one if it doesn't exist.
  /// This key is stored securely in the device's Keychain/Keystore.
  static Future<Uint8List> getEncryptionKey() async {
    if (_cachedKey != null) return Uint8List.fromList(_cachedKey!);
    final pending = _keyLoad ??= _loadEncryptionKey();
    try {
      return Uint8List.fromList(await pending);
    } finally {
      if (identical(_keyLoad, pending)) _keyLoad = null;
    }
  }
}
