# Marzban Setup

A one-command installer that sets up a ready-to-use [Marzban](https://github.com/Gozargah/Marzban) VPN panel with VLESS Reality on a fresh VPS.

Made by [F3 Cloud](https://f3cloud.com). Step-by-step guide: [docs.f3cloud.com](https://docs.f3cloud.com/ru/vpn-guide/marzban-ustanovka-vpn).

## Quick start

Run as root on a fresh server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/f3cloud-host/Marzban/main/marzban-setup.sh)
```

The script runs on its own, without questions, and takes 3–5 minutes. When it finishes it prints the panel address, the admin login and a generated password.

## What the script does

- Installs Marzban (SQLite) with the official installer and updates the Xray core.
- Creates a ready **VLESS Reality** inbound on port 443. The masking site is picked automatically from a short list of small European sites and verified live for TLS 1.3, HTTP/2 and no CDN before use.
- Publishes the panel on a random port through Nginx, so Marzban stays on localhost.
- Creates a sudo admin named `admin` with a random 20-character password, saved to `/root/marzban-credentials.txt` (readable by root only).
- Closes the firewall with ufw, leaving only ports 22 (SSH), 443 (VPN) and the panel port open.

## Requirements

A fresh Ubuntu 22.04+ or Debian 11+ server, run as root. The script refuses to run if Marzban is already installed, port 443 is taken or Nginx already serves other sites.

## After installation

Open the panel address from the script output, log in, create a user with the Vless protocol and share the subscription link. The full walkthrough is in the [F3 Cloud knowledge base](https://docs.f3cloud.com/ru/vpn-guide/marzban-ustanovka-vpn).

---

# Marzban Setup (по-русски)

Скрипт одной командой ставит панель [Marzban](https://github.com/Gozargah/Marzban) с VLESS Reality на чистый VPS и сам всё настраивает.

Подробная инструкция в [базе знаний F3 Cloud](https://docs.f3cloud.com/ru/vpn-guide/marzban-ustanovka-vpn).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/f3cloud-host/Marzban/main/marzban-setup.sh)
```

Скрипт работает без вопросов и занимает 3–5 минут. Сайт для маскировки Reality подбирается автоматически из списка небольших европейских сайтов и проверяется вживую. Панель открывается на случайном порту, пароль администратора генерируется случайный, а в брандмауэре остаются только порты 22, 443 и порт панели.
