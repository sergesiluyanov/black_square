#!/bin/bash
# Установка coturn на сервере для WebRTC (звонки через 4G)
# Запуск на сервере: sudo bash coturn-setup.sh

set -e

TURN_USER="blacksquare"
TURN_PASS="BS_turn_$(openssl rand -hex 8)"
SERVER_IP="213.171.27.44"

echo "=== Установка coturn ==="
apt-get update
apt-get install -y coturn

echo "=== Настройка /etc/turnserver.conf ==="
cat > /etc/turnserver.conf << EOF
listening-port=3478
tls-listening-port=5349
fingerprint
lt-cred-mech
user=${TURN_USER}:${TURN_PASS}
realm=${SERVER_IP}
no-multicast-peers
no-cli
EOF

echo "=== Включение coturn ==="
if [ -f /etc/default/coturn ]; then
  sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || true
fi
systemctl enable coturn
systemctl restart coturn

echo "=== Проверка ==="
systemctl status coturn --no-pager

echo ""
echo "=========================================="
echo "ГОТОВО! Скопируйте в lib/config.dart:"
echo "  turnCredential = '${TURN_PASS}';"
echo "=========================================="
echo ""
echo "Откройте порты в файрволе: 3478 (UDP/TCP), 5349 (TLS), 49152-65535 (UDP relay)"
