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
#   /ping     — проверка доступности прокси
#   /qr       — QR-код со ссылкой прокси
#   /servers  — статус всех серверов (мульти-сервер)
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
EXTRA_SERVERS="${EXTRA_SERVERS:-}"      # Доп. серверы: "Имя1:ip1:port1,Имя2:ip2:port2"
POLAND_IP="${POLAND_IP:-}"             # IP сервера Польша
POLAND_SSH_KEY="${POLAND_SSH_KEY:-}"   # Путь к SSH-ключу для Польши

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

send_photo() {
    local chat_id="$1"
    local photo_path="$2"
    local caption="${3:-}"

    curl -s -X POST "${API_URL}/sendPhoto" \
        -F "chat_id=${chat_id}" \
        -F "photo=@${photo_path}" \
        -F "caption=${caption}" \
        -F "parse_mode=Markdown" \
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

get_connections() {
    local container_id
    container_id=$(docker ps -q --filter name=mtproto 2>/dev/null | head -1)
    if [ -n "$container_id" ]; then
        docker exec "$container_id" ss -tn 2>/dev/null | grep -c ESTAB || echo "0"
    else
        echo "0"
    fi
}

get_remote_connections() {
    local ip="$1"
    local key="$2"
    if [ -z "$ip" ] || [ -z "$key" ]; then echo "N/A"; return; fi
    ssh -i "$key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        root@"$ip" \
        'docker exec $(docker ps -q --filter name=mtproto) ss -tn 2>/dev/null | grep -c ESTAB || echo 0' \
        2>/dev/null || echo "N/A"
}

get_server_ip() {
    local ip=""
    # Пробуем несколько сервисов определения IP
    for svc in "ifconfig.me" "icanhazip.com" "ipinfo.io/ip" "api.ipify.org" "ifconfig.co"; do
        ip=$(curl -s --max-time 3 "$svc" 2>/dev/null | tr -d '[:space:]')
        # Проверяем что результат — валидный IPv4
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    echo "N/A"
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

    local cpu=$(get_cpu_usage)
    local ram=$(get_ram_usage)
    local disk=$(get_disk_usage)
    local proxy_uptime=$(get_container_uptime "mtproto-proxy")

    local msg="*📊 Статус серверов*
"
    # Локальный сервер
    local local_ip
    local_ip=$(get_server_ip)
    local local_port=$(get_proxy_port)
    local local_status=$(check_container "mtproto-proxy")
    local local_conns=$(get_connections)

    local local_icon="🔴"
    local local_latency=""
    if [ "$local_status" = "up" ]; then
        local_icon="🟢"
        local start_time end_time
        start_time=$(date +%s%N)
        if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${local_port}" 2>/dev/null; then
            end_time=$(date +%s%N)
            local_latency=" ($(( (end_time - start_time) / 1000000 )) ms)"
        fi
    fi

    msg="${msg}
${local_icon} *Main* — \`${local_ip}:${local_port}\`${local_latency} 👥 \`${local_conns}\`"

    # Дополнительные серверы
    if [ -n "$EXTRA_SERVERS" ]; then
        IFS=',' read -ra SERVERS <<< "$EXTRA_SERVERS"
        for server_entry in "${SERVERS[@]}"; do
            local srv_name srv_ip srv_port
            IFS=':' read -r srv_name srv_ip srv_port <<< "$server_entry"
            srv_port=${srv_port:-443}

            local srv_icon="🔴"
            local srv_latency=""
            local srv_conns="N/A"

            local start_time end_time
            start_time=$(date +%s%N)
            if timeout 3 bash -c "echo > /dev/tcp/${srv_ip}/${srv_port}" 2>/dev/null; then
                end_time=$(date +%s%N)
                srv_latency=" ($(( (end_time - start_time) / 1000000 )) ms)"
                srv_icon="🟢"
            fi

            if [ -n "$POLAND_IP" ] && [ "$srv_ip" = "$POLAND_IP" ] && [ -n "$POLAND_SSH_KEY" ]; then
                srv_conns=$(get_remote_connections "$srv_ip" "$POLAND_SSH_KEY")
            fi

            msg="${msg}
${srv_icon} *${srv_name}* — \`${srv_ip}:${srv_port}\`${srv_latency} 👥 \`${srv_conns}\`"
        done
    fi

    msg="${msg}

💻 *Ресурсы (Main):*
CPU: \`${cpu}%\`
RAM: \`${ram}%\`
Disk: \`${disk}%\`
⏱ Uptime: \`${proxy_uptime}\`"

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
    server_ip=$(get_server_ip)

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

cmd_ping() {
    local chat_id="$1"

    local proxy_status=$(check_container "mtproto-proxy")
    if [ "$proxy_status" != "up" ]; then
        send_message "$chat_id" "🔴 *Прокси не запущен!*"
        return
    fi

    local proxy_port=$(get_proxy_port)

    # Измеряем TCP-соединение к прокси
    local start_time end_time latency
    start_time=$(date +%s%N)
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${proxy_port}" 2>/dev/null; then
        end_time=$(date +%s%N)
        latency=$(( (end_time - start_time) / 1000000 ))
        local port_status="🟢 Порт ${proxy_port}: открыт (${latency} ms)"
    else
        local port_status="🔴 Порт ${proxy_port}: не отвечает"
    fi

    # Проверяем DNS домена
    local dns_status=""
    if [ -f "$PROXY_ENV" ]; then
        local domain
        domain=$(grep '^PROXY_DOMAIN=' "$PROXY_ENV" 2>/dev/null | cut -d= -f2 || echo "")
        if [ -n "$domain" ]; then
            local resolved
            resolved=$(dig +short "$domain" 2>/dev/null | head -1)
            if [ -n "$resolved" ]; then
                dns_status="
🟢 DNS ${domain}: \`${resolved}\`"
            else
                dns_status="
🔴 DNS ${domain}: не резолвится"
            fi
        fi
    fi

    # Проверяем доступность Telegram API
    local tg_start tg_end tg_latency tg_status
    tg_start=$(date +%s%N)
    if curl -s --max-time 3 -o /dev/null https://core.telegram.org 2>/dev/null; then
        tg_end=$(date +%s%N)
        tg_latency=$(( (tg_end - tg_start) / 1000000 ))
        tg_status="🟢 Telegram API: доступен (${tg_latency} ms)"
    else
        tg_status="🔴 Telegram API: недоступен"
    fi

    send_message "$chat_id" "*🏓 Ping*

${port_status}
${tg_status}${dns_status}

Контейнер: \`$(get_container_uptime "mtproto-proxy")\`"
}

cmd_qr() {
    local chat_id="$1"

    # Проверяем qrencode
    if ! command -v qrencode &> /dev/null; then
        send_message "$chat_id" "⚠️ \`qrencode\` не установлен. Выполните: \`apt install qrencode\`"
        return
    fi

    local server_ip
    server_ip=$(get_server_ip)

    local proxy_port=$(get_proxy_port)
    local plain_secret=""
    if [ -f "$PROXY_ENV" ]; then
        plain_secret=$(grep '^PROXY_SECRET=' "$PROXY_ENV" 2>/dev/null | cut -d= -f2 || echo "")
    fi

    if [ -z "$plain_secret" ]; then
        send_message "$chat_id" "⚠️ SECRET не найден в конфигурации."
        return
    fi

    local proxy_link="tg://proxy?server=${server_ip}&port=${proxy_port}&secret=${plain_secret}"
    local qr_file="/tmp/proxy-qr-$$.png"

    # Генерируем QR-код
    qrencode -o "$qr_file" -s 10 -l H -m 2 "$proxy_link" 2>/dev/null

    if [ -f "$qr_file" ]; then
        send_photo "$chat_id" "$qr_file" "📱 *QR-код прокси*
Отсканируйте камерой Telegram"
        rm -f "$qr_file"
    else
        send_message "$chat_id" "❌ Ошибка генерации QR-кода."
    fi
}

cmd_servers() {
    local chat_id="$1"

    local msg="*🖥 Статус серверов*
"
    # Локальный сервер
    local local_ip
    local_ip=$(get_server_ip)
    local local_port=$(get_proxy_port)
    local local_status=$(check_container "mtproto-proxy")
    local local_conns=$(get_connections)

    local local_icon="🔴"
    local local_latency=""
    if [ "$local_status" = "up" ]; then
        local_icon="🟢"
        local start_time end_time
        start_time=$(date +%s%N)
        if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${local_port}" 2>/dev/null; then
            end_time=$(date +%s%N)
            local_latency=" ($(( (end_time - start_time) / 1000000 )) ms)"
        fi
    fi

    msg="${msg}
${local_icon} *Main* — \`${local_ip}:${local_port}\`${local_latency} 👥 \`${local_conns}\`"

    # Дополнительные серверы
    if [ -n "$EXTRA_SERVERS" ]; then
        IFS=',' read -ra SERVERS <<< "$EXTRA_SERVERS"
        for server_entry in "${SERVERS[@]}"; do
            local srv_name srv_ip srv_port
            IFS=':' read -r srv_name srv_ip srv_port <<< "$server_entry"
            srv_port=${srv_port:-443}

            local srv_icon="🔴"
            local srv_latency=""
            local srv_conns="N/A"

            local start_time end_time
            start_time=$(date +%s%N)
            if timeout 3 bash -c "echo > /dev/tcp/${srv_ip}/${srv_port}" 2>/dev/null; then
                end_time=$(date +%s%N)
                srv_latency=" ($(( (end_time - start_time) / 1000000 )) ms)"
                srv_icon="🟢"
            fi

            # Получаем подключения для серверов с SSH-ключом
            if [ -n "$POLAND_IP" ] && [ "$srv_ip" = "$POLAND_IP" ] && [ -n "$POLAND_SSH_KEY" ]; then
                srv_conns=$(get_remote_connections "$srv_ip" "$POLAND_SSH_KEY")
            fi

            msg="${msg}
${srv_icon} *${srv_name}* — \`${srv_ip}:${srv_port}\`${srv_latency} 👥 \`${srv_conns}\`"
        done
    else
        msg="${msg}

_Доп. серверы не настроены._
_Добавьте EXTRA\\_SERVERS в .env бота._"
    fi

    send_message "$chat_id" "$msg"
}

cmd_restart_poland() {
    local chat_id="$1"
    if [ -z "$POLAND_IP" ] || [ -z "$POLAND_SSH_KEY" ]; then
        send_message "$chat_id" "❌ POLAND\\_IP или POLAND\\_SSH\\_KEY не настроены в .env"
        return
    fi
    send_message "$chat_id" "🔄 *Перезапуск прокси на Польше...*"
    ssh -i "$POLAND_SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        root@"$POLAND_IP" \
        "cd /opt/mtproto-dashboard && docker compose restart mtproto-proxy" 2>&1
    sleep 3
    if timeout 5 bash -c "echo > /dev/tcp/${POLAND_IP}/443" 2>/dev/null; then
        send_message "$chat_id" "✅ *Прокси на Польше перезапущен!*"
    else
        send_message "$chat_id" "❌ *Польша не отвечает после перезапуска.*"
    fi
}

cmd_restartall_poland() {
    local chat_id="$1"
    if [ -z "$POLAND_IP" ] || [ -z "$POLAND_SSH_KEY" ]; then
        send_message "$chat_id" "❌ POLAND\\_IP или POLAND\\_SSH\\_KEY не настроены в .env"
        return
    fi
    send_message "$chat_id" "🔄 *Перезапуск всех сервисов на Польше...*"
    ssh -i "$POLAND_SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        root@"$POLAND_IP" \
        "cd /opt/mtproto-dashboard && docker compose down && docker compose up -d" 2>&1
    sleep 5
    if timeout 5 bash -c "echo > /dev/tcp/${POLAND_IP}/443" 2>/dev/null; then
        send_message "$chat_id" "✅ *Все сервисы на Польше перезапущены!*"
    else
        send_message "$chat_id" "❌ *Польша не отвечает после перезапуска.*"
    fi
}

cmd_speedtest() {
    local chat_id="$1"

    send_message "$chat_id" "⏳ *Запускаю speedtest...*
_Это займёт ~20 секунд_"

    if ! command -v speedtest-cli &>/dev/null && ! command -v speedtest &>/dev/null; then
        send_message "$chat_id" "❌ speedtest-cli не установлен.

Установи командой:
\`\`\`
apt install speedtest-cli
\`\`\`"
        return
    fi

    local result
    if command -v speedtest-cli &>/dev/null; then
        result=$(speedtest-cli --simple 2>&1)
    else
        result=$(speedtest --simple 2>&1)
    fi

    if [ $? -ne 0 ] || [ -z "$result" ]; then
        send_message "$chat_id" "❌ Ошибка при запуске speedtest. Попробуйте позже."
        return
    fi

    local ping_val download_val upload_val
    ping_val=$(echo "$result"     | grep -i "ping"     | awk '{print $2, $3}')
    download_val=$(echo "$result" | grep -i "download" | awk '{print $2, $3}')
    upload_val=$(echo "$result"   | grep -i "upload"   | awk '{print $2, $3}')

    local server_ip
    server_ip=$(get_server_ip)

    send_message "$chat_id" "*📡 Speedtest — \`${server_ip}\`*

🏓 Ping: \`${ping_val}\`
⬇️ Download: \`${download_val}\`
⬆️ Upload: \`${upload_val}\`"
}

cmd_help() {
    local chat_id="$1"

    send_message "$chat_id" "*🤖 Команды бота:*

/status — Статус всех сервисов
/restart — Перезапуск прокси (Германия)
/restartall — Перезапуск всех сервисов (Германия)
/restart\_pl — Перезапуск прокси (Польша)
/restartall\_pl — Перезапуск всех сервисов (Польша)
/logs — Последние логи прокси
/traffic — Статистика трафика
/ip — IP и ссылка прокси
/ping — Проверка доступности прокси
/qr — QR-код со ссылкой прокси
/servers — Статус всех серверов с подключениями
/speedtest — Тест скорости интернета сервера
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
            /restart)       cmd_restart "$chat_id" ;;
            /restartall)    cmd_restart_all "$chat_id" ;;
            /restart_pl)    cmd_restart_poland "$chat_id" ;;
            /restartall_pl) cmd_restartall_poland "$chat_id" ;;
            /logs)       cmd_logs "$chat_id" ;;
            /traffic)    cmd_traffic "$chat_id" ;;
            /ip)         cmd_ip "$chat_id" ;;
            /ping)       cmd_ping "$chat_id" ;;
            /qr)         cmd_qr "$chat_id" ;;
            /servers)    cmd_servers "$chat_id" ;;
            /speedtest)  cmd_speedtest "$chat_id" ;;
            /help|/start) cmd_help "$chat_id" ;;
            *)           send_message "$chat_id" "Неизвестная команда. /help" ;;
        esac
    done <<< "$results"
}

# --- Автоматический мониторинг ---

PREV_PROXY_STATE="unknown"
declare -A PREV_SERVER_STATES

auto_monitor() {
    local proxy_status=$(check_container "mtproto-proxy")
    local cpu=$(get_cpu_usage)
    local ram=$(get_ram_usage)

    # Проверка состояния локального прокси
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

    # Проверка дополнительных серверов
    if [ -n "$EXTRA_SERVERS" ]; then
        IFS=',' read -ra SERVERS <<< "$EXTRA_SERVERS"
        for server_entry in "${SERVERS[@]}"; do
            local srv_name srv_ip srv_port
            IFS=':' read -r srv_name srv_ip srv_port <<< "$server_entry"
            srv_port=${srv_port:-443}

            local srv_status="down"
            if timeout 3 bash -c "echo > /dev/tcp/${srv_ip}/${srv_port}" 2>/dev/null; then
                srv_status="up"
            fi

            local prev_state="${PREV_SERVER_STATES[$srv_name]:-unknown}"

            if [ "$srv_status" = "down" ] && [ "$prev_state" != "down" ]; then
                send_message "$ADMIN_CHAT_ID" "🚨 *Сервер ${srv_name} (${srv_ip}:${srv_port}) недоступен!*"
                PREV_SERVER_STATES[$srv_name]="down"
            elif [ "$srv_status" = "up" ] && [ "$prev_state" = "down" ]; then
                send_message "$ADMIN_CHAT_ID" "✅ *Сервер ${srv_name} (${srv_ip}:${srv_port}) снова доступен!*"
                PREV_SERVER_STATES[$srv_name]="up"
            else
                PREV_SERVER_STATES[$srv_name]="$srv_status"
            fi
        done
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
