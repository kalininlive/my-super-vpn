#!/bin/bash
# =============================================================================
# monitor-bot.sh — Telegram-бот для мониторинга и управления MTProto Proxy
#
# Функции:
#   /status   — статус всех сервисов
#   /restart  — перезапуск прокси
#   /restartall — перезапуск всех сервисов
#   /logs     — последние логи
#   /traffic  — статистика трафика
#   /ip       — показать IP сервера
#   /help     — список команд
#
# Автоматические уведомления:
#   - Прокси упал → уведомление
#   - Прокси восстановился → уведомление
#   - Высокая нагрузка CPU/RAM → предупреждение
# =============================================================================

set -euo pipefail

# --- Конфигурация (заполняется при установке) ---
BOT_TOKEN="${BOT_TOKEN:-}"
ADMIN_CHAT_ID="${ADMIN_CHAT_ID:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"  # Секунды между проверками

# --- Файл конфигурации прокси ---
PROXY_ENV="/opt/mtproto-dashboard/.env"

# --- Файл состояния ---
STATE_FILE="/tmp/mtproto-monitor-state"
LOCK_FILE="/tmp/mtproto-monitor.lock"

# --- Цвета для логов ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# --- Проверка конфигурации ---
if [ -z "$BOT_TOKEN" ] || [ -z "$ADMIN_CHAT_ID" ]; then
    echo "Ошибка: BOT_TOKEN и ADMIN_CHAT_ID должны быть заданы!"
    echo "Использование: BOT_TOKEN=xxx ADMIN_CHAT_ID=yyy ./monitor-bot.sh"
    exit 1
fi

# --- Telegram API ---
API_URL="https://api.telegram.org/bot${BOT_TOKEN}"
LAST_UPDATE_ID=0

send_message() {
    local chat_id="$1"
    local text="$2"
    local parse_mode="${3:-Markdown}"

    curl -s -X POST "${API_URL}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${text}" \
        -d "parse_mode=${parse_mode}" \
        -d "disable_web_page_preview=true" \
        > /dev/null 2>&1
}

get_updates() {
    curl -s -X POST "${API_URL}/getUpdates" \
        -d "offset=${LAST_UPDATE_ID}" \
        -d "timeout=5" \
        -d "allowed_updates=[\"message\"]" \
        2>/dev/null
}

# --- Функции проверки ---

check_container() {
    local name="$1"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        echo "up"
    else
        echo "down"
    fi
}

get_container_uptime() {
    local name="$1"
    docker ps --format '{{.Status}}' --filter "name=^${name}$" 2>/dev/null || echo "N/A"
}

get_cpu_usage() {
    top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1 2>/dev/null || echo "0"
}

get_ram_usage() {
    free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}' 2>/dev/null || echo "0"
}

get_disk_usage() {
    df / | tail -1 | awk '{print $5}' | tr -d '%' 2>/dev/null || echo "0"
}

# --- Чтение конфигурации прокси ---
get_proxy_link() {
    if [ -f "$PROXY_ENV" ]; then
        local secret domain domain_hex fake_tls_secret
        secret=$(grep '^PROXY_SECRET=' "$PROXY_ENV" 2>/dev/null | cut -d= -f2 || echo "")
        domain=$(grep '^FAKE_TLS_DOMAIN=' "$PROXY_ENV" 2>/dev/null | cut -d= -f2 || echo "google.com")
        fake_tls_secret=$(grep '^FAKE_TLS_SECRET=' "$PROXY_ENV" 2>/dev/null | cut -d= -f2 || echo "")

        if [ -z "$fake_tls_secret" ] && [ -n "$secret" ]; then
            domain_hex=$(echo -n "${domain:-google.com}" | xxd -p | tr -d '\n')
            fake_tls_secret="ee${secret}${domain_hex}"
        fi

        echo "$fake_tls_secret"
    else
        echo ""
    fi
}

get_proxy_port() {
    if [ -f "$PROXY_ENV" ]; then
        grep '^PROXY_PORT=' "$PROXY_ENV" 2>/dev/null | cut -d= -f2 || echo "443"
    else
        echo "443"
    fi
}

# --- Обработчики команд ---

