#!/bin/sh

# ==========================================
# Usque Auto-Installer for Keenetic Entware
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "Начинаю установку Usque..."

# 1. Проверка и установка зависимостей
# ДОБАВЛЕН curl (нужен для мониторинга прокси)
DEPS="wget-ssl ca-certificates unzip bind-dig curl"
NEED_UPDATE=0

echo "Проверка зависимостей..."
for pkg in $DEPS; do
    if [ -z "$(opkg status $pkg 2>/dev/null | grep "Status:")" ]; then
        echo "Пакет $pkg не найден. Требуется установка."
        NEED_UPDATE=1
    else
        echo "Пакет $pkg уже установлен."
    fi
done

if [ $NEED_UPDATE -eq 1 ]; then
    echo "Обновление списков пакетов..."
    opkg update > /dev/null
    echo "Установка недостающих пакетов..."
    opkg install $DEPS > /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}Ошибка при установке зависимостей.${NC}"
        exit 1
    fi
    echo "Зависимости установлены."
fi

# Устанавливаем переменные окружения
export SSL_CERT_FILE=/opt/etc/ssl/certs/ca-certificates.crt
export HTTPLIB_CA_CERTS=/opt/etc/ssl/certs/ca-certificates.crt

# 2. Определение архитектуры через opkg
OPKG_ARCH=$(opkg print-architecture | awk '/arch/ {print $2}' | head -n 1)
echo "Архитектура Entware: $OPKG_ARCH"

case "$OPKG_ARCH" in
    mipsel*) FILE_ARCH="mipsle" ;;
    mips*)   FILE_ARCH="mips" ;;
    aarch64*) FILE_ARCH="arm64" ;;
    arm*)    FILE_ARCH="armv7" ;;
    x86_64*) FILE_ARCH="amd64" ;;
    *)
        ARCH=$(uname -m)
        echo "Попытка определения через uname: $ARCH"
        case "$ARCH" in
            mips|mipsel) FILE_ARCH="mipsle" ;;
            aarch64) FILE_ARCH="arm64" ;;
            armv7l|armv6l) FILE_ARCH="armv7" ;;
            x86_64) FILE_ARCH="amd64" ;;
            *) echo -e "${RED}Ошибка: Архитектура не определена.${NC}"; exit 1 ;;
        esac
        ;;
esac

echo "Целевая сборка: linux_$FILE_ARCH"

# 3. Получение ссылки на скачивание
REPO_API="https://api.github.com/repos/Diniboy1123/usque/releases/latest"
echo "Получение информации о последнем релизе..."

DOWNLOAD_URL=$(wget -qO- "$REPO_API" | grep "browser_download_url" | grep "linux_${FILE_ARCH}" | head -n 1 | sed 's/.*"\(http[^"]*\)".*/\1/')

if [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED}Не удалось найти подходящий пакет для архитектуры $FILE_ARCH.${NC}"
    exit 1
fi

echo "Ссылка на скачивание: $DOWNLOAD_URL"

# 4. Скачивание и распаковка
TMP_DIR=/tmp/usque_install
mkdir -p $TMP_DIR

echo "Скачивание..."
wget --no-check-certificate -q --show-progress -O $TMP_DIR/usque.zip "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при скачивании файла.${NC}"
    exit 1
fi

echo "Распаковка..."
unzip -o $TMP_DIR/usque.zip -d $TMP_DIR > /dev/null

BINARY_FILE=$(find $TMP_DIR -name "usque" -type f | head -n 1)

if [ -z "$BINARY_FILE" ]; then
    echo -e "${RED}Не удалось найти исполняемый файл 'usque' в архиве.${NC}"
    exit 1
fi

# 5. Перемещение в /opt/usr/bin
mv "$BINARY_FILE" /opt/usr/bin/usque
chmod +x /opt/usr/bin/usque
echo "Исполняемый файл установлен в /opt/usr/bin/usque"

rm -rf $TMP_DIR

# 6. Определение IP адреса роутера
LAN_IP=$(ip -4 addr show br0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -z "$LAN_IP" ]; then
    LAN_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
fi

if [ -z "$LAN_IP" ]; then
    echo -e "${RED}Не удалось автоматически определить IP адрес роутера. Установлено значение по умолчанию 192.168.1.1${NC}"
    LAN_IP="192.168.1.1"
fi

echo "Определен IP адрес роутера: $LAN_IP"

# 7. Создание init скрипта (С ВСТРОЕННЫМ МОНИТОРИНГОМ)
echo "Создание скрипта запуска /opt/etc/init.d/S99usque..."
cat <<EOF > /opt/etc/init.d/S99usque
#!/bin/sh

# --- Configuration ---
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
# LD_LIBRARY_PATH=/lib:/usr/lib:/opt/lib:/opt/usr/lib
# export PATH LD_LIBRARY_PATH

PROG=/opt/usr/bin/usque
CONFIG_FILE=/opt/usr/bin/config.json
ARGS="socks -S -b $LAN_IP -p 8480 -d 1.1.1.1 -d 1.0.0.1 -s ozon.ru"
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
    echo "\$DESC is running (PID \$(cat \$PIDFILE))."
  else
    echo "\$DESC is stopped."
  fi
  if [ -f "\$MONITOR_PIDFILE" ] && kill -0 "\$(cat \$MONITOR_PIDFILE)" 2>/dev/null; then
    echo "Monitor is running."
  else
    echo "Monitor is stopped."
  fi
}

