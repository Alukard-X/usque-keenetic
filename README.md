<h1 align="center">Usque Auto-Installer for Keenetic</h1>

<p align="center">
  Автоматический установщик и конфигуратор <a href="https://github.com/Diniboy1123/usque">Usque</a> для роутеров Keenetic с Entware
</p>

<p align="center">
  <img src="https://img.shields.io/badge/arch-mipsle%20%7C%20mips%20%7C%20armv7%20%7C%20arm64%20%7C%20x86_64-blue" alt="Architectures"/>
  <img src="https://img.shields.io/badge/Keenetic-Entware-green" alt="Entware"/>
  <img src="https://img.shields.io/badge/shell-bash-4EAA25" alt="Shell"/>
</p>

---

## Содержание

- [Возможности](#-возможности)
- [Требования](#-требования)
- [Быстрая установка](#-быстрая-установка)
- [Использование](#-использование)
  - [Управление сервисом](#управление-сервисом)
  - [Настройка параметров](#настройка-параметров)
- [Удаление](#-удаление)
- [Как это работает](#-как-это-работает)
- [Поддерживаемые архитектуры](#-поддерживаемые-архитектуры)
- [Благодарности](#-благодарности)

---

## ✨ Возможности

- **Автоопределение архитектуры** — корректно определяет `mipsle`, `armv7`, `arm64` и другие архитектуры роутеров Keenetic, включая различие Big/Little Endian для MIPS.
- **Умная установка зависимостей** — проверяет наличие `wget-ssl`, `ca-certificates` и `unzip` через `opkg` и устанавливает только отсутствующие.
- **Скачивание последней версии** — автоматически получает ссылку на актуальный релиз через GitHub API, не требует ручного обновления URL.
- **Автоматическая конфигурация** — определяет внутренний IP-адрес роутера, создаёт init.d-скрипт для автозапуска через `start-stop-daemon`.
- **Регистрация** — автоматически принимает лицензионное соглашение и регистрирует `usque` — после установки сервис сразу готов к работе.

---

## 📋 Требования

| Требование | Описание |
|---|---|
| **Роутер Keenetic** | С поддержкой [Entware](https://github.com/Entware/Entware) |
| **SSH-доступ** | Подключение к роутеру по SSH |
| **USB-накопитель** | Подключённое хранилище для установки Entware |

> **Важно:** Если Entware ещё не установлен, скрипт не сработает. [Установите Entware](https://help.keenetic.com/hc/ru/articles/360000421400) перед запуском.

---

## 🚀 Быстрая установка

Подключитесь к роутеру по SSH (пример: 192.168.1.1:222 root/keenetic) и выполните команду:

```bash
opkg install wget-ssl ca-certificates
```

```bash
wget -qO- https://raw.githubusercontent.com/Alukard-X/usque-keenetic/refs/heads/main/install_usque.sh | sh
```

Если что-то пошло не так и не прошла автоматическая регистрация:

```bash
/opt/usr/bin/usque register
/opt/etc/init.d/S99usque restart
```

После основной установки можно дополнительно настроить проксирование через **redsocks**:

```bash
wget -qO- https://raw.githubusercontent.com/Alukard-X/usque-keenetic/refs/heads/main/setup_redsocks.sh | sh
```

---

## 🛠 Использование

После завершения установки сервис **Usque** запускается автоматически и добавляется в автозагрузку.

### Управление сервисом

Сервис управляется через стандартный init.d-скрипт `/opt/etc/init.d/S99usque`:

| Действие | Команда |
|---|---|
| **Статус** | `/opt/etc/init.d/S99usque status` |
| **Запуск** | `/opt/etc/init.d/S99usque start` |
| **Остановка** | `/opt/etc/init.d/S99usque stop` |
| **Перезапуск** | `/opt/etc/init.d/S99usque restart` |

### Настройка параметров

Для изменения параметров запуска (порт, DNS-сервер, привязка IP и т.д.) отредактируйте конфигурацию:

```bash
nano /opt/etc/init.d/S99usque
```

Найдите строку `ARGS` и измените параметры под свои нужды:

```sh
ARGS="socks -S -b 192.168.1.1 -p 8480 -d 1.1.1.1 -d 1.0.0.1 -s ozon.ru"
```

После внесения изменений перезапустите сервис:

```bash
/opt/etc/init.d/S99usque restart
```

---

## 🗑 Удаление

### Usque

```bash
/opt/etc/init.d/S99usque stop
rm /opt/usr/bin/usque /opt/usr/bin/config.json /opt/etc/init.d/S99usque
```

### Redsocks (опционально)

Если была установлена опциональная часть с redsocks:

```bash
opkg remove redsocks
rm /opt/etc/ndm/netfilter.d/010-proxy.sh
```

После удаления перезагрузите устройство, чтобы очистить правила iptables:

```bash
reboot
```

---

## ⚙️ Как это работает

Установка проходит в **7 шагов**:

1. **Проверка зависимостей** — скрипт проверяет наличие `unzip`, `wget-ssl` и `ca-certificates` через `opkg` и при необходимости устанавливает недостающие.
2. **Определение архитектуры** — используется `opkg print-architecture`, что исключает ошибки определения `mips` vs `mipsle`, характерные для роутеров Keenetic.
3. **Поиск релиза** — запрос к GitHub API для получения ссылки на последний релиз, соответствующий архитектуре роутера.
4. **Скачивание и установка** — бинарный файл скачивается, распаковывается и перемещается в `/opt/usr/bin/usque`.
5. **Определение IP** — скрипт определяет IP-адрес LAN-интерфейса (обычно `br0`) для параметра `-b`.
6. **Настройка автозапуска** — создаётся init.d-скрипт `S99usque`, использующий `start-stop-daemon` для корректной фоновой работы.
7. **Регистрация и запуск** — выполняется `usque register`, после чего сервис запускается и добавляется в автозагрузку.

---

## 🖥 Поддерживаемые архитектуры

| Архитектура | Описание |
|---|---|
| `mipsle` | Little Endian — большинство моделей Keenetic (Giga, Ultra, Extra, Viva и др.) |
| `mips` | Big Endian — редкие модели |
| `armv7` | 32-битный ARM |
| `arm64` / `aarch64` | 64-битный ARM |
| `x86_64` | x86 |

---

## 🙏 Благодарности

- [Diniboy1123](https://github.com/Diniboy1123) — автор [Usque](https://github.com/Diniboy1123/usque)
