#!/bin/sh

# 1. Установка redsocks
echo "Установка redsocks..."
opkg install redsocks

# 2. Определение IP адреса роутера (LAN)
# Пытаемся получить IP интерфейса br0 (стандарт для Keenetic)
LAN_IP=$(ip -4 addr show br0 | grep inet | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$LAN_IP" ]; then
    echo "Не удалось определить IP адрес интерфейса br0."
    echo "Проверьте имя интерфейса командой 'ip a'."
    exit 1
fi

echo "Определен IP адрес роутера: $LAN_IP"

# 3. Создание директории для скриптов netfilter
mkdir -p /opt/etc/ndm/netfilter.d/

# 4. Создание исполняемого скрипта 010-proxy.sh
echo "Создание скрипта /opt/etc/ndm/netfilter.d/010-proxy.sh..."
cat << 'EOFSCRIPT' > /opt/etc/ndm/netfilter.d/010-proxy.sh
#!/bin/sh

# 1. Проверяем, что redsocks запущен (ищем по вашему init-файлу)
PIDFILE="/opt/var/run/redsocks.pid"
if [ ! -f "$PIDFILE" ] || ! kill -0 $(cat "$PIDFILE") 2>/dev/null; then
    exit 0
fi

# 2. Работаем только с таблицей nat
[ "$table" != "nat" ] && exit 0

# 3. Настройка цепочки
iptables -t nat -N REDSOCKS_TG 2>/dev/null
iptables -t nat -F REDSOCKS_TG

# Исключаем локальную сеть и сам адрес роутера
iptables -t nat -A REDSOCKS_TG -d 192.168.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS_TG -d 127.0.0.1 -j RETURN

# Направляем трафик Telegram на порт REDSOCKS (12345)
# Диапазоны Telegram:
for ip in 91.108.56.0/22 91.108.4.0/22 91.108.8.0/22 91.108.16.0/22 91.108.12.0/22 149.154.160.0/20 91.105.192.0/23 91.108.20.0/22 185.76.151.0/24; do
    iptables -t nat -A REDSOCKS_TG -d $ip -p tcp -j REDIRECT --to-ports 12345
done

# 4. Пробрасываем цепочку в основной поток (если еще не добавлена)
iptables -t nat -C PREROUTING -p tcp -j REDSOCKS_TG 2>/dev/null || \
iptables -t nat -A PREROUTING -p tcp -j REDSOCKS_TG
EOFSCRIPT

chmod +x /opt/etc/ndm/netfilter.d/010-proxy.sh

# 5. Создание конфигурационного файла redsocks.conf
echo "Создание конфига /opt/etc/redsocks.conf с IP $LAN_IP..."
cat << 'EOFCONF' > /opt/etc/redsocks.conf
base {
    // debug: connection progress & client list on SIGUSR1
    log_debug = off;

    // info: start and end of client session
    log_info = on;

    /* possible `log' values are:
     *   stderr
     *   "file:/path/to/file"
     *   syslog:FACILITY  facility is any of "daemon", "local0"..."local7"
     */
    // log = stderr;
    // log = "file:/path/to/file";
    log = "syslog:local7";

    // detach from console
    daemon = on;

    /* Change uid, gid and root directory, these options require root
     * privilegies on startup.
     * Note, your chroot may requre /etc/localtime if you write log to syslog.
     * Log is opened before chroot & uid changing.
     */
    // user = nobody;
    // group = nobody;
    // chroot = "/var/chroot";

    /* possible `redirector' values are:
     *   iptables   - for Linux
     *   ipf        - for FreeBSD
     *   pf         - for OpenBSD
     *   generic    - some generic redirector that MAY work
     */
    redirector = iptables;
    redsocks_conn_max = 4096; 
}

redsocks {
    /* `local_ip' defaults to 127.0.0.1 for security reasons,
     * use 0.0.0.0 if you want to listen on every interface.
     * `local_*' are used as port to redirect to.
     */
    local_ip = PLACEHOLDER_IP;
    local_port = 12345;

    // listen() queue length. Default value is SOMAXCONN and it should be
    // good enough for most of us.
     listenq = 1024; // SOMAXCONN equals 128 on my Linux box.

    // `max_accept_backoff` is a delay to retry `accept()` after accept
    // failure (e.g. due to lack of file descriptors). It's measured in
    // milliseconds and maximal value is 65535. `min_accept_backoff` is
    // used as initial backoff value and as a damper for `accept() after
    // close()` logic.
    // min_accept_backoff = 100;
    // max_accept_backoff = 60000;

    // `ip' and `port' are IP and tcp-port of proxy-server
    // You can also use hostname instead of IP, only one (random)
    // address of multihomed host will be used.
    ip = PLACEHOLDER_IP;
    port = 8480;


    // known types: socks4, socks5, http-connect, http-relay
    type = socks5;

    // login = "foobar";
    // password = "baz";
}

redudp {
    // `local_ip' should not be 0.0.0.0 as it's also used for outgoing
    // packets that are sent as replies - and it should be fixed
    // if we want NAT to work properly.
    local_ip = 127.0.0.1;
    local_port = 10053;

    // `ip' and `port' of socks5 proxy server.
    ip = 10.0.0.1;
    port = 1080;
    login = username;
    password = pazzw0rd;

    // redsocks knows about two options while redirecting UDP packets at
    // linux: TPROXY and REDIRECT.  TPROXY requires more complex routing
    // configuration and fresh kernel (>= 2.6.37 according to squid
    // developers[1]) but has hack-free way to get original destination
    // address, REDIRECT is easier to configure, but requires `dest_ip` and
    // `dest_port` to be set, limiting packet redirection to single
    // destination.
    // [1] http://wiki.squid-cache.org/Features/Tproxy4
    dest_ip = 8.8.8.8;
    dest_port = 53;

    udp_timeout = 30;
    udp_timeout_stream = 180;
}

dnstc {
    // fake and really dumb DNS server that returns "truncated answer" to
    // every query via UDP, RFC-compliant resolver should repeat same query
    // via TCP in this case.
    local_ip = 127.0.0.1;
    local_port = 5300;
}

// you can add more `redsocks' and `redudp' sections if you need.
EOFCONF

# Заменяем плейсхолдер на реальный IP
sed -i "s/PLACEHOLDER_IP/$LAN_IP/g" /opt/etc/redsocks.conf

# 6. Перезапуск redsocks для применения конфига
echo "Перезапуск службы redsocks..."
/opt/etc/init.d/S23redsocks restart 2>/dev/null || /opt/etc/init.d/S23redsocks start

# Небольшая пауза, чтобы сервис успел стартануть и создать PID-файл
sleep 2

# 7. Применение правил iptables
echo "Применение правил iptables..."
export table=nat && /opt/etc/ndm/netfilter.d/010-proxy.sh

echo "Готово. Настройка завершена."
