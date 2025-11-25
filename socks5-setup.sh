#!/bin/bash
# Скрипт установки и запуска SOCKS5 прокси с выбором аутентификации

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

PROXY_PORT=1080

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "  ██████╗  ██████╗ ███████╗██╗  ██╗ █████╗ "
    echo " ██╔════╝ ██╔═══██╗██╔════╝██║  ██║██╔══██╗"
    echo " ██║  ███╗██║   ██║███████╗███████║███████║"
    echo " ██║   ██║██║   ██║╚════██║██╔══██║██╔══██║"
    echo " ╚██████╔╝╚██████╔╝███████║██║  ██║██║  ██║"
    echo "  ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝"
    echo ""
    echo "    ███████╗ ██████╗██████╗ ██╗██████╗ ████████╗"
    echo "    ██╔════╝██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝"
    echo "    ███████╗██║     ██████╔╝██║██████╔╝   ██║   "
    echo "    ╚════██║██║     ██╔══██╗██║██╔═══╝    ██║   "
    echo "    ███████║╚██████╗██║  ██║██║██║        ██║   "
    echo "    ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝   "
    echo -e "${NC}"
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║                    ${WHITE}SOCKS5 PROXY MANAGER${PURPLE}                    ║${NC}"
    echo -e "${PURPLE}║              ${YELLOW}Простой и надежный прокси сервер${PURPLE}              ║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен быть запущен с правами root"
        echo -e "${YELLOW}Используйте: sudo $0${NC}"
        exit 1
    fi
}

check_system() {
    log "Проверка системы..."
    if [[ -f /etc/debian_version ]]; then
        info "Обнаружен Debian/Ubuntu"
    else
        error "Скрипт предназначен для Debian/Ubuntu"
        exit 1
    fi
}

