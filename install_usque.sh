#!/bin/sh

# ==========================================
# Usque Auto-Installer for Keenetic Entware
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

printf "Начинаю установку Usque...\n"

# 1. Проверка и установка зависимостей
DEPS="wget-ssl ca-certificates unzip bind-dig curl"
NEED_UPDATE=0

printf "Проверка зависимостей...\n"
for pkg in $DEPS; do
    if ! opkg list-installed | grep -q "^${pkg} -"; then
        printf "Пакет %s не найден. Требуется установка.\n" "$pkg"
        NEED_UPDATE=1
    else
        printf "Пакет %s уже установлен.\n" "$pkg"
    fi
done

if [ "$NEED_UPDATE" -eq 1 ]; then
    printf "Обновление списков пакетов...\n"
    opkg update > /dev/null
    printf "Установка недостающих пакетов...\n"
    opkg install $DEPS > /dev/null
    if [ $? -ne 0 ]; then
        printf "${RED}Ошибка при установке зависимостей.${NC}\n"
        exit 1
    fi
    printf "Зависимости установлены.\n"
fi

export SSL_CERT_FILE=/opt/etc/ssl/certs/ca-certificates.crt
export HTTPLIB_CA_CERTS=/opt/etc/ssl/certs/ca-certificates.crt

# 2. Определение архитектуры

get_endian() {
    if [ -x /bin/busybox ]; then
        od -An -tx1 -N5 /bin/busybox | tr -d ' \n' | cut -c9-10
    else
        echo "unknown"
    fi
}

OPKG_ARCH=$(opkg print-architecture | awk '/arch/ && $2 != "all" && $2 != "noarch" {print $2; exit}')
printf "Архитектура Entware: %s\n" "$OPKG_ARCH"

case "$OPKG_ARCH" in
    mipsel*) FILE_ARCH="mipsle" ;;
    mips*)   FILE_ARCH="mips" ;;
    aarch64*) FILE_ARCH="arm64" ;;
    arm*)    FILE_ARCH="armv7" ;;
    x86_64*) FILE_ARCH="amd64" ;;
    *)
        ARCH=$(uname -m)
        printf "Попытка определения через uname: %s\n" "$ARCH"
        case "$ARCH" in
            aarch64) FILE_ARCH="arm64" ;;
            armv7l|armv6l) FILE_ARCH="armv7" ;;
            x86_64) FILE_ARCH="amd64" ;;
            mipsel) FILE_ARCH="mipsle" ;;
            mips)
                ENDIAN=$(get_endian)
                printf "Определена Endianness процессора: %s\n" "$ENDIAN"
                if [ "$ENDIAN" = "01" ]; then
                    FILE_ARCH="mipsle"
                else
                    FILE_ARCH="mips"
                fi
                ;;
            *) printf "${RED}Ошибка: Архитектура не определена.${NC}\n"; exit 1 ;;
        esac
        ;;
esac

printf "Целевая сборка: linux_%s\n" "$FILE_ARCH"

# 3. Получение ссылки на скачивание
REPO_API="https://api.github.com/repos/Diniboy1123/usque/releases/latest"
printf "Получение информации о последнем релизе...\n"

DOWNLOAD_URL=$(wget -qO- "$REPO_API" | grep "browser_download_url" | grep "linux_${FILE_ARCH}" | head -n 1 | sed 's/.*:[[:space:]]*"\(http[^"]*\)".*/\1/')

if [ -z "$DOWNLOAD_URL" ]; then
    printf "${RED}Не удалось найти подходящий пакет для архитектуры %s.${NC}\n" "$FILE_ARCH"
    exit 1
fi

printf "Ссылка на скачивание: %s\n" "$DOWNLOAD_URL"

# 4. Скачивание и распаковка
TMP_DIR=/tmp/usque_install
mkdir -p "$TMP_DIR"

printf "Скачивание...\n"
wget -q --show-progress -O "$TMP_DIR/usque.zip" "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    printf "${RED}Ошибка при скачивании файла.${NC}\n"
    exit 1
fi

printf "Распаковка...\n"
unzip -o "$TMP_DIR/usque.zip" -d "$TMP_DIR" > /dev/null

BINARY_FILE=$(find "$TMP_DIR" -name "usque" -type f | head -n 1)

if [ -z "$BINARY_FILE" ]; then
    printf "${RED}Не удалось найти исполняемый файл 'usque' в архиве.${NC}\n"
    exit 1
