#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Configuration
# ============================================================

CONTAINER_NAME="amnezia-socks5proxy"
IMAGE_NAME="amnezia-socks5proxy"
INSTALL_DIR="/opt/amnezia/amnezia-socks5proxy"

SOCKS5_USER="socks5user"

# ============================================================
# Colors
# ============================================================

RESET='\033[0m'

BLUE='\033[34m'
PURPLE='\033[35m'
CYAN='\033[36m'

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'

BOLD='\033[1m'

# ============================================================
# Logging
# ============================================================

info() {
    echo -e "${BLUE}🔵 INFO${RESET}  $*"
}

ok() {
    echo -e "${GREEN}🟢 OK${RESET}    $*"
}

warn() {
    echo -e "${YELLOW}🟡 WARN${RESET}  $*"
}

error() {
    echo -e "${RED}🔴 ERROR${RESET} $*" >&2
}

stage() {
    echo
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}${BOLD}🔵 $*${RESET}"
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

cleanup_on_error() {
    error "Произошла ошибка на строке ${BASH_LINENO[0]}"
    error "Установка прервана."
}

trap cleanup_on_error ERR

# ============================================================
# Root check
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    error "Скрипт необходимо запускать от root."
    echo
    echo "Пример:"
    echo "  sudo $0"
    exit 1
fi

# ============================================================
# Random port
# ============================================================

generate_random_port() {
    while true; do
        local port
        port=$(shuf -i 1024-65535 -n 1)

        if ! ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"; then
            echo "$port"
            return
        fi
    done
}

# ============================================================
# Random password
# ============================================================

generate_password() {
    local length=16

    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom \
        | head -c "$length"
}

# ============================================================
# Variables
# ============================================================

stage "1/8 — Генерация параметров SOCKS5"

export SOCKS5_PORT="$(generate_random_port)"
export SOCKS5_USER="$SOCKS5_USER"
export SOCKS5_PASSWORD="$(generate_password)"

info "Порт:     ${SOCKS5_PORT}"
info "Пользователь: ${SOCKS5_USER}"
info "Пароль:   ${SOCKS5_PASSWORD}"

# ============================================================
# Install Docker
# ============================================================

stage "2/8 — Проверка Docker"

if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен."

    docker --version
else
    warn "Docker не найден. Устанавливаем..."

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update
        apt-get install -y docker.io

        systemctl enable --now docker

        ok "Docker установлен."

    else
        error "Не найден apt-get."
        error "Автоматическая установка Docker невозможна."
        exit 1
    fi
fi

systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker

if ! docker info >/dev/null 2>&1; then
    error "Docker daemon недоступен."
    exit 1
fi

ok "Docker daemon работает."

# ============================================================
# Prepare directory
# ============================================================

stage "3/8 — Подготовка Docker image"

mkdir -p "$INSTALL_DIR"

cd "$INSTALL_DIR"

cat > Dockerfile <<'EOF'
FROM 3proxy/3proxy:0.9.5

LABEL maintainer="AmneziaVPN"

RUN mkdir -p /opt/amnezia

RUN echo -e "#!/bin/bash\ntail -f /dev/null" > /opt/amnezia/start.sh

RUN chmod a+x /opt/amnezia/start.sh

ENTRYPOINT [ "/bin/sh", "/opt/amnezia/start.sh" ]

CMD [ "" ]
EOF

ok "Dockerfile создан."

# ============================================================
# Build image
# ============================================================

stage "4/8 — Сборка Docker image"

info "Собираем ${IMAGE_NAME}..."

docker build \
    --no-cache \
    --pull \
    -t "$IMAGE_NAME" \
    "$INSTALL_DIR"

ok "Image ${IMAGE_NAME} успешно собран."

# ============================================================
# Remove old container
# ============================================================

stage "5/8 — Создание контейнера"

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    warn "Контейнер ${CONTAINER_NAME} уже существует."

    info "Удаляем старый контейнер..."

    docker rm -f "$CONTAINER_NAME"

    ok "Старый контейнер удалён."
fi

info "Запускаем новый контейнер..."

docker run -d \
    --restart always \
    -p "${SOCKS5_PORT}:${SOCKS5_PORT}/tcp" \
    --name "$CONTAINER_NAME" \
    "$IMAGE_NAME" >/dev/null

ok "Контейнер ${CONTAINER_NAME} запущен."

# ============================================================
# Configure 3proxy
# ============================================================

stage "6/8 — Настройка 3proxy"

info "Создаём конфигурацию SOCKS5..."

docker exec \
    -e "SOCKS5_PORT=${SOCKS5_PORT}" \
    -e "SOCKS5_USER=${SOCKS5_USER}" \
    -e "SOCKS5_PASSWORD=${SOCKS5_PASSWORD}" \
    "$CONTAINER_NAME" \
    sh -c '
        cat > /usr/local/3proxy/conf/3proxy.cfg <<EOF
