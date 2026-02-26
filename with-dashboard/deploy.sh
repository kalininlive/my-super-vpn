#!/bin/bash
# =============================================================================
# deploy.sh — Развертывание MTProto Proxy + Grafana Dashboard
# Использует официальный образ от Telegram (telegrammessenger/proxy)
# с поддержкой TAG (промо-канал) и Fake-TLS маскировки.
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
echo "  MTProto Proxy + Dashboard"
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
echo -e "${CYAN}Шаг 1: Конфигурация MTProto Proxy${NC}"
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

read -p "Домен для Fake-TLS маскировки [google.com]: " FAKE_TLS_DOMAIN
FAKE_TLS_DOMAIN=${FAKE_TLS_DOMAIN:-google.com}

echo ""
echo -e "${CYAN}Шаг 2: Конфигурация Grafana (личный кабинет)${NC}"
echo ""

read -p "Порт Grafana [3000]: " GRAFANA_PORT
GRAFANA_PORT=${GRAFANA_PORT:-3000}

read -p "Логин Grafana [admin]: " GRAFANA_USER
GRAFANA_USER=${GRAFANA_USER:-admin}

read -sp "Пароль Grafana [admin]: " GRAFANA_PASSWORD
GRAFANA_PASSWORD=${GRAFANA_PASSWORD:-admin}
echo ""

# --- Генерация Fake-TLS секрета для ссылки ---
echo ""
echo "Генерация Fake-TLS секрета для ссылки..."

DOMAIN_HEX=$(echo -n "$FAKE_TLS_DOMAIN" | xxd -p | tr -d '\n')
FAKE_TLS_SECRET="ee${PROXY_SECRET}${DOMAIN_HEX}"

echo -e "${GREEN}Fake-TLS секрет: ${FAKE_TLS_SECRET}${NC}"

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
FAKE_TLS_DOMAIN=${FAKE_TLS_DOMAIN}
FAKE_TLS_SECRET=${FAKE_TLS_SECRET}
GRAFANA_PORT=${GRAFANA_PORT}
GRAFANA_USER=${GRAFANA_USER}
GRAFANA_PASSWORD=${GRAFANA_PASSWORD}
EOF
chmod 600 "$WORK_DIR/.env"

# --- Открываем порты в фаерволе ---
echo ""
echo "Настройка фаервола..."
ufw allow "${PROXY_PORT}/tcp" comment 'MTProto Proxy' 2>/dev/null || true
ufw allow "${GRAFANA_PORT}/tcp" comment 'Grafana Dashboard' 2>/dev/null || true
ufw reload 2>/dev/null || true

# --- Запуск ---
echo ""
echo "Запуск контейнеров..."
docker compose down 2>/dev/null || true
docker compose pull
docker compose up -d

# --- Ждем запуска ---
echo ""
echo "Ожидание запуска сервисов..."
sleep 10

# --- Проверка ---
ALL_OK=true

echo ""
echo "Проверка сервисов:"

if docker ps --format '{{.Names}}' | grep -q "mtproto-proxy"; then
    echo -e "  MTProto Proxy: ${GREEN}Работает${NC}"
else
    echo -e "  MTProto Proxy: ${RED}Не запущен!${NC}"
    ALL_OK=false
fi

if docker ps --format '{{.Names}}' | grep -q "node-exporter"; then
    echo -e "  Node Exporter: ${GREEN}Работает${NC}"
else
    echo -e "  Node Exporter: ${RED}Не запущен!${NC}"
    ALL_OK=false
fi

if docker ps --format '{{.Names}}' | grep -q "prometheus"; then
    echo -e "  Prometheus:    ${GREEN}Работает${NC}"
else
    echo -e "  Prometheus:    ${RED}Не запущен!${NC}"
    ALL_OK=false
fi

if docker ps --format '{{.Names}}' | grep -q "grafana"; then
    echo -e "  Grafana:       ${GREEN}Работает${NC}"
else
    echo -e "  Grafana:       ${RED}Не запущен!${NC}"
    ALL_OK=false
fi

# --- Вывод результатов ---
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "ВАШ_IP")

echo ""
if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Все сервисы успешно запущены!${NC}"
    echo -e "${GREEN}============================================${NC}"
else
    echo -e "${YELLOW}============================================${NC}"
    echo -e "${YELLOW}  Некоторые сервисы не запустились.${NC}"
    echo -e "${YELLOW}  Проверьте логи: docker compose logs${NC}"
    echo -e "${YELLOW}============================================${NC}"
fi

echo ""
echo -e "${CYAN}=== ЛИЧНЫЙ КАБИНЕТ (Grafana) ===${NC}"
echo ""
echo "  URL:    http://${SERVER_IP}:${GRAFANA_PORT}"
echo "  Логин:  ${GRAFANA_USER}"
echo "  Пароль: ${GRAFANA_PASSWORD}"
echo ""

echo -e "${CYAN}=== ССЫЛКИ ДЛЯ ПОЛЬЗОВАТЕЛЕЙ ===${NC}"
echo ""
echo "  Ссылка с Fake-TLS (рекомендуется):"
echo "  tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${FAKE_TLS_SECRET}"
echo ""
echo "  Веб-ссылка:"
echo "  https://t.me/proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${FAKE_TLS_SECRET}"
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
echo "  docker compose logs -f             # Логи всех сервисов"
echo "  docker compose logs mtproto-proxy  # Логи прокси"
echo "  docker compose restart             # Перезапуск"
echo "  docker compose down                # Остановка"
echo "  docker compose up -d               # Запуск"
echo ""
echo -e "${YELLOW}Конфигурация сохранена в: ${WORK_DIR}/.env${NC}"
echo ""
