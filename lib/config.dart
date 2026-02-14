/// Конфигурация приложения
class Config {
  /// URL WebSocket сервера
  static const String serverUrl = 'ws://213.171.27.44:8080';

  /// TURN-сервер для звонков через 4G/мобильный интернет.
  /// Установите coturn на сервере и укажите URL, username, credential.
  /// Пример: turn:213.171.27.44:3478
  static const String? turnUrl = null;
  static const String? turnUsername = null;
  static const String? turnCredential = null;
}
