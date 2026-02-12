import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

/// Сервис сквозного шифрования (E2E).
/// Использует AES-256-CBC для шифрования сообщений и файлов.
class EncryptionService {
  static const _storageKey = 'black_square_encryption_key';
  static const _keyLength = 32; // 256 bits for AES-256
  static const _ivLength = 16;

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  encrypt.Encrypter? _encrypter;
  Uint8List? _keyBytes;

  /// Ключ для передачи в изолят (только для encryptBytes в фоне)
  Uint8List? get keyBytesForIsolate => _keyBytes;

  /// Инициализация: загрузка или генерация ключа шифрования
  Future<void> initialize() async {
    String? keyBase64 = await _secureStorage.read(key: _storageKey);

    if (keyBase64 == null) {
      final key = _generateKey();
      await _secureStorage.write(
        key: _storageKey,
        value: base64Encode(key),
      );
      keyBase64 = base64Encode(key);
    }

    final keyBytes = base64Decode(keyBase64);
    _keyBytes = Uint8List.fromList(keyBytes);
    _encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(_keyBytes!)),
    );
  }

  /// Шифрование байтов в изоляте (статический метод для compute)
  static Uint8List encryptBytesWithKey(List<Object> args) {
    final keyBytes = args[0] as Uint8List;
    final data = args[1] as Uint8List;
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(keyBytes)),
    );
    final iv = encrypt.IV.fromLength(_ivLength);
    final encrypted = encrypter.encryptBytes(data, iv: iv);
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  /// Дешифрование байтов в изоляте (статический метод для compute)
  static Uint8List decryptBytesWithKey(List<Object> args) {
    final keyBytes = args[0] as Uint8List;
    final encryptedData = args[1] as Uint8List;
    if (encryptedData.length < _ivLength) {
      throw EncryptionException('Encrypted data too short');
    }
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(keyBytes)),
    );
    final iv = encrypt.IV(encryptedData.sublist(0, _ivLength));
    final cipherBytes = encryptedData.sublist(_ivLength);
    final encrypted = encrypt.Encrypted(Uint8List.fromList(cipherBytes));
    return Uint8List.fromList(encrypter.decryptBytes(encrypted, iv: iv));
  }

  Uint8List _generateKey() {
    final secureRandom = FortunaRandom();
    final seedSource = Random.secure();
    final seeds = <int>[];
    for (int i = 0; i < 32; i++) {
      seeds.add(seedSource.nextInt(256));
    }
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    return secureRandom.nextBytes(_keyLength);
  }

  /// Шифрование текста
  String encryptText(String plainText) {
    _ensureInitialized();
    final iv = encrypt.IV.fromLength(_ivLength);
    final encrypted = _encrypter!.encrypt(plainText, iv: iv);
    return '${base64Encode(iv.bytes)}:${encrypted.base64}';
  }

  /// Дешифрование текста
  String decryptText(String encryptedData) {
    _ensureInitialized();
    final parts = encryptedData.split(':');
    if (parts.length != 2) {
      throw EncryptionException('Invalid encrypted data format');
    }
    final iv = encrypt.IV(base64Decode(parts[0]));
    final encrypted = encrypt.Encrypted.fromBase64(parts[1]);
    return _encrypter!.decrypt(encrypted, iv: iv);
  }

  /// Шифрование байтов (для файлов)
  Uint8List encryptBytes(Uint8List data) {
    _ensureInitialized();
    final iv = encrypt.IV.fromLength(_ivLength);
    final encrypted = _encrypter!.encryptBytes(data, iv: iv);
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  /// Дешифрование байтов
  Uint8List decryptBytes(Uint8List encryptedData) {
    _ensureInitialized();
    if (encryptedData.length < _ivLength) {
      throw EncryptionException('Encrypted data too short');
    }
    final iv = encrypt.IV(encryptedData.sublist(0, _ivLength));
    final cipherBytes = encryptedData.sublist(_ivLength);
    final encrypted = encrypt.Encrypted(Uint8List.fromList(cipherBytes));
    return Uint8List.fromList(_encrypter!.decryptBytes(encrypted, iv: iv));
  }

  /// Шифрование текста общим ключом чата (shareCode)
  static String encryptWithShareCode(String plainText, String shareCode) {
    final encrypter = _encrypterFromShareCode(shareCode);
    final iv = encrypt.IV.fromLength(_ivLength);
    final encrypted = encrypter.encrypt(plainText, iv: iv);
    return '${base64Encode(iv.bytes)}:${encrypted.base64}';
  }

  /// Дешифрование текста общим ключом чата
  static String decryptWithShareCode(String encryptedData, String shareCode) {
    final encrypter = _encrypterFromShareCode(shareCode);
    final parts = encryptedData.split(':');
    if (parts.length != 2) throw EncryptionException('Invalid format');
    final iv = encrypt.IV(base64Decode(parts[0]));
    final encrypted = encrypt.Encrypted.fromBase64(parts[1]);
    return encrypter.decrypt(encrypted, iv: iv);
  }

  /// Шифрование байтов общим ключом чата (для файлов)
  static Uint8List encryptBytesWithShareCode(Uint8List data, String shareCode) {
    final encrypter = _encrypterFromShareCode(shareCode);
    final iv = encrypt.IV.fromLength(_ivLength);
    final encrypted = encrypter.encryptBytes(data, iv: iv);
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  /// Дешифрование байтов общим ключом чата
  static Uint8List decryptBytesWithShareCode(Uint8List encryptedData, String shareCode) {
    if (encryptedData.length < _ivLength) throw EncryptionException('Data too short');
    final encrypter = _encrypterFromShareCode(shareCode);
    final iv = encrypt.IV(encryptedData.sublist(0, _ivLength));
    final cipherBytes = encryptedData.sublist(_ivLength);
    final encrypted = encrypt.Encrypted(Uint8List.fromList(cipherBytes));
    return Uint8List.fromList(encrypter.decryptBytes(encrypted, iv: iv));
  }

  static encrypt.Encrypter _encrypterFromShareCode(String shareCode) {
    final hash = SHA256Digest().process(Uint8List.fromList(shareCode.codeUnits));
    return encrypt.Encrypter(encrypt.AES(encrypt.Key(Uint8List.fromList(hash))));
  }

  void _ensureInitialized() {
    if (_encrypter == null) {
      throw EncryptionException(
        'EncryptionService not initialized. Call initialize() first.',
      );
    }
  }

  /// Проверка инициализации
  bool get isInitialized => _encrypter != null;
}

class EncryptionException implements Exception {
  final String message;
  EncryptionException(this.message);

  @override
  String toString() => 'EncryptionException: $message';
}
