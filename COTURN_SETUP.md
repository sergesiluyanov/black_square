# TURN-сервер для звонков через 4G

Для звонков через мобильный интернет (4G) нужен TURN-сервер — он ретранслирует трафик, когда прямое P2P-соединение не устанавливается.

## Вариант 1: Публичный freeTURN (уже встроен)

В приложении уже используется публичный TURN `freeturn.net` (free/free). Он может работать нестабильно.

## Вариант 2: Свой coturn на сервере

1. Установите coturn на сервере (213.171.27.44):

```bash
# Ubuntu/Debian
sudo apt install coturn
sudo systemctl enable coturn
```

2. Настройте `/etc/turnserver.conf`:

```
listening-port=3478
fingerprint
lt-cred-mech
user=black_square:ВАШ_СЕКРЕТНЫЙ_ПАРОЛЬ
realm=213.171.27.44
```

3. Перезапустите: `sudo systemctl restart coturn`

4. Откройте порты 3478 (UDP/TCP) и 49152-65535 (UDP) в файрволе.

5. В `lib/config.dart` укажите:

```dart
static const String? turnUrl = 'turn:213.171.27.44:3478';
static const String? turnUsername = 'black_square';
static const String? turnCredential = 'ВАШ_СЕКРЕТНЫЙ_ПАРОЛЬ';
```

6. Пересоберите APK.