force_kill_apt() {
    log "Принудительное завершение всех процессов apt..."
    pkill -9 -f "apt" 2>/dev/null || true
    pkill -9 -f "dpkg" 2>/dev/null || true
    pkill -9 -f "unattended-upgrade" 2>/dev/null || true
    sleep 2
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock /var/cache/apt/archives/partial/* /var/lib/apt/lists/partial/*
    dpkg --configure -a 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    success "Все процессы apt завершены и блокировки удалены"
}

install_dependencies() {
    force_kill_apt
    log "Обновление пакетов..."
    apt-get update -qq
    log "Установка необходимых пакетов..."
    apt-get install -y python3 python3-pip dante-server net-tools apache2-utils
    if ! command -v danted &> /dev/null; then
        error "Dante не установлен корректно"
        exit 1
    fi
    success "Зависимости установлены"
}

get_server_ip() {
    local ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' | head -1)
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

check_port() {
    local port=${1:-$PROXY_PORT}
    if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        warning "Порт $port уже занят"
        return 1
    fi
    return 0
}

select_port() {
    local default_port=1080
    local port=$default_port
    if ! check_port $default_port; then
        echo ""
        echo -e "${YELLOW}Порт $default_port занят. Введите альтернативный порт (1024-65535):${NC}"
        while true; do
            read -p "Порт: " custom_port
            if [[ "$custom_port" =~ ^[0-9]+$ ]] && [[ $custom_port -ge 1024 && $custom_port -le 65535 ]]; then
                if check_port $custom_port; then
                    port=$custom_port
                    break
                else
                    warning "Порт $custom_port занят. Попробуйте другой."
                fi
            else
                error "Введите корректный номер порта (1024-65535)"
            fi
        done
    fi
    PROXY_PORT=$port
    success "Используется порт: $PROXY_PORT"
}

create_proxy_user() {
    read -p "Введите имя пользователя для прокси: " username
    if id "$username" &>/dev/null; then
        warning "Пользователь $username уже существует"
    else
        useradd -m "$username"
        passwd "$username"
        success "Пользователь $username создан"
    fi
}

setup_dante_auth() {
    select_port
    local server_ip=$(get_server_ip)
    info "IP сервера: $server_ip"
    info "Порт прокси: $PROXY_PORT"

    cat > /etc/danted.conf << EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

internal: 0.0.0.0 port = $PROXY_PORT
external: $server_ip

socksmethod: pam

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}
EOF

    log "Конфигурация Dante с аутентификацией создана"
}

setup_dante_noauth() {
    select_port
    local server_ip=$(get_server_ip)
    info "IP сервера: $server_ip"
    info "Порт прокси: $PROXY_PORT"

    cat > /etc/danted.conf << EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

internal: 0.0.0.0 port = $PROXY_PORT
external: $server_ip

socksmethod: none

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}
EOF

    log "Конфигурация Dante без аутентификации создана"
}

install_proxy() {
    check_system
    install_dependencies

    echo -e "${YELLOW}Хотите создать SOCKS5 прокси с аутентификацией?${NC}"
    echo "1) Да, с логином и паролем (PAM)"
    echo "2) Нет, без аутентификации (открытый прокси)"
    read -p "Введите 1 или 2: " auth_choice

    if [[ "$auth_choice" == "1" ]]; then
        create_proxy_user
        setup_dante_auth
    else
        setup_dante_noauth
    fi

    create_service
    manage_service start
    show_info
}

create_service() {
    log "Создание systemd сервиса..."
    cat > /etc/systemd/system/socks5-proxy.service << EOF
[Unit]
Description=SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/danted -f /etc/danted.conf
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    success "Systemd сервис создан"
}

manage_service() {
    local action=$1
    case $action in
        start)
            log "Запуск SOCKS5 прокси..."
            if ! check_port $PROXY_PORT; then
                error "Порт $PROXY_PORT занят"
                return 1
            fi
            systemctl start socks5-proxy
            systemctl enable socks5-proxy
            sleep 2
            if systemctl is-active --quiet socks5-proxy; then
                success "SOCKS5 прокси запущен"
                return 0
            else
                error "Не удалось запустить прокси"
                return 1
            fi
            ;;
        stop)
            log "Остановка SOCKS5 прокси..."
            systemctl stop socks5-proxy
            systemctl disable socks5-proxy
            success "SOCKS5 прокси остановлен"
            ;;
        restart)
            log "Перезапуск SOCKS5 прокси..."
            systemctl restart socks5-proxy
            sleep 2
            if systemctl is-active --quiet socks5-proxy; then
                success "SOCKS5 прокси перезапущен"
                return 0
            else
                error "Не удалось перезапустить прокси"
                return 1
            fi
            ;;
        status)
            systemctl status socks5-proxy
            ;;
        logs)
            log "Последние логи SOCKS5 прокси:"
            journalctl -u socks5-proxy --no-pager -n 20
            ;;
        *)
            error "Неизвестное действие: $action"
            return 1
            ;;
    esac
}

uninstall() {
    echo -e "${RED}Удаление SOCKS5 прокси${NC}"
    read -p "Вы уверены? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Удаление отменено"
        return 0
    fi

    if systemctl is-active --quiet socks5-proxy 2>/dev/null; then
        systemctl stop socks5-proxy
    fi

    if systemctl is-enabled --quiet socks5-proxy 2>/dev/null; then
        systemctl disable socks5-proxy
    fi

    rm -f /etc/danted.conf
    rm -f /etc/systemd/system/socks5-proxy.service
    systemctl daemon-reload

    apt-get remove -y dante-server apache2-utils
    apt-get autoremove -y

    success "SOCKS5 прокси полностью удален"
}

show_info() {
    echo -e "${CYAN}Информация о прокси${NC}"
    local server_ip=$(get_server_ip)
    echo "Сервер: $server_ip"
    echo "Порт: $PROXY_PORT"
    if grep -q "socksmethod: pam" /etc/danted.conf; then
        echo "Аутентификация: PAM (логин и пароль)"
    else
        echo "Аутентификация: нет (открытый прокси)"
    fi

    if systemctl is-active --quiet socks5-proxy 2>/dev/null; then
        echo -e "${GREEN}Прокси работает${NC}"
    else
        echo -e "${RED}Прокси не работает${NC}"
    fi
}

interactive_menu() {
    while true; do
        show_banner
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "${GREEN}1)${NC} Установить SOCKS5 прокси"
        echo -e "${GREEN}2)${NC} Запустить прокси"
        echo -e "${GREEN}3)${NC} Остановить прокси"
        echo -e "${GREEN}4)${NC} Перезапустить прокси"
        echo -e "${GREEN}5)${NC} Показать статус"
        echo -e "${GREEN}6)${NC} Показать логи"
        echo -e "${GREEN}7)${NC} Информация о прокси"
        echo -e "${GREEN}8)${NC} Удалить прокси"
        echo -e "${YELLOW}0)${NC} Выход"
        echo ""

        read -p "Введите номер действия (0-8): " choice
        echo ""

        case $choice in
            1)
                install_proxy
                ;;
            2)
                manage_service start
                ;;
            3)
                manage_service stop
                ;;
            4)
                manage_service restart
                ;;
            5)
                manage_service status
                ;;
            6)
                manage_service logs
                ;;
            7)
                show_info
                ;;
            8)
                uninstall
                ;;
            0)
                echo -e "${GREEN}До свидания!${NC}"
                exit 0
                ;;
            *)
                error "Неверный выбор"
                ;;
        esac

        echo ""
        read -p "Нажмите Enter для продолжения..."
        clear
    done
}

main() {
    check_root
    if [[ $# -gt 0 ]]; then
        case $1 in
            install)
                install_proxy
                ;;
            start|stop|restart|status|logs)
                manage_service $1
                ;;
            uninstall)
                uninstall
                ;;
            info)
                show_info
                ;;
            menu)
                interactive_menu
                ;;
            *)
                echo "Использование: $0 {install|start|stop|restart|status|logs|info|uninstall|menu}"
                exit 1
                ;;
        esac
    else
        interactive_menu
    fi
}

main "$@"
