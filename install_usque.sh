#!/bin/sh

# ==========================================
# Usque Auto-Installer for Keenetic Entware
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "Начинаю установку Usque..."

# 1. Проверка и установка зависимостей
# Список необходимых пакетов
DEPS="wget-ssl ca-certificates unzip"
NEED_UPDATE=0

echo "Проверка зависимостей..."
for pkg in $DEPS; do
    # Проверяем, установлен ли пакет (opkg status возвращает пусто, если нет)
    if [ -z "$(opkg status $pkg)" ]; then
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

# Устанавливаем переменные окружения (делаем это после установки ca-certificates)
export SSL_CERT_FILE=/opt/etc/ssl/certs/ca-certificates.crt
export HTTPLIB_CA_CERTS=/opt/etc/ssl/certs/ca-certificates.crt

# 2. Определение архитектуры через opkg (Самый надежный способ для Keenetic)
# opkg print-architecture выводит строки вида: arch mipsel-3.4 200
OPKG_ARCH=$(opkg print-architecture | awk '/arch/ {print $2}' | head -n 1)
echo "Архитектура Entware: $OPKG_ARCH"

case "$OPKG_ARCH" in
    mipsel*)
        # Keenetic Giga, Ultra, Extra, Viva и др. обычно попадают сюда
        FILE_ARCH="mipsle"
        ;;
    mips*)
        # Редкие модели Big Endian
        FILE_ARCH="mips"
        ;;
    aarch64*)
        FILE_ARCH="arm64"
        ;;
    arm*)
        FILE_ARCH="armv7"
        ;;
    x86_64*)
        FILE_ARCH="amd64"
        ;;
    *)
        # Fallback через uname, если opkg дал странный результат
        ARCH=$(uname -m)
        echo "Попытка определения через uname: $ARCH"
        case "$ARCH" in
            mips|mipsel) FILE_ARCH="mipsle" ;; # Для Keenetic default mips = mipsle
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

# Используем wget с сертификатами
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

# Поиск бинарника (игнорируем мусор, ищем файл 'usque')
BINARY_FILE=$(find $TMP_DIR -name "usque" -type f | head -n 1)

if [ -z "$BINARY_FILE" ]; then
    echo -e "${RED}Не удалось найти исполняемый файл 'usque' в архиве.${NC}"
    exit 1
fi

# 5. Перемещение в /opt/usr/bin
mv "$BINARY_FILE" /opt/usr/bin/usque
chmod +x /opt/usr/bin/usque
echo "Исполняемый файл установлен в /opt/usr/bin/usque"

# Очистка временных файлов
rm -rf $TMP_DIR

# 6. Определение IP адреса роутера
# Ищем IP интерфейса br0 (мост LAN), либо берем IP маршрута по умолчанию
LAN_IP=$(ip -4 addr show br0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -z "$LAN_IP" ]; then
    # Если br0 нет, берем IP интерфейса, через который идет внешний маршрут
    LAN_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
fi

if [ -z "$LAN_IP" ]; then
    echo -e "${RED}Не удалось автоматически определить IP адрес роутера. Установлено значение по умолчанию 192.168.1.1${NC}"
    LAN_IP="192.168.1.1"
fi

echo "Определен IP адрес роутера: $LAN_IP"

# 7. Создание init скрипта (UPDATED ROBUST VERSION)
echo "Создание скрипта запуска /opt/etc/init.d/S99usque..."
cat <<EOF > /opt/etc/init.d/S99usque
#!/bin/sh

# --- Configuration ---
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/lib:/usr/lib:/opt/lib:/opt/usr/lib
export PATH LD_LIBRARY_PATH

PROG=/opt/usr/bin/usque
CONFIG_FILE=/opt/usr/bin/config.json
ARGS="socks -S -b $LAN_IP -p 8480 -d 1.1.1.1 -d 1.0.0.1 -s ozon.ru"
DESC="Usque SOCKS5"
PIDFILE="/opt/var/run/usque.pid"
BIND_IP="$LAN_IP"
# The domain you use in ARGS (needed for DNS check)
TARGET_DOMAIN="ozon.ru"

# --- Logic ---

is_running() {
  pgrep -f "\$PROG" >/dev/null 2>&1
}

status_service() {
  if is_running; then
    echo "\$DESC is running."
  else
    echo "\$DESC is stopped."
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

# Wait for DNS resolution (Critical for -s ozon.ru)
wait_for_dns() {
  local RETRIES=30
  echo "Checking DNS resolution for \$TARGET_DOMAIN..."
  
  while [ \$RETRIES -gt 0 ]; do
    # nslookup checks if the router can resolve the domain
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
    pkill -f "\$PROG"
    sleep 1
  fi

  # Step 1: Wait for Local Interface
  wait_for_ip
  
  # Step 2: Wait for Config File
  if [ ! -f "\$CONFIG_FILE" ]; then
      echo "Error: Config missing."
      return 1
  fi
  
  # Step 3: Wait for Internet Connection
  if ! wait_for_internet; then return 1; fi
  
  # Step 4: Wait for DNS (Crucial fix for -s domain args)
  if ! wait_for_dns; then return 1; fi

  # Step 5: Stabilization delay
  # Even after connectivity is up, routing tables might settle late.
  echo "Waiting 5 seconds for system stabilization..."
  sleep 5
  
  cd /opt/usr/bin

  echo -n "Starting \$DESC: "
  
  \$PROG \$ARGS >> /tmp/usque_startup.log 2>&1 &
  local NEW_PID=\$!
  
  sleep 2
  
  if kill -0 "\$NEW_PID" 2>/dev/null; then
    echo "\$NEW_PID" > "\$PIDFILE"
    echo "done. (PID \$NEW_PID)"
    > /tmp/usque_startup.log
  else
    echo "failed."
    cat /tmp/usque_startup.log
  fi
}

stop() {
  echo -n "Stopping \$DESC: "
  if is_running; then
    pkill -f "\$PROG"
    echo "done."
  else
    echo "not running."
  fi
  rm -f "\$PIDFILE"
}

case "\$1" in
  start) start ;;
  stop) stop ;;
  status) status_service ;;
  restart) stop; start ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF

chmod +x /opt/etc/init.d/S99usque

# 8. Регистрация и запуск
echo "Выполняю регистрацию (usque register)..."
# Автоматически отвечаем 'y' на вопрос лицензии
echo "y" | /opt/usr/bin/usque register

echo "Запуск сервиса..."
/opt/etc/init.d/S99usque start

echo -e "${GREEN}Установка завершена!${NC}"