fi

# 5. Перемещение в /opt/usr/bin
mv "$BINARY_FILE" /opt/usr/bin/usque
chmod +x /opt/usr/bin/usque
printf "Исполняемый файл установлен в /opt/usr/bin/usque\n"

rm -rf "$TMP_DIR"

# 6. Определение ВНУТРЕННЕГО IP адреса роутера
LAN_IP=$(ip -4 addr show br0 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}')

if [ -z "$LAN_IP" ]; then
    LAN_IP=$(ip -4 addr show | awk '/inet / {
        ip=$2; sub(/\/.*/, "", ip);
        if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) {
            print ip; exit
        }
    }')
fi

if [ -z "$LAN_IP" ]; then
    printf "${RED}Не удалось автоматически определить внутренний IP адрес роутера. Установлено значение по умолчанию 192.168.1.1${NC}\n"
    LAN_IP="192.168.1.1"
fi

printf "Определен внутренний IP адрес роутера: %s\n" "$LAN_IP"

# 7. Создание init скрипта
printf "Создание скрипта запуска /opt/etc/init.d/S99usque...\n"
cat <<EOF > /opt/etc/init.d/S99usque
#!/bin/sh

# --- Configuration ---
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROG=/opt/usr/bin/usque
CONFIG_FILE=/opt/etc/usque/config.json
ARGS="-c \$CONFIG_FILE socks -S -b $LAN_IP -p 8480 -d 1.1.1.1 -d 1.0.0.1 -s ozon.ru"
DESC="Usque SOCKS5"
PIDFILE="/opt/var/run/usque.pid"
MONITOR_PIDFILE="/opt/var/run/usque_monitor.pid"
BIND_IP="$LAN_IP"
TARGET_DOMAIN="ozon.ru"
REDSOCKS_INIT="/opt/etc/init.d/S23redsocks"

# --- Logic ---