#!/bin/3proxy

config /usr/local/3proxy/conf/3proxy.cfg

timeouts 1 5 30 60 180 1800 15 60

users ${SOCKS5_USER}:CL:${SOCKS5_PASSWORD}

log /usr/local/3proxy/logs/3proxy.log

auth strong

socks -p${SOCKS5_PORT}
EOF
    '

ok "Конфигурация 3proxy создана."

# ============================================================
# Startup script
# ============================================================

info "Устанавливаем startup script..."

docker exec "$CONTAINER_NAME" sh -c '
    cat > /opt/amnezia/start.sh <<EOF
#!/bin/sh

echo "Container startup"

/bin/3proxy /usr/local/3proxy/conf/3proxy.cfg
EOF

chmod +x /opt/amnezia/start.sh
'

ok "Startup script установлен."

# ============================================================
# Restart container
# ============================================================

stage "7/8 — Запуск SOCKS5"

info "Перезапускаем контейнер..."

docker restart "$CONTAINER_NAME" >/dev/null

sleep 2

if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" | grep -q true; then
    ok "Контейнер работает."
else
    error "Контейнер не запустился."
    docker logs "$CONTAINER_NAME"
    exit 1
fi

# ============================================================
# Test
# ============================================================

stage "8/8 — Проверка SOCKS5"

info "Проверяем наличие процесса 3proxy..."

if docker exec "$CONTAINER_NAME" pgrep 3proxy >/dev/null 2>&1; then
    ok "3proxy запущен."
else
    error "Процесс 3proxy не найден."
    docker logs "$CONTAINER_NAME"
    exit 1
fi

info "Проверяем SOCKS5 через curl..."

if command -v curl >/dev/null 2>&1; then

    if curl \
        --silent \
        --show-error \
        --max-time 15 \
        --proxy "socks5h://${SOCKS5_USER}:${SOCKS5_PASSWORD}@127.0.0.1:${SOCKS5_PORT}" \
        https://api.ipify.org \
        >/tmp/socks5_test_result 2>/tmp/socks5_test_error
    then
        EXTERNAL_IP="$(cat /tmp/socks5_test_result)"

        ok "SOCKS5 работает."
        info "Внешний IP через proxy: ${EXTERNAL_IP}"

        rm -f /tmp/socks5_test_result /tmp/socks5_test_error
    else
        warn "Не удалось проверить SOCKS5 через curl."
        warn "Сам контейнер и процесс 3proxy при этом работают."

        if [[ -s /tmp/socks5_test_error ]]; then
            warn "$(cat /tmp/socks5_test_error)"
        fi

        rm -f /tmp/socks5_test_result /tmp/socks5_test_error
    fi

else
    warn "curl не установлен. Проверка SOCKS5 пропущена."
fi

# ============================================================
# Firewall information
# ============================================================

if command -v ufw >/dev/null 2>&1; then

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        warn "Обнаружен активный UFW."
        warn "Необходимо открыть TCP порт ${SOCKS5_PORT}:"

        echo
        echo "    ufw allow ${SOCKS5_PORT}/tcp"
        echo
    fi
fi

# ============================================================
# Final information
# ============================================================

stage "Готово"

echo
echo -e "${GREEN}${BOLD}🟢 SOCKS5 proxy успешно установлен${RESET}"
echo
echo -e "${CYAN}${BOLD}Параметры подключения:${RESET}"
echo
echo -e "  ${BLUE}🔵 Host:${RESET}     $(hostname -I | awk '{print $1}')"
echo -e "  ${BLUE}🔵 Port:${RESET}     ${SOCKS5_PORT}"
echo -e "  ${BLUE}🔵 Username:${RESET} ${SOCKS5_USER}"
echo -e "  ${BLUE}🔵 Password:${RESET} ${SOCKS5_PASSWORD}"
echo
echo -e "${CYAN}${BOLD}SOCKS5 URL:${RESET}"
echo
echo "  socks5h://${SOCKS5_USER}:${SOCKS5_PASSWORD}@$(hostname -I | awk '{print $1}'):${SOCKS5_PORT}"
echo
echo -e "${CYAN}${BOLD}Переменные окружения:${RESET}"
echo
echo "  export SOCKS5_PORT='${SOCKS5_PORT}'"
echo "  export SOCKS5_USER='${SOCKS5_USER}'"
echo "  export SOCKS5_PASSWORD='${SOCKS5_PASSWORD}'"
echo
echo -e "${CYAN}${BOLD}Docker:${RESET}"
echo
echo "  Container: ${CONTAINER_NAME}"
echo "  Image:     ${IMAGE_NAME}"
echo "  Restart:   always"
echo
echo -e "${GREEN}🟢 После перезагрузки VPS контейнер запустится автоматически.${RESET}"
echo
