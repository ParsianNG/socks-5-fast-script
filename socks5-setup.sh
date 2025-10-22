#!/bin/bash
# Скрипт установки и управления SOCKS5 (Dante/sockd) с PAM-аутентификацией (libpam-pwdfile)

set -e

# ===== Цвета =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ===== Глобальные переменные =====
PROXY_USER=""
PROXY_PASS=""
USE_AUTH=false
PROXY_PORT=1080

CRED_FILE="/etc/socks5-credentials.txt"  # человеко-читаемый (для вывода)
PASSWD_FILE="/etc/danted.passwd"         # файл паролей PAM (htpasswd формат)
PAM_FILE="/etc/pam.d/sockd"              # PAM профиль
CONF_FILE="/etc/danted.conf"             # конфиг Dante
SERVICE_FILE="/etc/systemd/system/socks5-proxy.service"

# ===== Утилиты логирования =====
log()      { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()    { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warning()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success()  { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# ===== Баннер =====
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

# ===== Проверки прав/системы =====
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен быть запущен с правами root. Используйте: sudo $0"
    exit 1
  fi
}

check_system() {
  log "Проверка системы..."
  if [[ -f /etc/debian_version ]]; then
    info "Обнаружен Debian/Ubuntu"
  elif [[ -f /etc/redhat-release ]]; then
    error "Этот скрипт ориентирован на Debian/Ubuntu. Для RHEL/CentOS используйте аналог с yum/dnf."
    exit 1
  else
    warning "Неизвестный дистрибутив — продолжим, но возможны ошибки."
  fi
}

# ===== APT "анлок" =====
force_kill_apt() {
  log "Принудительное завершение apt/dpkg..."
  pkill -9 -f "apt" 2>/dev/null || true
  pkill -9 -f "dpkg" 2>/dev/null || true
  pkill -9 -f "unattended-upgrade" 2>/dev/null || true
  sleep 2
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
        /var/cache/apt/archives/lock /var/lib/apt/lists/lock
  rm -f /var/cache/apt/archives/partial/* 2>/dev/null || true
  rm -f /var/lib/apt/lists/partial/* 2>/dev/null || true
  dpkg --configure -a 2>/dev/null || true
  apt-get clean 2>/dev/null || true
  success "APT разблокирован"
}

# ===== Установка зависимостей =====
install_dependencies() {
  log "Обновление и установка пакетов..."
  force_kill_apt
  apt-get update -qq
  apt-get install -y python3 python3-pip dante-server libpam-pwdfile net-tools apache2-utils

  # Проверяем наличие бинаря sockd
  if ! command -v sockd &>/dev/null; then
    error "Dante (sockd) не установлен корректно"
    exit 1
  fi
  success "Зависимости установлены"
}

# ===== IP сервера =====
get_server_ip() {
  local ip
  ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' | head -1)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I | awk '{print $1}')
  fi
  echo "$ip"
}

# ===== Загрузка существующего порта =====
load_existing_port() {
  if [[ -f "$CONF_FILE" ]]; then
    local port
    port=$(grep -E "^\s*internal:" "$CONF_FILE" | grep -oE "port\s*=\s*[0-9]+" | awk '{print $3}' | head -1)
    if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
      PROXY_PORT=$port
      info "Загружен порт из существующей конфигурации: $PROXY_PORT"
    fi
  fi
}

# ===== Генерация учёток =====
generate_username() {
  local prefixes=("proxy" "socks" "user" "client" "vpn" "tunnel")
  local prefix=${prefixes[$RANDOM % ${#prefixes[@]}]}
  local number=$((RANDOM % 9000 + 1000))
  echo "${prefix}${number}"
}

generate_password() {
  local length=${1:-16}
  local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
  local password=""
  for ((i=0; i<length; i++)); do
    password="${password}${chars:$((RANDOM % ${#chars})):1}"
  done
  echo "$password"
}

generate_credentials() {
  PROXY_USER=$(generate_username)
  PROXY_PASS=$(generate_password 16)
  cat > "$CRED_FILE" << EOF
# SOCKS5 Proxy Credentials
# Generated on: $(date)
Username: $PROXY_USER
Password: $PROXY_PASS
Server: $(get_server_ip)
Port: $PROXY_PORT
Type: SOCKS5
EOF
  chmod 600 "$CRED_FILE"
  log "Учетные данные сохранены в $CRED_FILE"
}

# ===== Создание файла паролей и PAM профиля =====
create_user_file() {
  if [[ "$USE_AUTH" == "true" ]]; then
    log "Настройка PAM-аутентификации и файла паролей..."
    htpasswd -b -B -C 10 -c "$PASSWD_FILE" "$PROXY_USER" "$PROXY_PASS"
    chmod 600 "$PASSWD_FILE"

    cat > "$PAM_FILE" << 'EOF'
auth    required pam_pwdfile.so pwdfile /etc/danted.passwd
account required pam_permit.so
EOF
    success "PAM и файл паролей готовы"
  fi
}

# ===== Проверка порта =====
check_port() {
  local port=${1:-$PROXY_PORT}
  if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
    warning "Порт $port уже занят"
    info "Занятый порт $port:"
    netstat -tlnp | grep ":$port " || true
    return 1
  fi
  return 0
}

# ===== Выбор порта =====
select_port() {
  local default_port=1080
  local port=$default_port
  load_existing_port

  if [[ $PROXY_PORT -ne 1080 ]]; then
    info "Используем существующий порт: $PROXY_PORT"
    return 0
  fi

  if ! check_port $default_port; then
    echo -e "${YELLOW}Порт $default_port занят. Выберите альтернативный:${NC}"
    local suggested_ports=(1081 1082 1083 1084 1085 8080 8081 8082 3128 9050)
    for i in "${!suggested_ports[@]}"; do
      local p=${suggested_ports[$i]}
      if check_port "$p" 2>/dev/null; then
        echo -e "${GREEN}$((i+1)))${NC} $p ${GREEN}(свободен)${NC}"
      else
        echo -e "${RED}$((i+1)))${NC} $p ${RED}(занят)${NC}"
      fi
    done
    echo -e "${GREEN}$(( ${#suggested_ports[@]} + 1 )))${NC} Ввести свой порт"

    while true; do
      read -p "Выберите номер (1-$(( ${#suggested_ports[@]} + 1 ))): " choice
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [[ $choice -ge 1 && $choice -le ${#suggested_ports[@]} ]]; then
          port=${suggested_ports[$((choice-1))]}
          if check_port "$port" 2>/dev/null; then
            break
          else
            warning "Порт $port занят. Выберите другой."
          fi
        elif [[ $choice -eq $(( ${#suggested_ports[@]} + 1 )) ]]; then
          while true; do
            read -p "Введите порт (1024-65535): " custom_port
            if [[ "$custom_port" =~ ^[0-9]+$ ]] && [[ $custom_port -ge 1024 && $custom_port -le 65535 ]]; then
              if check_port "$custom_port" 2>/dev/null; then
                port=$custom_port; break 2
              else
                warning "Порт $custom_port занят."
              fi
            else
              error "Некорректный порт."
            fi
          done
        else
          error "Неверный выбор."
        fi
      else
        error "Введите число."
      fi
    done
  fi

  PROXY_PORT=$port
  success "Выбран порт: $PROXY_PORT"
}

# ===== Настройка Dante =====
setup_dante() {
  log "Настройка Dante..."
  select_port

  local server_ip
  server_ip=$(get_server_ip)
  info "IP сервера: $server_ip"
  info "Порт: $PROXY_PORT"

  echo -e "${YELLOW}Выберите тип аутентификации:${NC}"
  echo -e "${GREEN}1)${NC} С аутентификацией (логин/пароль — рекомендуется)"
  echo -e "${GREEN}2)${NC} Без аутентификации (открытый прокси)"
  read -p "Введите номер (1-2): " auth_choice

  case $auth_choice in
    1) USE_AUTH=true; info "Включена аутентификация"; generate_credentials; create_user_file ;;
    2) USE_AUTH=false; info "Открытый прокси без аутентификации" ;;
    *) USE_AUTH=true; warning "Неверный ввод — включена аутентификация по умолчанию"; generate_credentials; create_user_file ;;
  esac

  if [[ "$USE_AUTH" == "true" ]]; then
    cat > "$CONF_FILE" << EOF
logoutput: syslog
user.privileged: root
user.notprivileged: nobody

internal: 0.0.0.0 port = $PROXY_PORT
external: $server_ip

clientmethod: none
socksmethod: pam

client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect disconnect }
socks  pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect disconnect }
EOF
  else
    cat > "$CONF_FILE" << EOF
logoutput: syslog
user.privileged: root
user.notprivileged: nobody

internal: 0.0.0.0 port = $PROXY_PORT
external: $server_ip

clientmethod: none
socksmethod: none

client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect disconnect }
socks  pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect disconnect }
EOF
  fi

  log "Конфигурация записана в $CONF_FILE"

  # Валидация конфига
  if sockd -t -f "$CONF_FILE" 2>/dev/null; then
    success "Конфигурация валидна"
  else
    # fallback: короткий прогон
    if timeout 2 sockd -f "$CONF_FILE" -N -D1 >/dev/null 2>&1; then
      success "Конфигурация валидна (проверка в рантайме)"
    else
      error "Конфигурация некорректна"
      exit 1
    fi
  fi
}

# ===== systemd unit =====
create_service() {
  log "Создание systemd юнита..."
  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=SOCKS5 Proxy Server (Dante)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sockd -f $CONF_FILE
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  success "Юнит создан: $SERVICE_FILE"
}

remove_service() {
  log "Удаление systemd юнита..."
  if systemctl is-active --quiet socks5-proxy 2>/dev/null; then
    systemctl stop socks5-proxy || true
  fi
  if systemctl is-enabled --quiet socks5-proxy 2>/dev/null; then
    systemctl disable socks5-proxy || true
  fi
  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    success "Юнит удалён"
  fi
}

# ===== Удаление конфигов =====
remove_config() {
  log "Удаление конфигурационных файлов..."
  [[ -f "$CONF_FILE" ]]    && rm -f "$CONF_FILE" && success "Удален $CONF_FILE"
  [[ -f "$PASSWD_FILE" ]]  && rm -f "$PASSWD_FILE" && success "Удален $PASSWD_FILE"
  [[ -f "$PAM_FILE" ]]     && rm -f "$PAM_FILE" && success "Удален $PAM_FILE"
  [[ -f "$CRED_FILE" ]]    && rm -f "$CRED_FILE" && success "Удален $CRED_FILE"
}

# ===== Управление сервисом =====
manage_service() {
  local action=$1
  case $action in
    start)
      log "Запуск прокси..."
      if ! check_port "$PROXY_PORT"; then
        error "Порт $PROXY_PORT занят. Измени порт или останови конфликтующий сервис."
        return 1
      fi
      systemctl enable --now socks5-proxy
      sleep 1
      if systemctl is-active --quiet socks5-proxy; then
        success "SOCKS5 прокси запущен и в автозагрузке"
      else
        error "Не удалось запустить прокси"
        return 1
      fi
      ;;
    stop)     systemctl stop socks5-proxy; systemctl disable socks5-proxy || true; success "Прокси остановлен";;
    restart)  systemctl restart socks5-proxy; sleep 1; systemctl is-active --quiet socks5-proxy && success "Перезапущен" || { error "Не запустился"; return 1; };;
    status)   systemctl status socks5-proxy ;;
    logs)     journalctl -u socks5-proxy --no-pager -n 50 ;;
    *)        error "Неизвестное действие: $action"; return 1 ;;
  esac
}

# ===== Информация/учётки/диагностика =====
show_info() {
  load_existing_port
  local server_ip
  server_ip=$(get_server_ip)

  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                  ${WHITE}ИНФОРМАЦИЯ О ПРОКСИ${CYAN}                   ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "${BOLD}Сервер:${NC} $server_ip"
  echo -e "${BOLD}Порт:${NC} $PROXY_PORT"
  echo -e "${BOLD}Тип:${NC} SOCKS5"

  if [[ -f "$PASSWD_FILE" ]]; then
    echo -e "${BOLD}Аутентификация:${NC} Да (PAM/libpam-pwdfile)"
    if [[ -f "$CRED_FILE" ]]; then
      local username password
      username=$(grep -E "^Username:" "$CRED_FILE" | sed 's/^Username:\s*//')
      password=$(grep -E "^Password:" "$CRED_FILE" | sed 's/^Password:\s*//')
      [[ -n "$username" ]] && echo -e "${BOLD}Логин:${NC} $username"
      [[ -n "$password" ]] && echo -e "${BOLD}Пароль:${NC} $password"
    fi
  else
    echo -e "${BOLD}Аутентификация:${NC} Нет"
  fi

  echo ""
  if systemctl is-active --quiet socks5-proxy 2>/dev/null; then
    echo -e "${GREEN}✓ Прокси работает${NC}"
  else
    echo -e "${RED}✗ Прокси не работает${NC}"
  fi
}

show_credentials() {
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                ${WHITE}УЧЕТНЫЕ ДАННЫЕ ПРОКСИ${CYAN}                 ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  if [[ -f "$CRED_FILE" ]]; then
    cat "$CRED_FILE"
  else
    echo -e "${YELLOW}Файл с учетными данными не найден. Возможно, прокси без аутентификации.${NC}"
  fi
}

diagnose() {
  load_existing_port
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║                  ${WHITE}ДИАГНОСТИКА ПРОКСИ${YELLOW}                  ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"

  echo -e "\n${BOLD}1) Статус сервиса:${NC}"
  systemctl status socks5-proxy --no-pager || true

  echo -e "\n${BOLD}2) Проверка конфигурации:${NC}"
  if sockd -t -f "$CONF_FILE" 2>/dev/null; then
    echo -e "${GREEN}✓ Конфигурация корректна${NC}"
  else
    echo -e "${RED}✗ Проблемы в конфигурации${NC}"
    sockd -t -f "$CONF_FILE" || true
  fi

  echo -e "\n${BOLD}3) Проверка порта $PROXY_PORT:${NC}"
  if netstat -tlnp 2>/dev/null | grep -q ":$PROXY_PORT "; then
    echo -e "${GREEN}✓ Порт $PROXY_PORT слушается${NC}"
    netstat -tlnp | grep ":$PROXY_PORT " || true
  else
    echo -e "${RED}✗ Порт $PROXY_PORT свободен (сервис не слушает)${NC}"
  fi

  echo -e "\n${BOLD}4) Файл паролей:${NC}"
  if [[ -f "$PASSWD_FILE" ]]; then
    echo -e "${GREEN}✓ Найден $PASSWD_FILE${NC}"
    echo "Пользователи:"
    cut -d: -f1 "$PASSWD_FILE"
  else
    echo -e "${YELLOW}⚠ Файл паролей не найден (возможно, режим без аутентификации)${NC}"
  fi

  echo -e "\n${BOLD}5) Последние логи systemd:${NC}"
  journalctl -u socks5-proxy --no-pager -n 50 || true
}

# ===== Деинсталл =====
remove_dependencies() {
  log "Удаление пакетов..."
  systemctl stop socks5-proxy 2>/dev/null || true
  force_kill_apt
  apt-get remove -y dante-server libpam-pwdfile apache2-utils
  apt-get autoremove -y
  success "Пакеты удалены"
}

uninstall() {
  echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║                    ${WHITE}УДАЛЕНИЕ ПРОКСИ${RED}                        ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}Будут удалены: сервис, конфиги, PAM и пакеты Dante/PAM.${NC}"
  read -p "Вы уверены? (y/N): " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] || { log "Отменено"; return 0; }

  remove_service
  remove_config
  remove_dependencies
  success "Полное удаление завершено."
}

