#!/bin/bash
# =============================================================================
# deploy.sh — Развертывание MTProto Proxy
# Использует официальный образ от Telegram (telegrammessenger/proxy)
# с поддержкой TAG (промо-канал).
# Запускать от root на сервере, ПОСЛЕ выполнения setup-vps.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WORK_DIR="/opt/mtproto-dashboard"

echo "============================================"
echo "  MTProto Proxy"
echo "============================================"
echo ""

# --- Проверки ---
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker не установлен! Сначала запустите setup-vps.sh${NC}"
    exit 1
fi

if ! docker compose version &> /dev/null 2>&1; then
    echo "Установка Docker Compose plugin..."
    apt-get update && apt-get install -y docker-compose-plugin
fi

# --- Сбор конфигурации ---
echo -e "${CYAN}Конфигурация MTProto Proxy${NC}"
echo ""
echo "Перед продолжением зарегистрируйте прокси в @MTProxybot в Telegram."
echo ""
echo "  1. Откройте @MTProxybot"
echo "  2. Отправьте /newproxy"
echo "  3. Введите IP сервера и порт 443"
echo "  4. Бот попросит secret — сгенерируйте: openssl rand -hex 16"
echo "  5. Бот выдаст proxy tag — скопируйте его"
echo "  6. Через бота привяжите промо-канал (Promoted Channel)"
echo ""

read -p "Введите SECRET (32 hex-символа от @MTProxybot): " PROXY_SECRET
if [ -z "$PROXY_SECRET" ]; then
    echo -e "${RED}SECRET не может быть пустым!${NC}"
    exit 1
fi

read -p "Введите TAG (proxy tag от @MTProxybot): " PROXY_TAG
if [ -z "$PROXY_TAG" ]; then
    echo -e "${YELLOW}TAG не указан — промо-канал не будет работать.${NC}"
fi

read -p "Порт прокси [443]: " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-443}

# --- Создание рабочей директории ---
echo ""
echo "Создание рабочей директории: $WORK_DIR"
mkdir -p "$WORK_DIR"

# Копируем структуру
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp -r "$SCRIPT_DIR"/* "$WORK_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR"/.env "$WORK_DIR/" 2>/dev/null || true

cd "$WORK_DIR"

# --- Генерация .env ---
cat > "$WORK_DIR/.env" << EOF
PROXY_SECRET=${PROXY_SECRET}
PROXY_TAG=${PROXY_TAG}
PROXY_PORT=${PROXY_PORT}
EOF
chmod 600 "$WORK_DIR/.env"

# --- Открываем порты в фаерволе ---
echo ""
echo "Настройка фаервола..."
ufw allow "${PROXY_PORT}/tcp" comment 'MTProto Proxy' 2>/dev/null || true
ufw reload 2>/dev/null || true

# --- Запуск ---
echo ""
echo "Запуск контейнера..."
docker compose down 2>/dev/null || true
docker compose pull
docker compose up -d

# --- Ждем запуска ---
echo ""
echo "Ожидание запуска..."
sleep 5

# --- Проверка ---
echo ""
echo "Проверка сервиса:"

if docker ps --format '{{.Names}}' | grep -q "mtproto-proxy"; then
    echo -e "  MTProto Proxy: ${GREEN}Работает${NC}"
else
    echo -e "  MTProto Proxy: ${RED}Не запущен!${NC}"
    echo -e "  Проверьте логи: docker compose logs"
    exit 1
fi

# --- Определение IP ---
SERVER_IP=""
for svc in ifconfig.me icanhazip.com ipinfo.io/ip api.ipify.org ifconfig.co; do
    SERVER_IP=$(curl -s --max-time 3 "$svc" 2>/dev/null | tr -d '[:space:]')
    if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    SERVER_IP=""
done
SERVER_IP=${SERVER_IP:-ВАШ_IP}

# --- Вывод результатов ---
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  MTProto Proxy успешно запущен!${NC}"
echo -e "${GREEN}============================================${NC}"

echo ""
echo -e "${CYAN}=== ССЫЛКА ДЛЯ ПОЛЬЗОВАТЕЛЕЙ ===${NC}"
echo ""
echo "  tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${PROXY_SECRET}"
echo ""
echo "  Веб-ссылка:"
echo "  https://t.me/proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${PROXY_SECRET}"
echo ""

if [ -n "$PROXY_TAG" ]; then
    echo -e "${GREEN}  Промо-канал: TAG=${PROXY_TAG} (активен)${NC}"
else
    echo -e "${YELLOW}  Промо-канал: не настроен (TAG не указан)${NC}"
fi

echo ""
echo -e "${CYAN}=== УПРАВЛЕНИЕ ===${NC}"
echo ""
echo "  cd $WORK_DIR"
echo "  docker compose logs -f             # Логи прокси"
echo "  docker compose restart             # Перезапуск"
echo "  docker compose down                # Остановка"
echo "  docker compose up -d               # Запуск"
echo ""
echo -e "${YELLOW}Конфигурация сохранена в: ${WORK_DIR}/.env${NC}"
echo ""
