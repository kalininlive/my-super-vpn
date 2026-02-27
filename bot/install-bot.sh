#!/bin/bash
# =============================================================================
# install-bot.sh — Установка Telegram-бота мониторинга
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BOT_DIR="/opt/mtproto-bot"
SERVICE_NAME="mtproto-monitor-bot"

echo "============================================"
echo "  Установка Telegram-бота мониторинга"
echo "============================================"
echo ""

# --- Сбор данных ---
echo -e "${CYAN}Шаг 1: Создание бота в Telegram${NC}"
echo ""
echo "1. Откройте @BotFather в Telegram"
echo "2. Отправьте /newbot"
echo "3. Придумайте имя бота (например: МойПрокси Мониторинг)"
echo "4. Придумайте username бота (например: myproxy_monitor_bot)"
echo "5. Скопируйте токен, который выдаст BotFather"
echo ""

read -p "Вставьте BOT TOKEN: " BOT_TOKEN
if [ -z "$BOT_TOKEN" ]; then
    echo -e "${RED}Токен не может быть пустым!${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}Шаг 2: Получение Chat ID${NC}"
echo ""
echo "1. Откройте вашего нового бота в Telegram"
echo "2. Отправьте ему любое сообщение (например: /start)"
echo "3. Нажмите Enter когда отправите..."
echo ""

read -p "Нажмите Enter после отправки сообщения боту..."

# Получаем chat_id из последнего сообщения
echo "Получаю Chat ID..."
CHAT_RESPONSE=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null)

ADMIN_CHAT_ID=$(echo "$CHAT_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('result', [])
    if results:
        print(results[-1]['message']['chat']['id'])
except:
    pass
" 2>/dev/null || echo "")

if [ -z "$ADMIN_CHAT_ID" ]; then
    echo -e "${YELLOW}Не удалось автоматически получить Chat ID.${NC}"
    echo "Вы можете узнать его через @userinfobot в Telegram."
    read -p "Введите Chat ID вручную: " ADMIN_CHAT_ID
fi

if [ -z "$ADMIN_CHAT_ID" ]; then
    echo -e "${RED}Chat ID не может быть пустым!${NC}"
    exit 1
fi

echo -e "${GREEN}Chat ID: ${ADMIN_CHAT_ID}${NC}"

echo ""
read -p "Интервал проверки в секундах [30]: " CHECK_INTERVAL
CHECK_INTERVAL=${CHECK_INTERVAL:-30}

# --- Доп. серверы ---
echo ""
echo -e "${CYAN}Шаг 4: Мониторинг дополнительных серверов (опционально)${NC}"
echo ""
echo "Если у вас несколько серверов прокси, бот будет следить за ними."
echo "Формат: Имя:IP:Порт (через запятую для нескольких)"
echo "Пример: Backup:1.2.3.4:443,EU:5.6.7.8:443"
echo ""

read -p "Доп. серверы (Enter чтобы пропустить): " EXTRA_SERVERS
EXTRA_SERVERS=${EXTRA_SERVERS:-}

# --- Установка зависимостей ---
echo ""
echo "Установка зависимостей..."
apt-get install -y qrencode > /dev/null 2>&1 || echo -e "${YELLOW}qrencode не установлен — /qr будет недоступен${NC}"

# --- Установка ---
echo ""
echo "Установка бота..."

mkdir -p "$BOT_DIR"

# Копируем скрипт
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/monitor-bot.sh" "$BOT_DIR/monitor-bot.sh"
chmod +x "$BOT_DIR/monitor-bot.sh"

# Сохраняем конфигурацию
cat > "$BOT_DIR/.env" << EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_CHAT_ID=${ADMIN_CHAT_ID}
CHECK_INTERVAL=${CHECK_INTERVAL}
EXTRA_SERVERS=${EXTRA_SERVERS}
EOF
chmod 600 "$BOT_DIR/.env"

# --- Создание systemd-сервиса ---
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=MTProto Proxy Monitor Telegram Bot
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
EnvironmentFile=${BOT_DIR}/.env
ExecStart=/bin/bash ${BOT_DIR}/monitor-bot.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

# --- Запуск ---
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

sleep 3

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Бот успешно установлен и запущен!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "Откройте бота в Telegram и отправьте /help"
    echo ""
    echo "Управление ботом:"
    echo "  systemctl status ${SERVICE_NAME}    # Статус"
    echo "  systemctl restart ${SERVICE_NAME}   # Перезапуск"
    echo "  systemctl stop ${SERVICE_NAME}      # Остановка"
    echo "  journalctl -u ${SERVICE_NAME} -f    # Логи бота"
    echo ""
    echo -e "${YELLOW}Конфигурация: ${BOT_DIR}/.env${NC}"
else
    echo ""
    echo -e "${RED}Ошибка! Бот не запустился.${NC}"
    echo "Проверьте логи: journalctl -u ${SERVICE_NAME} -n 20"
fi
