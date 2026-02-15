/// Конфигурация приложения
class Config {
  /// URL WebSocket сервера
  static const String serverUrl = 'ws://213.171.27.44:8080';

  /// TURN-сервер для звонков через 4G/мобильный интернет.
  /// Пароль должен совпадать с тем, что в /etc/turnserver.conf на сервере.
  static const String? turnUrl = 'turn:213.171.27.44:3478';
  static const String? turnUsername = 'blacksquare';
  static const String? turnCredential = 'CHANGE_ME'; // Замените после настройки coturn
}