cmd_status() {
    local chat_id="$1"

    local proxy_status=$(check_container "mtproto-proxy")
    local prometheus_status=$(check_container "prometheus")
    local grafana_status=$(check_container "grafana")
    local exporter_status=$(check_container "node-exporter")

    local proxy_icon="🔴"
    local prom_icon="🔴"
    local graf_icon="🔴"
    local exp_icon="🔴"
    [ "$proxy_status" = "up" ] && proxy_icon="🟢"
    [ "$prometheus_status" = "up" ] && prom_icon="🟢"
    [ "$grafana_status" = "up" ] && graf_icon="🟢"
    [ "$exporter_status" = "up" ] && exp_icon="🟢"

    local proxy_uptime=$(get_container_uptime "mtproto-proxy")
    local cpu=$(get_cpu_usage)
    local ram=$(get_ram_usage)
    local disk=$(get_disk_usage)

    local server_ip
    server_ip=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "N/A")

    local msg="*📊 Статус сервера*

${proxy_icon} MTProto Proxy: \`${proxy_status}\`
${prom_icon} Prometheus: \`${prometheus_status}\`
${graf_icon} Grafana: \`${grafana_status}\`
${exp_icon} Node Exporter: \`${exporter_status}\`

⏱ Uptime прокси: \`${proxy_uptime}\`

💻 *Ресурсы:*
CPU: \`${cpu}%\`
RAM: \`${ram}%\`
Disk: \`${disk}%\`

🌐 IP: \`${server_ip}\`"

    send_message "$chat_id" "$msg"
}

cmd_restart() {
    local chat_id="$1"

    send_message "$chat_id" "🔄 *Перезапуск прокси...*"

    cd /opt/mtproto-dashboard
    docker compose restart mtproto-proxy 2>&1

    sleep 3

    local status=$(check_container "mtproto-proxy")
    if [ "$status" = "up" ]; then
        send_message "$chat_id" "✅ *Прокси перезапущен!*"
    else
        send_message "$chat_id" "❌ *Ошибка! Прокси не запустился.*
Проверьте логи: /logs"
    fi
}

cmd_restart_all() {
    local chat_id="$1"

    send_message "$chat_id" "🔄 *Перезапуск всех сервисов...*"

    cd /opt/mtproto-dashboard
    docker compose down 2>&1
    docker compose up -d 2>&1

    sleep 5

    cmd_status "$chat_id"
}

cmd_logs() {
    local chat_id="$1"

    local logs
    logs=$(cd /opt/mtproto-dashboard && docker compose logs --tail 15 mtproto-proxy 2>&1 | tail -15 | sed 's/[`]/\\`/g')

    if [ -z "$logs" ]; then
        logs="Логи пусты"
    fi

    # Обрезаем если слишком длинные
    if [ ${#logs} -gt 3500 ]; then
        logs="${logs:0:3500}..."
    fi

    send_message "$chat_id" "📋 *Последние логи:*

\`\`\`
${logs}
\`\`\`" "Markdown"
}

cmd_traffic() {
    local chat_id="$1"

    # Получаем статистику из docker stats
    local stats
    stats=$(docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}" mtproto-proxy 2>/dev/null || echo "")

    if [ -z "$stats" ]; then
        send_message "$chat_id" "⚠️ Статистика недоступна. Контейнер прокси не запущен."
        return
    fi

    local cpu_perc mem_usage net_io
    cpu_perc=$(echo "$stats" | cut -d'|' -f1)
    mem_usage=$(echo "$stats" | cut -d'|' -f2)
    net_io=$(echo "$stats" | cut -d'|' -f3)

    local net_in net_out
    net_in=$(echo "$net_io" | cut -d'/' -f1 | xargs)
    net_out=$(echo "$net_io" | cut -d'/' -f2 | xargs)

    # Системная статистика
    local sys_cpu=$(get_cpu_usage)
    local sys_ram=$(get_ram_usage)
    local sys_disk=$(get_disk_usage)

    send_message "$chat_id" "*📈 Статистика*

*Прокси-контейнер:*
CPU: \`${cpu_perc}\`
RAM: \`${mem_usage}\`
Трафик вход: \`${net_in}\`
Трафик выход: \`${net_out}\`

*Сервер:*
CPU: \`${sys_cpu}%\`
RAM: \`${sys_ram}%\`
Disk: \`${sys_disk}%\`"
}

cmd_ip() {
    local chat_id="$1"

    local server_ip
    server_ip=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "N/A")

    local proxy_port=$(get_proxy_port)
    local fake_tls_secret=$(get_proxy_link)

    local proxy_link
    if [ -n "$fake_tls_secret" ]; then
        proxy_link="tg://proxy?server=${server_ip}&port=${proxy_port}&secret=${fake_tls_secret}"
    else
        local plain_secret=""
        if [ -f "$PROXY_ENV" ]; then
            plain_secret=$(grep '^PROXY_SECRET=' "$PROXY_ENV" 2>/dev/null | cut -d= -f2 || echo "")
        fi
        proxy_link="tg://proxy?server=${server_ip}&port=${proxy_port}&secret=${plain_secret}"
    fi

    curl -s -X POST "${API_URL}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=IP сервера: ${server_ip}

Ссылка прокси:
${proxy_link}" \
        > /dev/null 2>&1
}

cmd_help() {
    local chat_id="$1"

    send_message "$chat_id" "*🤖 Команды бота:*

/status — Статус всех сервисов
/restart — Перезапуск прокси
/restartall — Перезапуск всех сервисов
/logs — Последние логи прокси
/traffic — Статистика трафика
/ip — IP и ссылка прокси
/help — Эта справка

*Автоматические уведомления:*
⚠️ Прокси упал
✅ Прокси восстановился
🔥 Высокая нагрузка (CPU > 80%, RAM > 90%)"
}

# --- Обработка входящих сообщений ---

process_updates() {
    local response
    response=$(get_updates)

    if [ -z "$response" ]; then
        return
    fi

    local results
    results=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for r in data.get('result', []):
        uid = r['update_id']
        msg = r.get('message', {})
        chat_id = msg.get('chat', {}).get('id', '')
        text = msg.get('text', '')
        print(f'{uid}|{chat_id}|{text}')
except:
    pass
" 2>/dev/null || echo "")

    if [ -z "$results" ]; then
        return
    fi

    while IFS='|' read -r update_id chat_id text; do
        LAST_UPDATE_ID=$((update_id + 1))

        # Проверяем что сообщение от админа
        if [ "$chat_id" != "$ADMIN_CHAT_ID" ]; then
            send_message "$chat_id" "⛔ Доступ запрещен."
            continue
        fi

        case "$text" in
            /status)     cmd_status "$chat_id" ;;
            /restart)    cmd_restart "$chat_id" ;;
            /restartall) cmd_restart_all "$chat_id" ;;
            /logs)       cmd_logs "$chat_id" ;;
            /traffic)    cmd_traffic "$chat_id" ;;
            /ip)         cmd_ip "$chat_id" ;;
            /help|/start) cmd_help "$chat_id" ;;
            *)           send_message "$chat_id" "Неизвестная команда. /help" ;;
        esac
    done <<< "$results"
}

# --- Автоматический мониторинг ---

PREV_PROXY_STATE="unknown"

auto_monitor() {
    local proxy_status=$(check_container "mtproto-proxy")
    local cpu=$(get_cpu_usage)
    local ram=$(get_ram_usage)

    # Проверка состояния прокси
    if [ "$proxy_status" = "down" ] && [ "$PREV_PROXY_STATE" != "down" ]; then
        send_message "$ADMIN_CHAT_ID" "🚨 *ВНИМАНИЕ: MTProto Proxy упал!*

Прокси-сервер перестал работать.

Используйте /restart для перезапуска или /logs для диагностики."
        PREV_PROXY_STATE="down"
    elif [ "$proxy_status" = "up" ] && [ "$PREV_PROXY_STATE" = "down" ]; then
        send_message "$ADMIN_CHAT_ID" "✅ *MTProto Proxy восстановлен!*

Прокси снова работает."
        PREV_PROXY_STATE="up"
    else
        PREV_PROXY_STATE="$proxy_status"
    fi

    # Проверка нагрузки
    if [ "$cpu" -gt 80 ] 2>/dev/null; then
        send_message "$ADMIN_CHAT_ID" "🔥 *Высокая нагрузка CPU: ${cpu}%*"
    fi

    if [ "$ram" -gt 90 ] 2>/dev/null; then
        send_message "$ADMIN_CHAT_ID" "🔥 *Высокая нагрузка RAM: ${ram}%*"
    fi
}

# --- Главный цикл ---

log "Бот запущен. Token: ${BOT_TOKEN:0:10}... Chat ID: ${ADMIN_CHAT_ID}"
send_message "$ADMIN_CHAT_ID" "🤖 *Бот мониторинга запущен!*

Отправьте /help для списка команд."

MONITOR_COUNTER=0

while true; do
    # Обработка команд
    process_updates

    # Автомониторинг каждые CHECK_INTERVAL секунд
    MONITOR_COUNTER=$((MONITOR_COUNTER + 5))
    if [ "$MONITOR_COUNTER" -ge "$CHECK_INTERVAL" ]; then
        auto_monitor
        MONITOR_COUNTER=0
    fi

    sleep 5
done
