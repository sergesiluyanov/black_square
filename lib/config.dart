/// Конфигурация приложения
class Config {
  /// URL WebSocket сервера
  static const String serverUrl = 'ws://213.171.27.44:8080';

  /// TURN-сервер для звонков через 4G/мобильный интернет.
  /// Пароль должен совпадать с тем, что в /etc/turnserver.conf на сервере.
  static const String? turnUrl = 'turn:213.171.27.44:3478';
  static const String? turnUsername = 'blacksquare';
  static const String? turnCredential = 'BS_turn_9f0c4bfebe13e8f1';

  /// true = только через TURN (для 4G когда P2P не работает)
  static const bool turnRelayOnly = true;
}
