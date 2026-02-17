#!/bin/bash
# =============================================================================
# deploy-mtproto.sh — Развертывание MTProto Proxy через Docker
# Использует официальный образ от Telegram (telegrammessenger/proxy)
# =============================================================================

set -euo pipefail

# --- Конфигурация ---
CONTAINER_NAME="mtproto-proxy"
PROXY_PORT=443                  # Порт, на котором будет слушать прокси (443 = маскировка под HTTPS)
STATS_PORT=2398                 # Внутренний порт статистики
DATA_DIR="/opt/mtproto-proxy"   # Директория для хранения данных

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "============================================"
echo "  Развертывание MTProto Proxy"
echo "============================================"

# --- Проверка Docker ---
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Ошибка: Docker не установлен. Сначала запустите setup-vps.sh${NC}"
    exit 1
fi

# --- Создание директории для данных ---
mkdir -p "$DATA_DIR"

# --- Остановка старого контейнера (если есть) ---
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo ""
    echo "Обнаружен существующий контейнер. Останавливаем..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
fi

# --- Получение секрета от MTProxybot ---
echo ""
echo -e "${YELLOW}ВАЖНО: Перед продолжением вы должны получить SECRET от @MTProxybot в Telegram.${NC}"
echo ""
echo "Инструкция:"
echo "  1. Откройте Telegram и найдите бота @MTProxybot"
echo "  2. Отправьте /newproxy"
echo "  3. Укажите IP вашего сервера и порт ${PROXY_PORT}"
echo "  4. Бот выдаст вам SECRET (секретный ключ)"
echo "  5. Через бота можно привязать промо-канал"
echo ""

read -p "Введите SECRET от @MTProxybot: " PROXY_SECRET

if [ -z "$PROXY_SECRET" ]; then
    echo -e "${RED}Ошибка: SECRET не может быть пустым!${NC}"
    exit 1
fi

# Сохраняем секрет для дальнейшего использования
echo "$PROXY_SECRET" > "$DATA_DIR/secret.txt"
chmod 600 "$DATA_DIR/secret.txt"

# --- Генерация Fake-TLS маскировки ---
echo ""
echo "Настройка Fake-TLS маскировки..."
echo ""
echo "Fake-TLS маскирует трафик прокси под обычный HTTPS."
echo "Нужно указать домен, под который маскироваться."
echo "Рекомендуемые домены: google.com, microsoft.com, cloudflare.com"
echo ""

read -p "Домен для маскировки [по умолчанию: google.com]: " FAKE_TLS_DOMAIN
FAKE_TLS_DOMAIN=${FAKE_TLS_DOMAIN:-google.com}

# Конвертируем домен в hex для Fake-TLS secret
DOMAIN_HEX=$(echo -n "$FAKE_TLS_DOMAIN" | xxd -p | tr -d '\n')
FAKE_TLS_SECRET="ee${PROXY_SECRET}${DOMAIN_HEX}"

echo ""
echo "Fake-TLS домен: $FAKE_TLS_DOMAIN"

# Сохраняем конфигурацию
cat > "$DATA_DIR/config.env" << EOF
PROXY_SECRET=${PROXY_SECRET}
PROXY_PORT=${PROXY_PORT}
FAKE_TLS_DOMAIN=${FAKE_TLS_DOMAIN}
FAKE_TLS_SECRET=${FAKE_TLS_SECRET}
EOF
chmod 600 "$DATA_DIR/config.env"

# --- Запуск контейнера ---
echo ""
echo "Запуск MTProto Proxy..."

docker pull telegrammessenger/proxy:latest

docker run -d \
    --name "$CONTAINER_NAME" \
    --restart always \
    -p "${PROXY_PORT}:443" \
    -v "${DATA_DIR}/data:/data" \
    -e SECRET="$PROXY_SECRET" \
    telegrammessenger/proxy:latest

# --- Проверка запуска ---
sleep 3

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  MTProto Proxy успешно запущен!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "ВАШ_IP")

    echo "Параметры подключения:"
    echo "  Сервер:  ${SERVER_IP}"
    echo "  Порт:    ${PROXY_PORT}"
    echo "  Секрет:  ${PROXY_SECRET}"
    echo ""
    echo "Ссылка для подключения (без Fake-TLS):"
    echo "  tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${PROXY_SECRET}"
    echo ""
    echo "Ссылка для подключения (с Fake-TLS, рекомендуется):"
    echo "  tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${FAKE_TLS_SECRET}"
    echo ""
    echo "Веб-ссылка (с Fake-TLS):"
    echo "  https://t.me/proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${FAKE_TLS_SECRET}"
    echo ""
    echo -e "${YELLOW}Сохраните эти данные! Они также записаны в ${DATA_DIR}/config.env${NC}"
    echo ""
    echo "Управление:"
    echo "  Логи:       docker logs ${CONTAINER_NAME}"
    echo "  Перезапуск: docker restart ${CONTAINER_NAME}"
    echo "  Стоп:       docker stop ${CONTAINER_NAME}"
else
    echo ""
    echo -e "${RED}Ошибка: Контейнер не запустился!${NC}"
    echo "Проверьте логи: docker logs ${CONTAINER_NAME}"
    exit 1
fi
