#!/bin/bash
# =============================================================================
# manage.sh — Управление MTProto Proxy
# Использование: ./manage.sh [команда]
# =============================================================================

set -euo pipefail

CONTAINER_NAME="mtproto-proxy"
DATA_DIR="/opt/mtproto-proxy"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Функции ---

show_help() {
    echo "============================================"
    echo "  MTProto Proxy — Управление"
    echo "============================================"
    echo ""
    echo "Использование: $0 [команда]"
    echo ""
    echo "Команды:"
    echo "  status      Показать статус прокси"
    echo "  start       Запустить прокси"
    echo "  stop        Остановить прокси"
    echo "  restart     Перезапустить прокси"
    echo "  logs        Показать логи"
    echo "  info        Показать параметры подключения"
    echo "  update      Обновить Docker-образ"
    echo "  newsecret   Сменить секрет (нужен новый от @MTProxybot)"
    echo "  migrate     Переехать на новый IP (после блокировки РКН)"
    echo "  uninstall   Полностью удалить прокси"
    echo ""
}

check_status() {
    echo -e "${CYAN}Статус MTProto Proxy:${NC}"
    echo ""
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "  Состояние: ${GREEN}Работает${NC}"
        echo "  Uptime:    $(docker ps --format '{{.Status}}' --filter name=${CONTAINER_NAME})"
        echo "  Порты:     $(docker ps --format '{{.Ports}}' --filter name=${CONTAINER_NAME})"

        # Показать использование ресурсов
        echo ""
        echo "Ресурсы:"
        docker stats --no-stream --format "  CPU: {{.CPUPerc}}  RAM: {{.MemUsage}}" "$CONTAINER_NAME"
    else
        echo -e "  Состояние: ${RED}Остановлен${NC}"
    fi
}

start_proxy() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${YELLOW}Прокси уже запущен.${NC}"
    else
        echo "Запускаем прокси..."
        docker start "$CONTAINER_NAME"
        sleep 2
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo -e "${GREEN}Прокси запущен!${NC}"
        else
            echo -e "${RED}Ошибка запуска. Проверьте логи: $0 logs${NC}"
        fi
    fi
}

stop_proxy() {
    echo "Останавливаем прокси..."
    docker stop "$CONTAINER_NAME"
    echo -e "${GREEN}Прокси остановлен.${NC}"
}

restart_proxy() {
    echo "Перезапускаем прокси..."
    docker restart "$CONTAINER_NAME"
    sleep 2
    echo -e "${GREEN}Прокси перезапущен.${NC}"
}

show_logs() {
    echo "Последние 50 строк логов (Ctrl+C для выхода из режима -f):"
    echo ""
    docker logs --tail 50 -f "$CONTAINER_NAME"
}

show_info() {
    if [ ! -f "$DATA_DIR/config.env" ]; then
        echo -e "${RED}Конфигурация не найдена. Сначала запустите deploy-mtproto.sh${NC}"
        exit 1
    fi

    source "$DATA_DIR/config.env"

    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "ВАШ_IP")

    echo "============================================"
    echo "  Параметры подключения"
    echo "============================================"
    echo ""
    echo "  Сервер:       ${SERVER_IP}"
    echo "  Порт:         ${PROXY_PORT}"
    echo "  Секрет:       ${PROXY_SECRET}"
    if [ -n "${PROXY_TAG:-}" ]; then
        echo "  TAG:          ${PROXY_TAG}"
    fi
    echo "  Fake-TLS:     ${FAKE_TLS_DOMAIN}"
    echo ""
    echo "Ссылка с Fake-TLS (рекомендуется):"
    echo ""
    echo "  tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${FAKE_TLS_SECRET}"
    echo ""
    echo "  https://t.me/proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${FAKE_TLS_SECRET}"
    echo ""
}

update_image() {
    echo "Обновляем Docker-образ..."
    docker pull telegrammessenger/proxy:latest

    if [ ! -f "$DATA_DIR/config.env" ]; then
        echo -e "${RED}Конфигурация не найдена!${NC}"
        exit 1
    fi

    source "$DATA_DIR/config.env"

    echo "Пересоздаем контейнер..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true

    DOCKER_ARGS=(
        -d
        --name "$CONTAINER_NAME"
        --restart always
        -p "${PROXY_PORT}:443"
        -v "${DATA_DIR}/data:/data"
        -e "SECRET=$PROXY_SECRET"
    )

    if [ -n "${PROXY_TAG:-}" ]; then
        DOCKER_ARGS+=(-e "TAG=$PROXY_TAG")
    fi

    docker run "${DOCKER_ARGS[@]}" telegrammessenger/proxy:latest

    sleep 2
    echo -e "${GREEN}Обновление завершено!${NC}"
    check_status
}

