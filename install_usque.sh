#!/bin.sh

# ==========================================
# Usque Auto-Installer for Keenetic Entware
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "Начинаю установку Usque..."

# 1. Устанавливаем переменные окружения
export SSL_CERT_FILE=/opt/etc/ssl/certs/ca-certificates.crt
export HTTPLIB_CA_CERTS=/opt/etc/ssl/certs/ca-certificates.crt

# Проверяем зависимости
if ! opkg list-installed | grep -q "wget-ssl"; then
    echo "Установка зависимостей (wget-ssl, ca-certificates, unzip)..."
    opkg update > /dev/null
    opkg install wget-ssl ca-certificates unzip > /dev/null
fi

# 2. Определение архитектуры через opkg (Самый надежный способ для Keenetic)
# opkg print-architecture выводит строки вида: arch mipsel-3.4 200
# Мы берем второе слово из строки, содержащей arch
OPKG_ARCH=$(opkg print-architecture | awk '/arch/ {print $2}' | head -n 1)
echo "Архитектура Entware: $OPKG_ARCH"

case "$OPKG_ARCH" in
    mipsel*)
        # Keenetic Giga, Ultra, Extra и др. обычно попадают сюда
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

# Ищем ссылку с названием "linux_{FILE_ARCH}"
DOWNLOAD_URL=$(wget -qO- "$REPO_API" | grep "browser_download_url" | grep "linux_${FILE_ARCH}" | head -n 1 | sed 's/.*"\(http[^"]*\)".*/\1/')

if [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED}Не удалось найти подходящий пакет для архитектуры $FILE_ARCH.${NC}"
    exit 1
fi

echo "Ссылка на скачивание: $DOWNLOAD_URL"

# 4. Скачивание и распаковка
TMP_DIR=/tmp/usque_install
mkdir -p $TMP_DIR
wget -q --show-progress -O $TMP_DIR/usque.zip "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при скачивании файла.${NC}"
    exit 1
fi

echo "Распаковка..."
unzip -o $TMP_DIR/usque.zip -d $TMP_DIR > /dev/null

# Поиск бинарника
BINARY_FILE=$(find $TMP_DIR -name "usque" -type f | head -n 1)

if [ -z "$BINARY_FILE" ]; then
    echo -e "${RED}Не удалось найти исполняемый файл 'usque' в архиве.${NC}"
    exit 1
fi

# 5. Перемещение в /opt/usr/bin
mv "$BINARY_FILE" /opt/usr/bin/usque
chmod +x /opt/usr/bin/usque
echo "Исполняемый файл установлен в /opt/usr/bin/usque"

# Очистка
rm -rf $TMP_DIR

# 6. Определение IP адреса роутера
# Сначала берем IP интерфейса br0 (мост LAN)
LAN_IP=$(ip -4 addr show br0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -z "$LAN_IP" ]; then
    # Если br0 нет, ищем интерфейс шлюза по умолчанию
    LAN_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
fi

if [ -z "$LAN_IP" ]; then
    echo -e "${RED}Не удалось автоматически определить IP адрес роутера.${NC}"
    LAN_IP="192.168.1.1"
fi

echo "Определен IP адрес роутера: $LAN_IP"

# 7. Создание init скрипта
echo "Создание скрипта запуска /opt/etc/init.d/S99usque..."
cat <<EOF > /opt/etc/init.d/S99usque
#!/bin/sh

# --- Configuration ---
ENABLED=yes
PROG=/opt/usr/bin/usque
ARGS="socks -S -b $LAN_IP -p 8480 -d 1.1.1.1 -d 1.0.0.1 -s ozon.ru"
DESC="Usque SOCKS5"
PIDFILE=/var/run/usque.pid

# --- Logic ---

if [ "\$ENABLED" != "yes" ]; then
    echo "\$DESC is disabled."
    exit 0
fi

start() {
    echo -n "Starting \$DESC: "
    if [ -f "\$PIDFILE" ]; then
        if kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
            echo "Already running."
            return 1
        fi
    fi
    
    start-stop-daemon -S -b -m -p "\$PIDFILE" -x "\$PROG" -- \$ARGS
    
    sleep 1
    if [ -f "\$PIDFILE" ]; then
        echo "done."
    else
        echo "failed."
    fi
}

stop() {
    echo -n "Stopping \$DESC: "
    start-stop-daemon -K -p "\$PIDFILE" -x "\$PROG"
    rm -f "\$PIDFILE"
    echo "done."
}

status() {
    if [ -f "\$PIDFILE" ]; then
        if kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
            echo "\$DESC is running (PID \$(cat \$PIDFILE))."
            return 0
        else
            echo "\$DESC is dead but PID file exists."
            return 1
        fi
    else
        echo "\$DESC is not running."
        return 3
    fi
}

case "\$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF

chmod +x /opt/etc/init.d/S99usque

# 8. Регистрация и запуск
echo "Выполняю регистрацию (usque register)..."
echo "y" | /opt/usr/bin/usque register

echo "Запуск сервиса..."
/opt/etc/init.d/S99usque start

echo -e "${GREEN}Установка завершена!${NC}"