# ===== Меню/обвязка =====
show_menu() {
  show_banner
  echo -e "${WHITE}Выберите действие:${NC}\n"
  echo -e "${GREEN}1)${NC} Установить SOCKS5 прокси"
  echo -e "${GREEN}2)${NC} Запустить прокси"
  echo -e "${GREEN}3)${NC} Остановить прокси"
  echo -e "${GREEN}4)${NC} Перезапустить прокси"
  echo -e "${GREEN}5)${NC} Показать статус"
  echo -e "${GREEN}6)${NC} Показать логи"
  echo -e "${GREEN}7)${NC} Информация о прокси"
  echo -e "${GREEN}8)${NC} Показать учетные данные"
  echo -e "${GREEN}9)${NC} Регенерировать учетные данные"
  echo -e "${GREEN}10)${NC} Диагностика проблем"
  echo -e "${RED}11)${NC} Удалить прокси"
  echo -e "${YELLOW}0)${NC} Выход"
  echo -e "\n${PURPLE}Подсказка:${NC} sudo $0 {install|start|stop|restart|status|logs|info|credentials|regenerate|diagnose|uninstall|menu}"
}

handle_menu_choice() {
  local choice=$1
  case $choice in
    1) install_proxy ;;
    2) manage_service start ;;
    3) manage_service stop ;;
    4) manage_service restart ;;
    5) manage_service status ;;
    6) manage_service logs ;;
    7) show_info ;;
    8) show_credentials ;;
    9) regenerate_credentials ;;
    10) diagnose ;;
    11) uninstall ;;
    0) echo -e "${GREEN}До свидания!${NC}"; exit 0 ;;
    *) error "Неверный выбор";;
  esac
}

