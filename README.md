# Messenger Proxy Cascade

Каскадный прокси **WhatsApp** и **Telegram MTProto**: клиенты подключаются к серверу в России, а наружу трафик выходит с зарубежного сервера. Между серверами — **Xray VLESS + REALITY**, снаружи неотличимый от обычного TLS 1.3.

```
Клиент ──► вход (РФ)                        выход (зарубеж) ──► g.whatsapp.net
           haproxy :8443 ─send-proxy─┐    ┌─► haproxy 127.0.0.1:8443
           haproxy :7777 ─send-proxy─┤    ├─► haproxy 127.0.0.1:7777 ──► whatsapp.net
           haproxy :9443 ────────────┤    ├─► mtg     127.0.0.1:9443 ──► Telegram DC
                                     ▼    │
                              xray dokodemo ──── VLESS + REALITY :443 ────► xray
```

## Зачем так

| | |
|---|---|
| **Домены смотрят на RU** | Российские клиенты ходят на российский IP — быстро и без блокировок на «последней миле» |
| **Зарубежный выход** | WhatsApp и Telegram видят иностранный IP, к которому у них нет вопросов |
| **REALITY между серверами** | Транзит РФ→заграница выглядит как TLS-сессия к легитимному сайту. WireGuard/OpenVPN здесь ловятся ТСПУ по сигнатуре, REALITY — нет |
| **Реальный IP клиента** | PROXY-протокол проходит сквозь VLESS, поэтому Meta получает адрес клиента, а не адрес каскада |
| **Выход закрыт наружу** | Открыт единственный порт REALITY, и только для IP входного сервера. `haproxy` и `mtg` слушают `127.0.0.1` |

## Установка

Порядок важен: сначала выходной сервер — он выдаёт токен для входного.

### 1. Выходной сервер (зарубежный)

```bash
curl -sSL https://raw.githubusercontent.com/World-Face/messenger-proxy-cascade/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh exit
```

Спросит IP обоих серверов, домены, порты и маскировочный SNI. В конце напечатает **токен** — длинную строку base64.

### 2. Входной сервер (российский)

```bash
curl -sSL https://raw.githubusercontent.com/World-Face/messenger-proxy-cascade/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh entry
```

Спросит только токен — всё остальное (ключи REALITY, секрет Telegram, домены, порты) приедет внутри него.

В конце входной установщик прогоняет сквозную проверку: запрашивает внешний IP через каскад и сверяет с адресом выходного сервера. Совпало — цепочка рабочая.

### Без интерактива

Любой вопрос можно ответить заранее через переменную окружения — установщик спросит только то, чего не хватает. Удобно для автоматизации:

```bash
EXIT_IP=1.2.3.4 ENTRY_IP=5.6.7.8 WA_DOMAIN=whatsapp.example.com TG_DOMAIN=telegram.example.com AUTO_CONFIRM=y bash install.sh exit
```

```bash
TOKEN=<токен_с_выходного> AUTO_CONFIRM=y bash install.sh entry
```

## Параметры

| Что | По умолчанию |
|---|---|
| Порт WhatsApp Chat | `8443` |
| Порт WhatsApp Media | `7777` |
| Порт Telegram | `9443` |
| Порт REALITY (вход→выход) | `443` |
| Маскировочный SNI | `vk.ru` |

DNS-записи обоих доменов должны указывать на **входной** (российский) сервер.

## Подключение клиентов

**WhatsApp** — Настройки → Хранилище и данные → Прокси → адрес домена, порты Chat и Media.

**Telegram** — ссылка вида `https://t.me/proxy?server=...&port=...&secret=...` печатается в конце установки и лежит в `/opt/messenger-proxy/info.txt`.

## Управление

```bash
systemctl status haproxy xray-cascade telegram-proxy
```

```bash
journalctl -u xray-cascade -f
```

Статистика HAProxy — на `127.0.0.1:8199`, смотреть через SSH-туннель:

```bash
ssh -L 8199:127.0.0.1:8199 root@ВАШ_СЕРВЕР
```

Сквозная проверка каскада с входного сервера (должен вернуться IP выходного):

```bash
curl -s --socks5-hostname 127.0.0.1:10808 https://api.ipify.org
```

## Конфиги

| Файл | Где |
|---|---|
| `/opt/messenger-proxy/xray/config.json` | оба сервера |
| `/etc/haproxy/haproxy.cfg` | оба сервера |
| `/opt/messenger-proxy/telegram/config.toml` | только выход |
| `/opt/messenger-proxy/join-token.txt` | только выход |
| `/opt/messenger-proxy/info.txt` | только вход |

## Требования

- Ubuntu 20.04 / 22.04 / 24.04, root
- Если у провайдера есть внешний firewall (security groups), откройте вручную:
  - на **входном**: TCP `8443`, `7777`, `9443`
  - на **выходном**: TCP `443`

## Смена ключей

Ключи REALITY одноразово создаются на выходном сервере. Чтобы перевыпустить всю связку, перезапустите `install.sh exit`, затем `install.sh entry` с новым токеном.
