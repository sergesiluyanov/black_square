import 'package:hive_flutter/hive_flutter.dart';

/// Локальное хранилище (ключ-значение)
class StorageService {
  static const _boxName = 'black_square_storage';
  Box<String>? _box;

  Future<void> initialize() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<String>(_boxName);
  }

  Future<String?> getString(String key) async {
    return _box?.get(key);
  }

  Future<void> setString(String key, String value) async {
    await _box?.put(key, value);
  }

  Future<void> remove(String key) async {
    await _box?.delete(key);
  }

  Future<void> clear() async {
    await _box?.clear();
  }
}