install_proxy() {
  log "Установка SOCKS5 прокси..."
  check_system
  install_dependencies
  setup_dante
  create_service
  if manage_service start; then
    success "SOCKS5 прокси установлен и запущен!"
    show_info
  else
    error "Не удалось запустить прокси после установки"
  fi
}

interactive_menu() {
  while true; do
    show_menu
    read -p "Введите номер действия (0-11): " choice
    echo ""
    handle_menu_choice "$choice"
    [[ "$choice" == "0" ]] && break
    echo ""; read -p "Нажмите Enter для продолжения..."
    clear
  done
}

main() {
  if [[ $# -gt 0 ]]; then
    case $1 in
      install)     check_root; install_proxy ;;
      start|stop|restart|status|logs) check_root; manage_service "$1" ;;
      uninstall)   check_root; uninstall ;;
      info)        show_info ;;
      credentials) show_credentials ;;
      regenerate)  check_root; generate_credentials; create_user_file; systemctl restart socks5-proxy || true; show_credentials ;;
      diagnose)    diagnose ;;
      menu)        check_root; interactive_menu ;;
      *) echo "Использование: $0 {install|start|stop|restart|status|logs|info|credentials|regenerate|diagnose|uninstall|menu}"; exit 1;;
    esac
  else
    check_root
    interactive_menu
  fi
}

# ===== Запуск =====
main "$@"