wait_for_ip() {
  local RETRIES=30
  echo "Checking for LAN IP: \$BIND_IP..."
  while [ \$RETRIES -gt 0 ]; do
    if ip addr show | grep -q "inet \$BIND_IP"; then
      echo "LAN IP ready."
      return 0
    fi
    sleep 1
    RETRIES=\$((RETRIES - 1))
  done
  echo "Warning: LAN IP not found."
  return 0
}

wait_for_internet() {
  local RETRIES=30
  echo "Checking Internet connectivity..."
  while [ \$RETRIES -gt 0 ]; do
    if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
      echo "Internet (ICMP) ready."
      return 0
    fi
    sleep 1
    RETRIES=\$((RETRIES - 1))
  done
  echo "Warning: No internet response."
  return 1
}

wait_for_dns() {
  local RETRIES=30
  echo "Checking DNS resolution for \$TARGET_DOMAIN..."
  while [ \$RETRIES -gt 0 ]; do
    if nslookup "\$TARGET_DOMAIN" >/dev/null 2>&1; then
      echo "DNS ready."
      return 0
    fi
    sleep 1
    RETRIES=\$((RETRIES - 1))
  done
  echo "Warning: DNS resolution failed."
  return 1
}

start() {
  if is_running; then
    echo "Cleaning up old processes..."
    stop
    sleep 1
  fi

  wait_for_ip
  
  if [ ! -f "\$CONFIG_FILE" ]; then
      echo "Error: Config missing."
      return 1
  fi
  
  if ! wait_for_internet; then return 1; fi
  if ! wait_for_dns; then return 1; fi

  echo "Waiting 5 seconds for system stabilization..."
  sleep 5
  
  cd /opt/usr/bin || return 1

  echo -n "Starting \$DESC: "
  
  start-stop-daemon -S -q -p "\$PIDFILE" -x "\$PROG" -b -m \
    >> /tmp/usque_startup.log 2>&1 -- \$ARGS
  
  sleep 2
  
  if is_running; then
    echo "done. (PID \$(cat \$PIDFILE))"
    > /tmp/usque_startup.log
    start_monitor
  else
    echo "failed."
    cat /tmp/usque_startup.log
  fi
}

stop() {
  stop_monitor
  echo -n "Stopping \$DESC: "
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
    
    echo "done."
  else
    echo "not running."
  fi
  rm -f "\$PIDFILE"
}

# --- Логика Мониторинга ---
start_monitor() {
  if [ -f "\$MONITOR_PIDFILE" ] && kill -0 "\$(cat \$MONITOR_PIDFILE)" 2>/dev/null; then
    return # Монитор уже запущен
  fi
  
  echo "Starting background proxy monitor..."
  (
    while true; do
      sleep 60 # Проверяем каждую минуту
      
      # Проверяем интернет ЧЕРЕЗ прокси. 
      # socks5h:// означает, что DNS тоже резолвится через прокси (важно для обхода!)
      HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -x socks5h://\$BIND_IP:8480 https://cp.cloudflare.com/generate_204 2>/dev/null)
      
      if [ "\$HTTP_CODE" != "204" ]; then
        echo "\$(date '+%Y-%m-%d %H:%M:%S') [Monitor] Proxy check failed (HTTP: \$HTTP_CODE). Restarting..." >> /tmp/usque_monitor.log
        
        # Останавливаем и запускаем основную службу (монитор при этом сам не убьется, т.к. он в subshell)
        stop
        sleep 3
        start
      fi
    done
  ) &
  
  echo \$! > "\$MONITOR_PIDFILE"
}

stop_monitor() {
  if [ -f "\$MONITOR_PIDFILE" ]; then
    local mpid=\$(cat \$MONITOR_PIDFILE)
    if [ -n "\$mpid" ] && kill -0 "\$mpid" 2>/dev/null; then
      echo -n "Stopping proxy monitor: "
      kill "\$mpid" 2>/dev/null
      echo "done."
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
      echo "Detected Redsocks, restarting to apply new proxy..."
      "\$REDSOCKS_INIT" restart
    fi
    ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF

chmod +x /opt/etc/init.d/S99usque

# 8. Регистрация и запуск
echo "Выполняю регистрацию (usque register)..."
if yes | /opt/usr/bin/usque register; then
    echo "Регистрация успешна."
else
    echo -e "${RED}Ошибка при регистрации. Проверяю конфигурацию...${NC}"
fi

if [ ! -f "/opt/usr/bin/config.json" ]; then
    echo "Файл /opt/usr/bin/config.json не найден. Проверяю наличие резервной копии..."
    if [ -f "/opt/root/config.json" ]; then
        cp "/opt/root/config.json" "/opt/usr/bin/config.json"
        echo "Резервная копия применена успешно."
    else
        echo -e "${RED}Ошибка: Файл /opt/usr/bin/config.json отсутствует, а резервная копия /opt/root/config.json не найдена.${NC}"
        exit 1
    fi
fi

echo "Запуск сервиса..."
/opt/etc/init.d/S99usque start

echo -e "${GREEN}Установка завершена!${NC}"