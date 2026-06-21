# black-box

> **[English](#english)** | **[فارسی](#فارسی)**

---

<a name="english"></a>
## WStunnel + Caddy Setup

An interactive bash script that sets up a **WebSocket reverse tunnel** between an Iran VPS (server) and one or more Foreign VPS machines (clients) using [wstunnel](https://github.com/erebe/wstunnel) and [Caddy](https://caddyserver.com).

### Traffic Flow

```
User Device
    │
    ▼  TCP/UDP
Iran VPS :PORT  (Caddy — TLS termination on :443)
    │
    ▼  WSS (wss://domain:443)
wstunnel server  ws://127.0.0.1:2018
    │
    ▼  WebSocket reverse tunnel (-R)
wstunnel client  (Foreign VPS)
    │
    ▼  localhost
VPN / Service  :LOCAL_PORT
```

---

### Quick Install

Run this **once** on either VPS — the script detects the appropriate role automatically:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh)
```

After the first install, a `ws` shortcut is placed at `/usr/local/bin/ws`.
From that point on, just run:

```bash
ws
```

to relaunch the latest version of the script from anywhere on the server.

---

### Requirements

| Requirement | Notes |
|---|---|
| Root / sudo access | Required on both VPS machines |
| `curl` | For downloading binaries |
| Debian / Ubuntu | Caddy installed via apt or binary |
| Domain with DNS A record | Must point to Iran VPS IP — required for TLS |

---

### What Gets Installed

| VPS | Component | Details |
|---|---|---|
| Iran VPS | wstunnel (server mode) | Listens on `ws://127.0.0.1:2018` (local only) |
| Iran VPS | Caddy | TLS termination + reverse proxy to wstunnel |
| Iran VPS | systemd service | `wstunnel-server.service` — auto-starts on boot |
| Foreign VPS | wstunnel (client mode) | Connects outbound via `wss://domain:443` |
| Foreign VPS | systemd service | `wstunnel-client.service` — auto-starts on boot |
| Both | `ws` shortcut | `/usr/local/bin/ws` — reruns latest script from GitHub |

---

### Features

**Installation**
- Interactive guided setup for Iran VPS (server) and Foreign VPS (client)
- Automatically installs wstunnel binary and creates systemd service
- Installs and configures Caddy with automatic internal TLS
- Enables services on boot out of the box

**Multi-Domain (Iran VPS)**
- Add multiple domain names — each gets its own Caddy block routing to the same wstunnel port
- Useful for domain rotation or load distribution

**Multi-Location (Multiple Foreign VPS)**
- Multiple Foreign VPS machines can connect to the same Iran VPS simultaneously
- Each client uses a different port — natively supported by wstunnel `-R` flags
- Duplicate port detection prevents conflicts at setup time

**Multiple Port Mappings (per Foreign VPS)**
- Each client can open multiple reverse-tunnel port mappings in a single service
- Add, edit, or remove individual mappings from the Edit menu

**Scheduled Auto-Restart**
- Configure periodic tunnel restarts (every 2 / 3 / 4 / 6 / 8 / 12 hours)
- Implemented via systemd timers — no cron required
- Configurable from the Edit menu without reinstalling

**Edit Menu**
- *Iran VPS*: add/remove domains, change bind IP & port, configure auto-restart
- *Foreign VPS*: add/edit/remove port mappings, change domain & WSS port, configure auto-restart

**Diagnose**
- Checks wstunnel service status, Caddy status, port reachability, and firewall rules
- Detects common misconfigurations and reports clear fix instructions

**Update**
- Updates wstunnel binary to any chosen version
- Updates Caddy binary (if installed by the script)
- Refreshes the `ws` script shortcut to the latest version from GitHub
- Restarts affected services automatically

**Full Uninstall**
- Removes wstunnel binary, systemd service files, and the `wstunnel` user
- Removes Caddy (binary or apt), its config, user, and apt repo entry
- Removes all systemd restart timer files
- If Caddy was pre-existing, only removes the blocks added by this script

---

### Performance & Stability Optimizations

The script automatically applies the following hardening on both roles:

**Caddy (Iran VPS)**
| Setting | Value | Reason |
|---|---|---|
| `protocols h1` | HTTP/1.1 only | Prevents HTTP/2 ALPN negotiation issues with wstunnel |
| `enable_full_duplex` | on | Allows simultaneous read/write on HTTP/1.1 connections |
| `flush_interval -1` | immediate | Enables real-time WebSocket streaming without buffering |
| `reverse_proxy 127.0.0.1:…` | IP literal | Avoids DNS resolution timeout for `localhost` under load |
| `response_header_timeout 0` | no timeout | Prevents proxy from closing long-lived WebSocket connections |
| `LimitNOFILE` | 1 048 576 | Supports large numbers of open file descriptors |

**wstunnel (both roles)**
| Setting | Value | Reason |
|---|---|---|
| `--websocket-ping-frequency-sec` | 30 s | Keeps WebSocket connections alive through idle firewalls |
| `--connection-min-idle` | 5 | Pre-warms connections — reduces latency on first user connect |
| `LimitNOFILE` | 65 536 | Handles many simultaneous tunnel connections |
| `TasksMax` | 65 536 | Prevents systemd from hitting the default task limit (~1027) |
| `RestartSec` (server) | 5 s | Fast recovery after crash |
| `RestartSec` (client) | 20 s | Prevents reconnect storms on repeated failures |

**Kernel (Iran VPS — applied automatically during install)**
| Parameter | Value | Reason |
|---|---|---|
| `net.ipv4.tcp_max_syn_backlog` | 4096 | Handles burst reconnects (default 128 causes drops at 800+ connections) |
| `net.core.netdev_max_backlog` | 4096 | Increases network receive queue depth |
| `net.ipv4.tcp_syn_retries` | 3 | Faster failure on dead paths |
| `net.ipv4.tcp_fin_timeout` | 15 s | Releases closed sockets faster |
| `net.ipv4.tcp_tw_reuse` | 1 | Allows TIME_WAIT socket reuse |

---

### DNS Setup

Point your domain to the Iran VPS IP before running the script:

```
tunnel.yourdomain.com  A  <IRAN_VPS_IP>
```

Caddy handles TLS certificate issuance automatically once DNS propagates.

---

### Menu Overview

```
What would you like to do?
  1) Install — Iran VPS (server)
  2) Install — Foreign VPS (client)
  3) Diagnose connection
  4) Edit configuration
  5) Update (wstunnel / Caddy / script)
  6) Uninstall
```

---

### Useful Commands After Install

```bash
# Relaunch the setup menu
ws

# Service status
systemctl status wstunnel-server.service   # Iran VPS
systemctl status wstunnel-client.service   # Foreign VPS

# Live logs
journalctl -u wstunnel-server.service -f
journalctl -u wstunnel-client.service -f

# Caddy
systemctl status caddy
cat /etc/caddy/Caddyfile

# Restart timers
systemctl list-timers | grep wstunnel
```

---

For the original manual setup reference see [wstunnel_caddy.md](wstunnel_caddy.md).

---
---

<a name="فارسی"></a>
## راه‌اندازی WStunnel + Caddy

اسکریپت bash تعاملی برای ایجاد یک **تونل معکوس WebSocket** بین سرور ایران و یک یا چند سرور خارج با استفاده از [wstunnel](https://github.com/erebe/wstunnel) و [Caddy](https://caddyserver.com).

### مسیر ترافیک

```
دستگاه کاربر
    │
    ▼  TCP/UDP
سرور ایران :PORT  (Caddy — پایان‌دهی TLS روی پورت 443)
    │
    ▼  WSS (wss://domain:443)
wstunnel server  ws://127.0.0.1:2018
    │
    ▼  تونل معکوس WebSocket (-R)
wstunnel client  (سرور خارج)
    │
    ▼  localhost
VPN / سرویس  :LOCAL_PORT
```

---

### نصب سریع

این دستور را **یک‌بار** روی هر VPS اجرا کن — اسکریپت نقش مناسب را خودکار تشخیص می‌دهد:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh)
```

پس از نصب اول، میانبر `ws` در `/usr/local/bin/ws` قرار می‌گیرد.
از آن به بعد فقط کافی است تایپ کنی:

```bash
ws
```

و آخرین نسخه اسکریپت از هر جای سرور اجرا می‌شود.

---

### پیش‌نیازها

| پیش‌نیاز | توضیح |
|---|---|
| دسترسی root / sudo | روی هر دو VPS |
| `curl` | برای دانلود باینری‌ها |
| Debian / Ubuntu | Caddy از طریق apt یا باینری نصب می‌شود |
| دامنه با رکورد DNS A | باید به IP سرور ایران اشاره داشته باشد — برای TLS الزامی است |

---

### چه چیزی نصب می‌شود

| VPS | کامپوننت | جزئیات |
|---|---|---|
| سرور ایران | wstunnel (حالت سرور) | روی `ws://127.0.0.1:2018` گوش می‌دهد (فقط local) |
| سرور ایران | Caddy | پایان‌دهی TLS + پروکسی معکوس به wstunnel |
| سرور ایران | سرویس systemd | `wstunnel-server.service` — هنگام بوت خودکار اجرا می‌شود |
| سرور خارج | wstunnel (حالت کلاینت) | از طریق `wss://domain:443` به خارج متصل می‌شود |
| سرور خارج | سرویس systemd | `wstunnel-client.service` — هنگام بوت خودکار اجرا می‌شود |
| هر دو | میانبر `ws` | `/usr/local/bin/ws` — آخرین اسکریپت را از GitHub اجرا می‌کند |

---

### ویژگی‌ها

**نصب**
- راه‌اندازی تعاملی گام‌به‌گام برای سرور ایران و سرور خارج
- نصب خودکار باینری wstunnel و ایجاد سرویس systemd
- نصب و پیکربندی Caddy با TLS داخلی خودکار
- فعال‌سازی سرویس‌ها هنگام بوت از همان ابتدا

**چند دامنه (سرور ایران)**
- اضافه کردن چند دامنه — هر کدام بلاک Caddy مجزا دارد و به همان پورت wstunnel هدایت می‌شود
- مناسب برای چرخش دامنه یا توزیع بار

**چند لوکیشن (چند سرور خارج)**
- چند سرور خارج می‌توانند همزمان به یک سرور ایران متصل شوند
- هر کلاینت پورت متفاوتی استفاده می‌کند — به صورت native توسط wstunnel پشتیبانی می‌شود
- تشخیص پورت تکراری در هنگام تنظیم از ایجاد تداخل جلوگیری می‌کند

**چند پورت (برای هر سرور خارج)**
- هر کلاینت می‌تواند در یک سرویس چند mapping پورت باز کند
- اضافه، ویرایش یا حذف هر mapping از منوی Edit

**ری‌استارت خودکار زمان‌بندی شده**
- تنظیم ری‌استارت دوره‌ای تونل (هر ۲ / ۳ / ۴ / ۶ / ۸ / ۱۲ ساعت)
- با systemd timer پیاده‌سازی شده — بدون نیاز به cron
- از منوی Edit قابل تغییر است، بدون نیاز به نصب مجدد

**منوی Edit**
- *سرور ایران*: اضافه/حذف دامنه، تغییر Bind IP و پورت، تنظیم ری‌استارت خودکار
- *سرور خارج*: اضافه/ویرایش/حذف mapping پورت، تغییر دامنه و پورت WSS، تنظیم ری‌استارت خودکار

**تشخیص مشکل (Diagnose)**
- بررسی وضعیت سرویس wstunnel، وضعیت Caddy، دسترسی به پورت‌ها و قوانین فایروال
- تشخیص خودکار خطاهای رایج با راهنمای رفع آن‌ها

**بروزرسانی**
- بروزرسانی باینری wstunnel به هر نسخه دلخواه
- بروزرسانی باینری Caddy (اگر توسط اسکریپت نصب شده باشد)
- بروزرسانی میانبر `ws` به آخرین نسخه از GitHub
- ری‌استارت خودکار سرویس‌های مرتبط

**حذف کامل**
- حذف باینری wstunnel، فایل‌های سرویس systemd و کاربر `wstunnel`
- حذف Caddy (باینری یا apt)، کانفیگ، کاربر و منبع apt
- حذف تمام فایل‌های timer ری‌استارت
- اگر Caddy از قبل نصب بوده، فقط بلاک‌های اضافه‌شده توسط این اسکریپت حذف می‌شوند

---

### بهینه‌سازی‌های عملکرد و پایداری

اسکریپت به صورت خودکار تنظیمات زیر را اعمال می‌کند:

**Caddy (سرور ایران)**
| تنظیم | مقدار | دلیل |
|---|---|---|
| `protocols h1` | فقط HTTP/1.1 | جلوگیری از مشکلات ALPN در HTTP/2 با wstunnel |
| `enable_full_duplex` | فعال | امکان خواندن و نوشتن همزمان روی اتصال HTTP/1.1 |
| `flush_interval -1` | فوری | ارسال بلادرنگ داده‌های WebSocket بدون بافرینگ |
| `reverse_proxy 127.0.0.1:…` | IP مستقیم | جلوگیری از timeout DNS برای `localhost` در زیر بار |
| `response_header_timeout 0` | بدون timeout | حفظ اتصال‌های WebSocket طولانی‌مدت |
| `LimitNOFILE` | ۱٬۰۴۸٬۵۷۶ | پشتیبانی از تعداد زیاد اتصال همزمان |

**wstunnel (هر دو سرور)**
| تنظیم | مقدار | دلیل |
|---|---|---|
| `--websocket-ping-frequency-sec` | ۳۰ ثانیه | زنده نگه داشتن اتصال از طریق فایروال‌های ایدل |
| `--connection-min-idle` | ۵ | آماده نگه داشتن ۵ اتصال — کاهش تأخیر اتصال اول کاربر |
| `LimitNOFILE` | ۶۵٬۵۳۶ | پشتیبانی از اتصال‌های همزمان زیاد |
| `TasksMax` | ۶۵٬۵۳۶ | جلوگیری از رسیدن systemd به محدودیت پیش‌فرض (~۱۰۲۷) |
| `RestartSec` (سرور) | ۵ ثانیه | بازیابی سریع پس از crash |
| `RestartSec` (کلاینت) | ۲۰ ثانیه | جلوگیری از reconnect storm در خطاهای پشت‌سرهم |

**کرنل (سرور ایران — هنگام نصب خودکار اعمال می‌شود)**
| پارامتر | مقدار | دلیل |
|---|---|---|
| `net.ipv4.tcp_max_syn_backlog` | ۴۰۹۶ | پشتیبانی از burst reconnect (پیش‌فرض ۱۲۸ در ۸۰۰+ اتصال drop ایجاد می‌کند) |
| `net.core.netdev_max_backlog` | ۴۰۹۶ | افزایش عمق صف دریافت شبکه |
| `net.ipv4.tcp_syn_retries` | ۳ | شکست سریع‌تر روی مسیرهای مرده |
| `net.ipv4.tcp_fin_timeout` | ۱۵ ثانیه | آزادسازی سریع‌تر socket‌های بسته |
| `net.ipv4.tcp_tw_reuse` | ۱ | استفاده مجدد از socket‌های در حالت TIME_WAIT |

---

### تنظیم DNS

قبل از اجرای اسکریپت، دامنه‌ات را به IP سرور ایران اشاره بده:

```
tunnel.yourdomain.com  A  <IP_سرور_ایران>
```

پس از انتشار DNS، Caddy به صورت خودکار گواهی TLS صادر می‌کند.

---

### نمای کلی منو

```
What would you like to do?
  1) Install — Iran VPS (server)      ← نصب روی سرور ایران
  2) Install — Foreign VPS (client)   ← نصب روی سرور خارج
  3) Diagnose connection              ← تشخیص مشکل
  4) Edit configuration               ← ویرایش تنظیمات
  5) Update (wstunnel / Caddy / script) ← بروزرسانی
  6) Uninstall                        ← حذف کامل
```

---

### دستورات مفید بعد از نصب

```bash
# اجرای مجدد منوی اسکریپت
ws

# وضعیت سرویس‌ها
systemctl status wstunnel-server.service   # سرور ایران
systemctl status wstunnel-client.service   # سرور خارج

# لاگ‌های زنده
journalctl -u wstunnel-server.service -f
journalctl -u wstunnel-client.service -f

# Caddy
systemctl status caddy
cat /etc/caddy/Caddyfile

# تایمرهای ری‌استارت
systemctl list-timers | grep wstunnel
```

---

برای راهنمای دستی نصب اولیه به [wstunnel_caddy.md](wstunnel_caddy.md) مراجعه کن.