is_running() {
  [ -f "\$PIDFILE" ] && read pid < "\$PIDFILE" && [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null
}

status_service() {
  if is_running; then
    printf "%s is running (PID %s).\n" "\$DESC" "\$(cat \$PIDFILE)"
  else
    printf "%s is stopped.\n" "\$DESC"
  fi
  if [ -f "\$MONITOR_PIDFILE" ] && kill -0 "\$(cat \$MONITOR_PIDFILE)" 2>/dev/null; then
    printf "Monitor is running.\n"
  else
    printf "Monitor is stopped.\n"
  fi
}

wait_for_ip() {
  local RETRIES=30
  printf "Checking for LAN IP: %s...\n" "\$BIND_IP"
  while [ \$RETRIES -gt 0 ]; do
    if ip addr show | grep -q "inet \$BIND_IP"; then
      printf "LAN IP ready.\n"
      return 0
    fi
    sleep 1
    RETRIES=\$((RETRIES - 1))
  done
  printf "Warning: LAN IP not found.\n"
  return 0
}

wait_for_internet() {
  local RETRIES=30
  printf "Checking Internet connectivity...\n"
  while [ \$RETRIES -gt 0 ]; do
    if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
      printf "Internet (ICMP) ready.\n"
      return 0
    fi
    sleep 1
    RETRIES=\$((RETRIES - 1))
  done
  printf "Warning: No internet response.\n"
  return 1
}

wait_for_dns() {
  local RETRIES=30
  printf "Checking DNS resolution for %s...\n" "\$TARGET_DOMAIN"
  while [ \$RETRIES -gt 0 ]; do
    if nslookup "\$TARGET_DOMAIN" >/dev/null 2>&1; then
      printf "DNS ready.\n"
      return 0
    fi
    sleep 1
    RETRIES=\$((RETRIES - 1))
  done
  printf "Warning: DNS resolution failed.\n"
  return 1
}

start() {
  if is_running; then
    printf "Cleaning up old processes...\n"
    stop
    sleep 1
  fi

  wait_for_ip
  
  if [ ! -f "\$CONFIG_FILE" ]; then
      printf "Error: Config missing at %s.\n" "\$CONFIG_FILE"
      return 1
  fi
  
  if ! wait_for_internet; then return 1; fi
  if ! wait_for_dns; then return 1; fi

  printf "Waiting 5 seconds for system stabilization...\n"
  sleep 5

  printf "Starting %s: " "\$DESC"
  
  start-stop-daemon -S -q -p "\$PIDFILE" -x "\$PROG" -b -m -- \$ARGS
  
  sleep 2
  
  if is_running; then
    printf "done. (PID %s)\n" "\$(cat \$PIDFILE)"
    start_monitor
  else
    printf "failed.\n"
  fi
}

stop() {
  stop_monitor
  printf "Stopping %s: " "\$DESC"
  if is_running; then
    start-stop-daemon -K -q -p "\$PIDFILE" -x "\$PROG"
    
    local RETRY=5
    while [ \$RETRY -gt 0 ] && is_running; do
      sleep 1
      RETRY=\$((RETRY - 1))
    done
    
    if is_running; then
      start-stop-daemon -K -q -p "\$PIDFILE" -x "\$PROG" -s KILL
    fi
    
    printf "done.\n"
  else
    printf "not running.\n"
  fi
  rm -f "\$PIDFILE"
}

# --- Логика Мониторинга ---
start_monitor() {
  if [ -f "\$MONITOR_PIDFILE" ] && kill -0 "\$(cat \$MONITOR_PIDFILE)" 2>/dev/null; then
    return
  fi
  
  printf "Starting background proxy monitor...\n"
  (
    while true; do
      sleep 60
      
      HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -x socks5h://\$BIND_IP:8480 https://cp.cloudflare.com/generate_204 2>/dev/null)
      
      if [ "\$HTTP_CODE" != "204" ]; then
        # ИСПРАВЛЕНО: %%s заменено на %s, а %%Y и прочее - на %Y, чтобы выводился реальный код, а не буквы
        printf "\$(date '+%Y-%m-%d %H:%M:%S') [Monitor] Proxy check failed (HTTP: %s). Restarting...\n" "\$HTTP_CODE" >> /tmp/usque_monitor.log
        
        /opt/etc/init.d/S99usque restart >> /tmp/usque_monitor.log 2>&1 &
        exit 0 
      fi
    done
  ) &
  
  echo \$! > "\$MONITOR_PIDFILE"
}

stop_monitor() {
  if [ -f "\$MONITOR_PIDFILE" ]; then
    local mpid=\$(cat \$MONITOR_PIDFILE)
    if [ -n "\$mpid" ] && kill -0 "\$mpid" 2>/dev/null; then
      printf "Stopping proxy monitor: "
      kill "\$mpid" 2>/dev/null
      printf "done.\n"
    fi
    rm -f "\$MONITOR_PIDFILE"
  fi
}

case "\$1" in
  start) start ;;
  stop) stop ;;
  status) status_service ;;
  restart)
    stop
    start
    if [ -x "\$REDSOCKS_INIT" ]; then
      printf "Detected Redsocks, restarting to apply new proxy...\n"
      "\$REDSOCKS_INIT" restart
    fi
    ;;
  # ИСПРАВЛЕНО: %%s заменено на %s
  *) printf "Usage: %s {start|stop|restart|status}\n" "\$0"; exit 1 ;;
esac
EOF

chmod +x /opt/etc/init.d/S99usque

# 8. Подготовка директории и регистрация
printf "Создание директории конфигурации...\n"
if [ ! -d "/opt/etc/usque" ]; then
    mkdir -p /opt/etc/usque
    printf "Директория /opt/etc/usque создана.\n"
fi

# Перенос старого конфига, если он есть
if [ -f "/opt/usr/bin/config.json" ] && [ ! -f "/opt/etc/usque/config.json" ]; then
    mv "/opt/usr/bin/config.json" "/opt/etc/usque/config.json"
    printf "Конфиг перенесен из /opt/usr/bin/ в /opt/etc/usque/\n"
fi

# Регистрация (только если конфига еще нет)
if [ -f "/opt/etc/usque/config.json" ]; then
    printf "Конфигурационный файл уже существует. Регистрация пропускается.\n"
else
    printf "Выполняю регистрацию (usque register)...\n"
    yes | /opt/usr/bin/usque register -c /opt/etc/usque/config.json
    
    if [ $? -ne 0 ]; then
        printf "${RED}Ошибка при автоматической регистрации. Попробуйте ввести команду вручную: usque register -c /opt/etc/usque/config.json${NC}\n"
        exit 1
    fi
    printf "Регистрация успешна.\n"
fi

printf "Запуск сервиса...\n"
/opt/etc/init.d/S99usque start

printf "${GREEN}Установка завершена!${NC}\n"