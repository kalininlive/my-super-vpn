#!/bin/bash
# =============================================================================
# setup-vps.sh — Первоначальная настройка VPS для MTProto Proxy
# Запускать от root на свежем Ubuntu 22.04 / 24.04 / Debian 12
# =============================================================================

set -euo pipefail

echo "============================================"
echo "  Настройка VPS для MTProto Proxy"
echo "============================================"

# --- 1. Обновление системы ---
echo ""
echo "[1/5] Обновление системы..."
apt-get update -y && apt-get upgrade -y

# --- 2. Установка необходимых пакетов ---
echo ""
echo "[2/5] Установка необходимых пакетов..."
apt-get install -y \
    curl \
    wget \
    git \
    ufw \
    fail2ban \
    htop \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release

# --- 3. Установка Docker ---
echo ""
echo "[3/5] Установка Docker..."
if command -v docker &> /dev/null; then
    echo "Docker уже установлен: $(docker --version)"
else
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    echo "Docker установлен: $(docker --version)"
fi

# --- 4. Настройка файрвола (UFW) ---
echo ""
echo "[4/5] Настройка файрвола..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH — обязательно, иначе потеряем доступ
ufw allow 22/tcp comment 'SSH'

# Порт для MTProto Proxy (443 = маскировка под HTTPS)
ufw allow 443/tcp comment 'MTProto Proxy'

# Если хотите использовать другой порт, раскомментируйте:
# ufw allow 8443/tcp comment 'MTProto Proxy Alt'

ufw --force enable
ufw status verbose

# --- 5. Базовая защита SSH ---
echo ""
echo "[5/5] Настройка безопасности SSH..."

# Отключаем вход по паролю для root (рекомендуется настроить SSH-ключи заранее)
# Раскомментируйте строки ниже ТОЛЬКО если вы уже добавили свой SSH-ключ:
# sed -i 's/#PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
# sed -i 's/PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
# systemctl restart sshd

# Настраиваем fail2ban для защиты от брутфорса
cat > /etc/fail2ban/jail.local << 'JAIL'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
JAIL

systemctl enable fail2ban
systemctl restart fail2ban

echo ""
echo "============================================"
echo "  VPS настроен!"
echo "============================================"
echo ""
echo "Следующий шаг: запустите deploy-mtproto.sh"
echo ""