new_secret() {
    echo -e "${YELLOW}Смена секрета MTProto Proxy${NC}"
    echo ""
    echo "1. Откройте @MTProxybot в Telegram"
    echo "2. Получите новый SECRET для вашего прокси"
    echo ""

    read -p "Введите новый SECRET: " NEW_SECRET

    if [ -z "$NEW_SECRET" ]; then
        echo -e "${RED}SECRET не может быть пустым!${NC}"
        exit 1
    fi

    read -p "Введите TAG (proxy tag, Enter чтобы оставить прежний): " NEW_TAG

    read -p "Домен для Fake-TLS [google.com]: " NEW_DOMAIN
    NEW_DOMAIN=${NEW_DOMAIN:-google.com}

    DOMAIN_HEX=$(echo -n "$NEW_DOMAIN" | xxd -p | tr -d '\n')
    NEW_FAKE_SECRET="ee${NEW_SECRET}${DOMAIN_HEX}"

    # Читаем старый конфиг для значений по умолчанию
    source "$DATA_DIR/config.env" 2>/dev/null || true
    NEW_TAG="${NEW_TAG:-${PROXY_TAG:-}}"

    # Обновляем конфиг
    cat > "$DATA_DIR/config.env" << EOF
PROXY_SECRET=${NEW_SECRET}
PROXY_TAG=${NEW_TAG}
PROXY_PORT=${PROXY_PORT:-443}
FAKE_TLS_DOMAIN=${NEW_DOMAIN}
FAKE_TLS_SECRET=${NEW_FAKE_SECRET}
EOF
    chmod 600 "$DATA_DIR/config.env"
    echo "$NEW_SECRET" > "$DATA_DIR/secret.txt"
    chmod 600 "$DATA_DIR/secret.txt"

    # Пересоздаем контейнер с новым секретом
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true

    DOCKER_ARGS=(
        -d
        --name "$CONTAINER_NAME"
        --restart always
        -p "${PROXY_PORT:-443}:443"
        -v "${DATA_DIR}/data:/data"
        -e "SECRET=$NEW_SECRET"
    )

    if [ -n "${NEW_TAG:-}" ]; then
        DOCKER_ARGS+=(-e "TAG=$NEW_TAG")
    fi

    docker run "${DOCKER_ARGS[@]}" telegrammessenger/proxy:latest

    sleep 2
    echo ""
    echo -e "${GREEN}Секрет обновлен! Новые ссылки:${NC}"
    show_info
}

migrate_server() {
    echo "============================================"
    echo "  Миграция на новый сервер"
    echo "============================================"
    echo ""
    echo "Когда РКН заблокирует IP вашего сервера, вам нужно:"
    echo ""
    echo "  1. Арендовать новый VPS"
    echo "  2. На новом сервере:"
    echo "     git clone https://github.com/kalininlive/my-super-vpn.git"
    echo "     cd my-super-vpn"
    echo "     chmod +x setup-vps.sh && ./setup-vps.sh"
    echo "     chmod +x with-dashboard/deploy.sh && cd with-dashboard && ./deploy.sh"
    echo ""
    echo "  3. В @MTProxybot обновить IP прокси на новый"
    echo ""
    echo "  4. Если есть домен — обновить A-запись на новый IP"
    echo "     Тогда пользователям не нужна новая ссылка!"
    echo ""
    echo -e "${YELLOW}Совет: используйте домен, чтобы при смене IP не раздавать новые ссылки.${NC}"
}

uninstall_proxy() {
    echo -e "${RED}ВНИМАНИЕ: Это полностью удалит MTProto Proxy!${NC}"
    read -p "Вы уверены? (yes/no): " CONFIRM

    if [ "$CONFIRM" = "yes" ]; then
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
        docker rmi telegrammessenger/proxy:latest 2>/dev/null || true
        rm -rf "$DATA_DIR"
        echo -e "${GREEN}MTProto Proxy полностью удален.${NC}"
    else
        echo "Отменено."
    fi
}

# --- Главное меню ---

case "${1:-}" in
    status)     check_status ;;
    start)      start_proxy ;;
    stop)       stop_proxy ;;
    restart)    restart_proxy ;;
    logs)       show_logs ;;
    info)       show_info ;;
    update)     update_image ;;
    newsecret)  new_secret ;;
    migrate)    migrate_server ;;
    uninstall)  uninstall_proxy ;;
    *)          show_help ;;
esac
