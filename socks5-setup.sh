#!/bin/bash
# Скрипт установки и запуска SOCKS5 прокси

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

# Глобальные переменные для учетных данных
PROXY_USER=""
PROXY_PASS=""
USE_AUTH=false

# ASCII Art для GOSHA SCRIPT
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

# Генерация случайного логина
generate_username() {
    local prefixes=("proxy" "socks" "user" "client" "vpn" "tunnel")
    local prefix=${prefixes[$RANDOM % ${#prefixes[@]}]}
    local number=$((RANDOM % 9000 + 1000))
    echo "${prefix}${number}"
}

# Генерация случайного пароля
generate_password() {
    local length=${1:-12}
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
    local password=""
    
    for ((i=0; i<length; i++)); do
        password="${password}${chars:$((RANDOM % ${#chars})):1}"
    done
    
    echo "$password"
}

# Генерация учетных данных
generate_credentials() {
    PROXY_USER=$(generate_username)
    PROXY_PASS=$(generate_password 16)
    
    # Сохраняем учетные данные в файл
    cat > /etc/socks5-credentials.txt << EOF
# SOCKS5 Proxy Credentials
# Generated on: $(date)
# 
# Username: $PROXY_USER
# Password: $PROXY_PASS
# 
# Server: $(get_server_ip)
# Port: 1080
# Type: SOCKS5
EOF
    
    chmod 600 /etc/socks5-credentials.txt
    log "Учетные данные сохранены в /etc/socks5-credentials.txt"
}

# Функция логирования
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

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен быть запущен с правами root"
        echo -e "${YELLOW}Используйте: sudo $0${NC}"
        exit 1
    fi
}

# Проверка системы
check_system() {
    log "Проверка системы..."
    
    # Проверяем дистрибутив
    if [[ -f /etc/debian_version ]]; then
        info "Обнаружен Debian/Ubuntu"
    elif [[ -f /etc/redhat-release ]]; then
        error "Этот скрипт предназначен для Debian/Ubuntu. Для RHEL/CentOS используйте yum вместо apt"
        exit 1
    else
        warning "Неизвестный дистрибутив Linux. Скрипт может не работать корректно."
    fi
}

# Принудительное завершение всех процессов apt
force_kill_apt() {
    log "Принудительное завершение всех процессов apt..."
    
    # Завершаем все процессы apt
    pkill -9 -f "apt" 2>/dev/null || true
    pkill -9 -f "dpkg" 2>/dev/null || true
    pkill -9 -f "unattended-upgrade" 2>/dev/null || true
    
    # Ждем немного
    sleep 2
    
    # Удаляем все блокировки
    rm -f /var/lib/dpkg/lock-frontend
    rm -f /var/lib/dpkg/lock
    rm -f /var/cache/apt/archives/lock
    rm -f /var/lib/apt/lists/lock
    rm -f /var/cache/apt/archives/partial/*
    rm -f /var/lib/apt/lists/partial/*
    
    # Восстанавливаем конфигурацию dpkg
    dpkg --configure -a 2>/dev/null || true
    
    # Очищаем кэш apt
    apt-get clean 2>/dev/null || true
    
    success "Все процессы apt завершены и блокировки удалены"
}

# Установка зависимостей
install_dependencies() {
    log "Проверка и завершение процессов apt..."
    force_kill_apt
    
    log "Обновление пакетов..."
    apt-get update -qq
    
    log "Установка необходимых пакетов..."
    apt-get install -y python3 python3-pip dante-server net-tools apache2-utils
    
    # Проверяем установку Dante
    if ! command -v danted &> /dev/null; then
        error "Dante не установлен корректно"
        exit 1
    fi
    
    success "Зависимости установлены"
}

# Удаление зависимостей
remove_dependencies() {
    log "Удаление установленных пакетов..."
    
    # Останавливаем сервис перед удалением
    if systemctl is-active --quiet socks5-proxy 2>/dev/null; then
        log "Остановка SOCKS5 прокси..."
        systemctl stop socks5-proxy
    fi
    
    # Завершаем apt процессы
    force_kill_apt
    
    # Удаляем пакеты
    apt-get remove -y dante-server apache2-utils
    apt-get autoremove -y
    
    success "Пакеты удалены"
}

# Получение IP адреса сервера
get_server_ip() {
    local ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' | head -1)
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

# Создание файла пользователей для Dante
create_user_file() {
    if [[ "$USE_AUTH" == "true" ]]; then
        log "Создание файла пользователей..."
        
        # Создаем файл с пользователями
        cat > /etc/danted-users.conf << EOF
# Dante users file
# Format: username:password
$PROXY_USER:$PROXY_PASS
EOF
        
        chmod 600 /etc/danted-users.conf
        success "Файл пользователей создан"
    fi
}

# Настройка Dante SOCKS5 сервера
setup_dante() {
    log "Настройка Dante SOCKS5 сервера..."
    
    # Получаем IP сервера
    local server_ip=$(get_server_ip)
    info "IP сервера: $server_ip"
    
    # Спрашиваем про аутентификацию
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                  ${WHITE}НАСТРОЙКА АУТЕНТИФИКАЦИИ${YELLOW}                 ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Выберите тип аутентификации:${NC}"
    echo ""
    echo -e "${GREEN}1)${NC} ${BOLD}С аутентификацией${NC} - логин и пароль (рекомендуется)"
    echo -e "${GREEN}2)${NC} ${BOLD}Без аутентификации${NC} - открытый прокси"
    echo ""
    read -p "Введите номер (1-2): " auth_choice
    
    case $auth_choice in
        1)
            USE_AUTH=true
            info "Выбрана аутентификация с логином и паролем"
            generate_credentials
            create_user_file
            ;;
        2)
            USE_AUTH=false
            info "Выбран прокси без аутентификации"
            ;;
        *)
            warning "Неверный выбор, используем аутентификацию по умолчанию"
            USE_AUTH=true
            generate_credentials
            create_user_file
            ;;
    esac
    
    # Создаем конфигурацию Dante
    if [[ "$USE_AUTH" == "true" ]]; then
        # Конфигурация с аутентификацией
        cat > /etc/danted.conf << EOF
# Конфигурация Dante SOCKS5 сервера с аутентификацией
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

# Интерфейс для прослушивания
internal: 0.0.0.0 port = 1080

# Внешний интерфейс
external: $server_ip

# Методы аутентификации
socksmethod: username

# Файл пользователей
user.libwrap: /etc/danted-users.conf

# Правила доступа
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}
EOF
    else
        # Конфигурация без аутентификации
        cat > /etc/danted.conf << EOF
# Конфигурация Dante SOCKS5 сервера без аутентификации
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

# Интерфейс для прослушивания
internal: 0.0.0.0 port = 1080

# Внешний интерфейс
external: $server_ip

# Методы аутентификации
socksmethod: none

# Правила доступа
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}
EOF
    fi
    
    log "Конфигурация Dante создана"
    
    # Проверяем конфигурацию
    if danted -f /etc/danted.conf -V 2>/dev/null; then
        success "Конфигурация Dante проверена успешно"
        if [[ "$USE_AUTH" == "true" ]]; then
            info "Прокси работает С аутентификацией"
        else
            warning "Прокси работает БЕЗ аутентификации"
        fi
    else
        error "Не удалось создать корректную конфигурацию Dante"
        exit 1
    fi
}

# Создание systemd сервиса
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

# Удаление systemd сервиса
remove_service() {
    log "Удаление systemd сервиса..."
    
    # Останавливаем и отключаем сервис
    if systemctl is-active --quiet socks5-proxy 2>/dev/null; then
        systemctl stop socks5-proxy
    fi
    
    if systemctl is-enabled --quiet socks5-proxy 2>/dev/null; then
        systemctl disable socks5-proxy
    fi
    
    # Удаляем файл сервиса
    if [[ -f /etc/systemd/system/socks5-proxy.service ]]; then
        rm -f /etc/systemd/system/socks5-proxy.service
        systemctl daemon-reload
        success "Systemd сервис удален"
    fi
}

# Удаление конфигурационных файлов
remove_config() {
    log "Удаление конфигурационных файлов..."
    
    if [[ -f /etc/danted.conf ]]; then
        rm -f /etc/danted.conf
        success "Конфигурация Dante удалена"
    fi
    
    if [[ -f /etc/danted-users.conf ]]; then
        rm -f /etc/danted-users.conf
        success "Файл пользователей удален"
    fi
    
    if [[ -f /etc/socks5-credentials.txt ]]; then
        rm -f /etc/socks5-credentials.txt
        success "Файл с учетными данными удален"
    fi
}

# Проверка порта
check_port() {
    local port=1080
    if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        warning "Порт $port уже занят"
        info "Занятые порты:"
        netstat -tlnp | grep ":$port "
        return 1
    fi
    return 0
}

# Управление сервисом
manage_service() {
    local action=$1
    
    case $action in
        start)
            log "Запуск SOCKS5 прокси..."
            
            # Проверяем порт
            if ! check_port; then
                error "Порт 1080 занят. Остановите конфликтующий сервис или измените порт в конфигурации"
                return 1
            fi
            
            systemctl start socks5-proxy
            systemctl enable socks5-proxy
            
            # Ждем запуска
            sleep 2
            
            if systemctl is-active --quiet socks5-proxy; then
                success "SOCKS5 прокси запущен и добавлен в автозагрузку"
                return 0
            else
                error "Не удалось запустить SOCKS5 прокси"
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
            else
                error "Не удалось перезапустить SOCKS5 прокси"
                return 1
            fi
            ;;
        status)
            systemctl status socks5-proxy
            ;;
        logs)
            log "Показываем последние логи SOCKS5 прокси:"
            journalctl -u socks5-proxy --no-pager -n 20
            ;;
        *)
            error "Неизвестное действие: $action"
            return 1
            ;;
    esac
}

# Полное удаление SOCKS5 прокси
uninstall() {
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ${WHITE}УДАЛЕНИЕ ПРОКСИ${RED}                        ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Подтверждение удаления
    echo -e "${YELLOW}Внимание! Это действие удалит:${NC}"
    echo "  • SOCKS5 прокси сервер"
    echo "  • Все конфигурационные файлы"
    echo "  • Systemd сервис"
    echo "  • Установленные пакеты (dante-server)"
    echo "  • Файлы с учетными данными"
    echo ""
    read -p "Вы уверены, что хотите продолжить? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Удаление отменено"
        return 0
    fi
    
    # Останавливаем сервис
    if systemctl is-active --quiet socks5-proxy 2>/dev/null; then
        log "Остановка SOCKS5 прокси..."
        systemctl stop socks5-proxy
    fi
    
    # Удаляем systemd сервис
    remove_service
    
    # Удаляем конфигурацию
    remove_config
    
    # Удаляем пакеты
    remove_dependencies
    
    success "=== SOCKS5 прокси полностью удален ==="
    echo "Удалены:"
    echo "  ✓ SOCKS5 прокси сервер"
    echo "  ✓ Конфигурационные файлы"
    echo "  ✓ Systemd сервис"
    echo "  ✓ Установленные пакеты"
    echo "  ✓ Файлы с учетными данными"
}

# Показать информацию о прокси
show_info() {
    local server_ip=$(get_server_ip)
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  ${WHITE}ИНФОРМАЦИЯ О ПРОКСИ${CYAN}                   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Сервер:${NC} $server_ip"
    echo -e "${BOLD}Порт:${NC} 1080"
    echo -e "${BOLD}Тип:${NC} SOCKS5"
    
    # Проверяем, есть ли аутентификация
    if [[ -f /etc/socks5-credentials.txt ]]; then
        # Безопасное чтение учетных данных
        local username=$(grep "^# Username:" /etc/socks5-credentials.txt | sed 's/^# Username: //')
        local password=$(grep "^# Password:" /etc/socks5-credentials.txt | sed 's/^# Password: //')
        
        if [[ -n "$username" && -n "$password" ]]; then
            echo -e "${BOLD}Аутентификация:${NC} Да"
            echo -e "${BOLD}Логин:${NC} $username"
            echo -e "${BOLD}Пароль:${NC} $password"
        else
            echo -e "${BOLD}Аутентификация:${NC} Нет"
        fi
    else
        echo -e "${BOLD}Аутентификация:${NC} Нет"
    fi
    
    echo ""
    echo -e "${YELLOW}Настройки для клиентов:${NC}"
    echo "  • Тип прокси: SOCKS5"
    echo "  • Адрес: $server_ip"
    echo "  • Порт: 1080"
    
    if [[ -f /etc/socks5-credentials.txt ]]; then
        local username=$(grep "^# Username:" /etc/socks5-credentials.txt | sed 's/^# Username: //')
        local password=$(grep "^# Password:" /etc/socks5-credentials.txt | sed 's/^# Password: //')
        
        if [[ -n "$username" && -n "$password" ]]; then
            echo "  • Логин: $username"
            echo "  • Пароль: $password"
        else
            echo "  • Логин: (не требуется)"
            echo "  • Пароль: (не требуется)"
        fi
    else
        echo "  • Логин: (не требуется)"
        echo "  • Пароль: (не требуется)"
    fi
    
    echo ""
    echo -e "${YELLOW}Файлы с учетными данными:${NC}"
    echo "  • /etc/socks5-credentials.txt"
    
    echo ""
    
    # Проверяем статус
    if systemctl is-active --quiet socks5-proxy 2>/dev/null; then
        echo -e "${GREEN}✓ SOCKS5 прокси работает${NC}"
    else
        echo -e "${RED}✗ SOCKS5 прокси не работает${NC}"
    fi
}

# Показать учетные данные
show_credentials() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                ${WHITE}УЧЕТНЫЕ ДАННЫЕ ПРОКСИ${CYAN}                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [[ -f /etc/socks5-credentials.txt ]]; then
        cat /etc/socks5-credentials.txt
    else
        echo -e "${RED}Файл с учетными данными не найден${NC}"
        echo "Возможно, прокси работает без аутентификации"
    fi
}

# Регенерация учетных данных
regenerate_credentials() {
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║              ${WHITE}РЕГЕНЕРАЦИЯ УЧЕТНЫХ ДАННЫХ${YELLOW}              ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    read -p "Вы уверены, что хотите сгенерировать новые учетные данные? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Генерация новых учетных данных..."
        generate_credentials
        create_user_file
        
        # Перезапускаем сервис
        if systemctl is-active --quiet socks5-proxy; then
            log "Перезапуск сервиса для применения новых учетных данных..."
            systemctl restart socks5-proxy
            success "Новые учетные данные применены!"
        fi
        
        show_credentials
    else
        log "Регенерация отменена"
    fi
}

# Диагностика проблем
diagnose() {
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                  ${WHITE}ДИАГНОСТИКА ПРОКСИ${YELLOW}                  ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BOLD}1. Проверка статуса сервиса:${NC}"
    systemctl status socks5-proxy --no-pager
    
    echo -e "\n${BOLD}2. Проверка конфигурации Dante:${NC}"
    if danted -f /etc/danted.conf -V 2>/dev/null; then
        echo -e "${GREEN}✓ Конфигурация корректна${NC}"
    else
        echo -e "${RED}✗ Проблема с конфигурацией${NC}"
        danted -f /etc/danted.conf -V
    fi
    
    echo -e "\n${BOLD}3. Проверка порта 1080:${NC}"
    if netstat -tlnp 2>/dev/null | grep -q ":1080 "; then
        echo -e "${GREEN}✓ Порт 1080 занят (это нормально если прокси работает)${NC}"
        netstat -tlnp | grep ":1080 "
    else
        echo -e "${RED}✗ Порт 1080 свободен (прокси не работает)${NC}"
    fi
    
    echo -e "\n${BOLD}4. Проверка файлов пользователей:${NC}"
    if [[ -f /etc/danted-users.conf ]]; then
        echo -e "${GREEN}✓ Файл пользователей существует${NC}"
        echo "Пользователи:"
        cat /etc/danted-users.conf
    else
        echo -e "${YELLOW}⚠ Файл пользователей не найден (прокси без аутентификации)${NC}"
    fi
    
    echo -e "\n${BOLD}5. Последние логи:${NC}"
    journalctl -u socks5-proxy --no-pager -n 10
}

# Главное меню
show_menu() {
    show_banner
    
    echo -e "${WHITE}Выберите действие:${NC}"
    echo ""
    echo -e "${GREEN}1)${NC} ${BOLD}Установить SOCKS5 прокси${NC}"
    echo -e "${GREEN}2)${NC} ${BOLD}Запустить прокси${NC}"
    echo -e "${GREEN}3)${NC} ${BOLD}Остановить прокси${NC}"
    echo -e "${GREEN}4)${NC} ${BOLD}Перезапустить прокси${NC}"
    echo -e "${GREEN}5)${NC} ${BOLD}Показать статус${NC}"
    echo -e "${GREEN}6)${NC} ${BOLD}Показать логи${NC}"
    echo -e "${GREEN}7)${NC} ${BOLD}Информация о прокси${NC}"
    echo -e "${GREEN}8)${NC} ${BOLD}Показать учетные данные${NC}"
    echo -e "${GREEN}9)${NC} ${BOLD}Регенерировать учетные данные${NC}"
    echo -e "${GREEN}10)${NC} ${BOLD}Диагностика проблем${NC}"
    echo -e "${RED}11)${NC} ${BOLD}Удалить прокси${NC}"
    echo -e "${YELLOW}0)${NC} ${BOLD}Выход${NC}"
    echo ""
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║  ${WHITE}Для быстрого запуска используйте: sudo $0 [команда]${PURPLE}  ║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Обработка выбора меню
handle_menu_choice() {
    local choice=$1
    
    case $choice in
        1)
            echo -e "${CYAN}Установка SOCKS5 прокси...${NC}"
            install_proxy
            ;;
        2)
            echo -e "${CYAN}Запуск SOCKS5 прокси...${NC}"
            if manage_service start; then
                success "Прокси успешно запущен!"
            else
                error "Не удалось запустить прокси"
            fi
            ;;
        3)
            echo -e "${CYAN}Остановка SOCKS5 прокси...${NC}"
            manage_service stop
            ;;
        4)
            echo -e "${CYAN}Перезапуск SOCKS5 прокси...${NC}"
            if manage_service restart; then
                success "Прокси успешно перезапущен!"
            else
                error "Не удалось перезапустить прокси"
            fi
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
            show_credentials
            ;;
        9)
            regenerate_credentials
            ;;
        10)
            diagnose
            ;;
        11)
            uninstall
            ;;
        0)
            echo -e "${GREEN}До свидания!${NC}"
            exit 0
            ;;
        *)
            error "Неверный выбор. Попробуйте снова."
            ;;
    esac
}

# Установка прокси
install_proxy() {
    log "Установка SOCKS5 прокси сервера..."
    check_system
    install_dependencies
    setup_dante
    create_service
    if manage_service start; then
        success "SOCKS5 прокси успешно установлен и запущен!"
        show_info
    else
        error "Не удалось запустить прокси после установки"
    fi
}

# Интерактивное меню
interactive_menu() {
    while true; do
        show_menu
        read -p "Введите номер действия (0-11): " choice
        echo ""
        
        handle_menu_choice $choice
        
        if [[ $choice != 0 ]]; then
            echo ""
            read -p "Нажмите Enter для продолжения..."
            clear
        fi
    done
}

# Основная функция
main() {
    # Если передан аргумент, выполняем команду напрямую
    if [[ $# -gt 0 ]]; then
        case $1 in
            install)
                check_root
                install_proxy
                ;;
            start|stop|restart|status|logs)
                check_root
                manage_service $1
                ;;
            uninstall)
                check_root
                uninstall
                ;;
            info)
                show_info
                ;;
            credentials)
                show_credentials
                ;;
            regenerate)
                check_root
                regenerate_credentials
                ;;
            diagnose)
                diagnose
                ;;
            menu)
                check_root
                interactive_menu
                ;;
            *)
                echo "Использование: $0 {install|start|stop|restart|status|logs|info|credentials|regenerate|diagnose|uninstall|menu}"
                echo ""
                echo "Команды:"
                echo "  install     - установить и настроить SOCKS5 прокси"
                echo "  start       - запустить прокси"
                echo "  stop        - остановить прокси"
                echo "  restart     - перезапустить прокси"
                echo "  status      - показать статус"
                echo "  logs        - показать логи"
                echo "  info        - показать информацию о прокси"
                echo "  credentials - показать учетные данные"
                echo "  regenerate  - регенерировать учетные данные"
                echo "  diagnose    - диагностика проблем"
                echo "  uninstall   - полностью удалить прокси"
                echo "  menu        - показать интерактивное меню"
                exit 1
                ;;
        esac
    else
        # Если аргументов нет, показываем интерактивное меню
        check_root
        interactive_menu
    fi
}

# Запуск
main "$@"