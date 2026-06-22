# black-box

> **[English](#english)** | **[فارسی](#فارسی)**

---

<a name="english"></a>
## WStunnel + Caddy Setup

An interactive bash script that sets up a **WebSocket reverse tunnel** between an Iran VPS (server) and one or more Foreign VPS machines (clients) using [wstunnel](https://github.com/erebe/wstunnel) and [Caddy](https://caddyserver.com).

The tunnel traffic is disguised as regular HTTPS API calls, making it resistant to DPI-based blocking.

### Traffic Flow

```
User Device
    │
    ▼  TCP/UDP
Iran VPS :PORT  (Caddy — TLS on :443, path obfuscation)
    │
    ▼  WSS (wss://domain:443/secret-path)
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
bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/WS-V2/setup.sh)
```

After the first install, a `ws` shortcut is placed at `/usr/local/bin/ws`.
From that point on, just run:

```bash
ws
```

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
| Iran VPS | Caddy | TLS termination + path-based routing to wstunnel |
| Iran VPS | systemd service | `wstunnel-server.service` — auto-starts on boot |
| Foreign VPS | wstunnel (client mode) | Connects outbound via `wss://domain:443` |
| Foreign VPS | Caddy CA cert | Iran VPS self-signed CA installed in system trust store |
| Foreign VPS | systemd service | `wstunnel-client.service` — auto-starts on boot |
| Both | `ws` shortcut | `/usr/local/bin/ws` — reruns latest script from GitHub |

---

### Features

**Installation**
- Interactive guided setup for Iran VPS (server) and Foreign VPS (client)
- Automatically installs wstunnel binary and creates systemd service
- Installs and configures Caddy with automatic internal TLS (`tls internal`)
- Enables services on boot out of the box

**Anti-Detection / DPI Evasion**
- **WebSocket path obfuscation** — Caddy routes only requests to a secret path (e.g. `/live/stream/abc123`) to wstunnel; all other paths return 404. The path is set with `--http-upgrade-path-prefix` on the client, not in the URL (wstunnel v10 ignores URL paths)
- **DNS protection** — client uses `--dns-resolver dns://1.1.1.1` to bypass local DNS manipulation and prevent DNS leaks
- **HTTP header spoofing** — client sends a realistic browser `User-Agent` and a valid `Origin` header, making WebSocket handshakes indistinguishable from browser traffic
- **`header -Server`** — Caddy removes the `Server` response header to reduce fingerprinting

**TLS Trust (Foreign VPS)**
- Iran VPS uses `tls internal` (self-signed CA) — no public CA required, no domain validation delays
- During client install, the script guides you through pasting the Iran VPS CA certificate and installs it system-wide via `update-ca-certificates`
- Certificate is validated with OpenSSL before being written to the trust store

**Multi-Domain (Iran VPS)**
- Add multiple domain names — each gets its own Caddy block with the obfuscated path routing
- Useful for domain rotation or connecting multiple Foreign VPS machines

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
- *Iran VPS*: add/remove domains, change upgrade path, change bind IP & port, configure auto-restart
- *Foreign VPS*: add/edit/remove port mappings, change domain & WSS port, change upgrade path, configure auto-restart

**Diagnose**
- Checks wstunnel service status, Caddy status, port reachability, and TLS trust
- Detects `--restrict-to` and `--restrict-http-upgrade-path-prefix` flags (both break reverse tunnels in wstunnel v10) and provides exact fix commands
- Detects upgrade path mismatch between client and Caddyfile
- Detects missing CA certificate on Foreign VPS and provides install instructions

**Update**
- Updates wstunnel binary to any chosen version
- Updates Caddy binary (if installed by the script)
- Refreshes the `ws` script shortcut to the latest version from GitHub
- Restarts affected services automatically

**Full Uninstall**
- Removes wstunnel binary, systemd service files, and the `wstunnel` user
- Removes Caddy (binary or apt), its config (`/etc/caddy/`), data (`/var/lib/caddy/`), logs, user, and apt repo
- Removes Caddy CA certificate from `/usr/local/share/ca-certificates/` and the corresponding symlink from `/etc/ssl/certs/`, then runs `update-ca-certificates`
- Removes all systemd restart timer files
- Removes kernel TCP tuning parameters from `/etc/sysctl.conf`
- If Caddy was pre-existing, only removes the blocks added by this script
- Correctly detects leftover CA certs even if service files were already removed manually

---

### Performance & Stability Optimizations

The script automatically applies the following during install:

**Caddy (Iran VPS)**
| Setting | Value | Reason |
|---|---|---|
| `protocols h1` | HTTP/1.1 only | Prevents HTTP/2 ALPN negotiation issues with wstunnel |
| `enable_full_duplex` | on | Allows simultaneous read/write on HTTP/1.1 connections |
| `handle /path*` | path routing | Only the secret path reaches wstunnel; everything else returns 404 |
| `flush_interval -1` | immediate | Enables real-time WebSocket streaming without buffering |
| `reverse_proxy 127.0.0.1:…` | IP literal | Avoids DNS resolution timeout for `localhost` under load |
| `response_header_timeout 0` | no timeout | Prevents proxy from closing long-lived WebSocket connections |
| `header -Server` | removed | Reduces server fingerprinting |
| `LimitNOFILE` | 1 048 576 | Supports large numbers of open file descriptors |

**wstunnel client (Foreign VPS)**
| Setting | Value | Reason |
|---|---|---|
| `--websocket-ping-frequency-sec` | 30 s | Keeps connections alive through idle firewalls |
| `--connection-min-idle` | 5 | Pre-warms connections — reduces latency on first user connect |
| `--dns-resolver dns://1.1.1.1` | Cloudflare DNS over UDP | Bypasses local DNS manipulation; prevents DNS leaks |
| `--http-headers User-Agent` | Chrome 120 UA string | WebSocket handshake looks like a real browser request |
| `--http-headers Origin` | `https://DOMAIN` | Valid Origin header — matches what a browser would send |
| `--http-upgrade-path-prefix` | secret path | Sends upgrade request to the correct obfuscated path (URL path is ignored by wstunnel v10) |
| `LimitNOFILE` | 65 536 | Handles many simultaneous tunnel connections |
| `TasksMax` | 65 536 | Prevents systemd from hitting the default task limit (~1027) |
| `RestartSec` | 20 s | Prevents reconnect storms on repeated failures |

**wstunnel server (Iran VPS)**
| Setting | Value | Reason |
|---|---|---|
| `--websocket-ping-frequency-sec` | 30 s | Keeps connections alive through idle firewalls |
| No `--restrict-to` | — | This flag blocks ALL reverse tunnel connections in wstunnel v10; path restriction is done by Caddy instead |
| `RestartSec` | 5 s | Fast recovery after crash |

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
  1) Install   — Iran VPS     (wstunnel server + Caddy entry point)
  2) Install   — Foreign VPS  (wstunnel client, hosts the VPN service)
  3) Diagnose  — check tunnel health layer by layer
  4) Edit      — manage ports, domain, and upgrade path on this machine
  5) Update    — upgrade wstunnel binary to a newer version
  6) Restart   — manually restart all tunnel services
  7) Uninstall — remove wstunnel completely from this machine
  8) Exit
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

### Important Notes

**Upgrade path must match on all machines.**
When the Iran VPS is reinstalled, a new upgrade path is generated. All Foreign VPS clients must be updated to use the new path — otherwise they will receive 404 errors. The script displays the path prominently after server install and validates the input to prevent accidental corruption.

**CA certificate must be reinstalled after server reinstall.**
`tls internal` generates a new CA on each fresh install. After reinstalling the Iran VPS, re-run the client install wizard on each Foreign VPS to update the trusted CA certificate.

---

For the original manual setup reference see [wstunnel_caddy.md](wstunnel_caddy.md).

---
---

<a name="فارسی"></a>
## راه‌اندازی WStunnel + Caddy

اسکریپت bash تعاملی برای ایجاد یک **تونل معکوس WebSocket** بین سرور ایران و یک یا چند سرور خارج با استفاده از [wstunnel](https://github.com/erebe/wstunnel) و [Caddy](https://caddyserver.com).

ترافیک تونل به شکل درخواست‌های HTTPS معمولی API پنهان می‌شود و در برابر فیلترینگ مبتنی بر DPI مقاوم است.

### مسیر ترافیک

```
دستگاه کاربر
    │
    ▼  TCP/UDP
سرور ایران :PORT  (Caddy — TLS روی پورت 443، مسیر مخفی)
    │
    ▼  WSS (wss://domain:443/مسیر-مخفی)
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
bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/WS-V2/setup.sh)
```

پس از نصب اول، میانبر `ws` در `/usr/local/bin/ws` قرار می‌گیرد:

```bash
ws
```

---

### پیش‌نیازها

| پیش‌نیاز | توضیح |
|---|---|
| دسترسی root / sudo | روی هر دو VPS |
| `curl` | برای دانلود باینری‌ها |
| Debian / Ubuntu | Caddy از طریق apt یا باینری نصب می‌شود |
| دامنه با رکورد DNS A | باید به IP سرور ایران اشاره داشته باشد |

---

### چه چیزی نصب می‌شود

| VPS | کامپوننت | جزئیات |
|---|---|---|
| سرور ایران | wstunnel (حالت سرور) | روی `ws://127.0.0.1:2018` گوش می‌دهد (فقط local) |
| سرور ایران | Caddy | پایان‌دهی TLS + مسیریابی مبتنی بر path به wstunnel |
| سرور ایران | سرویس systemd | `wstunnel-server.service` — هنگام بوت خودکار اجرا می‌شود |
| سرور خارج | wstunnel (حالت کلاینت) | از طریق `wss://domain:443` به خارج متصل می‌شود |
| سرور خارج | CA cert کادی | گواهی CA سرور ایران در trust store سیستم نصب می‌شود |
| سرور خارج | سرویس systemd | `wstunnel-client.service` — هنگام بوت خودکار اجرا می‌شود |
| هر دو | میانبر `ws` | `/usr/local/bin/ws` — آخرین اسکریپت را از GitHub اجرا می‌کند |

---

### ویژگی‌ها

**نصب**
- راه‌اندازی تعاملی گام‌به‌گام برای سرور ایران و سرور خارج
- نصب خودکار باینری wstunnel و ایجاد سرویس systemd
- نصب و پیکربندی Caddy با TLS داخلی خودکار (`tls internal`)
- فعال‌سازی سرویس‌ها هنگام بوت از همان ابتدا

**ضد شناسایی / دور زدن DPI**
- **مسیر مخفی WebSocket** — Caddy فقط درخواست‌های با path مخفی (مثلاً `/live/stream/abc123`) را به wstunnel هدایت می‌کند؛ بقیه مسیرها 404 برمی‌گردانند. path با `--http-upgrade-path-prefix` در کلاینت تنظیم می‌شود (wstunnel نسخه ۱۰ path URL را نادیده می‌گیرد)
- **محافظت DNS** — کلاینت از `--dns-resolver dns://1.1.1.1` استفاده می‌کند تا از دستکاری DNS محلی و DNS leak جلوگیری کند
- **جعل هدر HTTP** — کلاینت یک `User-Agent` واقعی مرورگر و هدر `Origin` معتبر ارسال می‌کند تا WebSocket handshake از ترافیک مرورگر قابل تشخیص نباشد
- **`header -Server`** — Caddy هدر `Server` را از پاسخ حذف می‌کند تا fingerprinting کمتر شود

**اعتماد TLS (سرور خارج)**
- سرور ایران از `tls internal` (CA خود-امضا) استفاده می‌کند — بدون نیاز به CA عمومی
- در حین نصب کلاینت، اسکریپت راهنمایی می‌کند که CA cert سرور ایران را paste کنید و آن را با `update-ca-certificates` در سیستم نصب می‌کند
- گواهی قبل از نوشتن در trust store با OpenSSL اعتبارسنجی می‌شود

**چند دامنه (سرور ایران)**
- اضافه کردن چند دامنه — هر کدام بلاک Caddy مجزا با مسیر مخفی دارد
- مناسب برای چرخش دامنه یا اتصال چند سرور خارج

**چند لوکیشن (چند سرور خارج)**
- چند سرور خارج می‌توانند همزمان به یک سرور ایران متصل شوند
- هر کلاینت پورت متفاوتی استفاده می‌کند
- تشخیص پورت تکراری در هنگام تنظیم از ایجاد تداخل جلوگیری می‌کند

**چند پورت (برای هر سرور خارج)**
- هر کلاینت می‌تواند در یک سرویس چند mapping پورت باز کند
- اضافه، ویرایش یا حذف هر mapping از منوی Edit

**ری‌استارت خودکار زمان‌بندی شده**
- تنظیم ری‌استارت دوره‌ای تونل (هر ۲ / ۳ / ۴ / ۶ / ۸ / ۱۲ ساعت)
- با systemd timer پیاده‌سازی شده — بدون نیاز به cron
- از منوی Edit قابل تغییر است، بدون نیاز به نصب مجدد

**منوی Edit**
- *سرور ایران*: اضافه/حذف دامنه، تغییر مسیر مخفی، تغییر Bind IP و پورت، تنظیم ری‌استارت
- *سرور خارج*: اضافه/ویرایش/حذف mapping پورت، تغییر دامنه و پورت WSS، تغییر مسیر مخفی، تنظیم ری‌استارت

**تشخیص مشکل (Diagnose)**
- بررسی وضعیت سرویس wstunnel، وضعیت Caddy، دسترسی به پورت‌ها و اعتماد TLS
- تشخیص فلگ‌های `--restrict-to` و `--restrict-http-upgrade-path-prefix` (هر دو تونل معکوس را در wstunnel v10 خراب می‌کنند) با دستور دقیق رفع
- تشخیص عدم تطابق مسیر مخفی بین کلاینت و Caddyfile
- تشخیص نبود CA cert روی سرور خارج با راهنمای نصب

**بروزرسانی**
- بروزرسانی باینری wstunnel به هر نسخه دلخواه
- بروزرسانی باینری Caddy (اگر توسط اسکریپت نصب شده باشد)
- بروزرسانی میانبر `ws` به آخرین نسخه از GitHub
- ری‌استارت خودکار سرویس‌های مرتبط

**حذف کامل**
- حذف باینری wstunnel، فایل‌های سرویس systemd و کاربر `wstunnel`
- حذف Caddy (باینری یا apt)، کانفیگ (`/etc/caddy/`)، داده (`/var/lib/caddy/`)، لاگ‌ها، کاربر و منبع apt
- حذف CA cert کادی از `/usr/local/share/ca-certificates/` و symlink مربوطه از `/etc/ssl/certs/` و اجرای `update-ca-certificates`
- حذف تمام فایل‌های timer ری‌استارت
- حذف پارامترهای kernel TCP tuning از `/etc/sysctl.conf`
- اگر Caddy از قبل نصب بوده، فقط بلاک‌های اضافه‌شده حذف می‌شوند
- تشخیص صحیح CA cert باقی‌مانده حتی اگر service file به صورت دستی حذف شده باشد

---

### بهینه‌سازی‌های عملکرد و پایداری

**Caddy (سرور ایران)**
| تنظیم | مقدار | دلیل |
|---|---|---|
| `protocols h1` | فقط HTTP/1.1 | جلوگیری از مشکلات ALPN در HTTP/2 با wstunnel |
| `enable_full_duplex` | فعال | امکان خواندن و نوشتن همزمان روی اتصال HTTP/1.1 |
| `handle /path*` | مسیریابی path | فقط مسیر مخفی به wstunnel می‌رسد، بقیه ۴۰۴ |
| `flush_interval -1` | فوری | ارسال بلادرنگ داده‌های WebSocket بدون بافرینگ |
| `reverse_proxy 127.0.0.1:…` | IP مستقیم | جلوگیری از timeout DNS برای `localhost` زیر بار |
| `response_header_timeout 0` | بدون timeout | حفظ اتصال‌های WebSocket طولانی‌مدت |
| `header -Server` | حذف شده | کاهش fingerprinting سرور |
| `LimitNOFILE` | ۱٬۰۴۸٬۵۷۶ | پشتیبانی از اتصال‌های زیاد همزمان |

**wstunnel کلاینت (سرور خارج)**
| تنظیم | مقدار | دلیل |
|---|---|---|
| `--websocket-ping-frequency-sec` | ۳۰ ثانیه | زنده نگه داشتن اتصال از طریق فایروال‌های ایدل |
| `--connection-min-idle` | ۵ | آماده نگه داشتن ۵ اتصال — کاهش تأخیر |
| `--dns-resolver dns://1.1.1.1` | DNS مستقیم | دور زدن دستکاری DNS محلی و جلوگیری از DNS leak |
| `--http-headers User-Agent` | Chrome 120 | WebSocket handshake شبیه مرورگر واقعی |
| `--http-headers Origin` | `https://DOMAIN` | هدر Origin معتبر — مشابه درخواست مرورگر |
| `--http-upgrade-path-prefix` | مسیر مخفی | ارسال درخواست upgrade به مسیر صحیح (URL path در wstunnel v10 نادیده گرفته می‌شود) |
| `LimitNOFILE` | ۶۵٬۵۳۶ | پشتیبانی از اتصال‌های همزمان زیاد |
| `TasksMax` | ۶۵٬۵۳۶ | جلوگیری از رسیدن systemd به محدودیت پیش‌فرض |
| `RestartSec` | ۲۰ ثانیه | جلوگیری از reconnect storm در خطاهای پشت‌سرهم |

**wstunnel سرور (سرور ایران)**
| تنظیم | مقدار | دلیل |
|---|---|---|
| `--websocket-ping-frequency-sec` | ۳۰ ثانیه | زنده نگه داشتن اتصال |
| بدون `--restrict-to` | — | این فلگ در wstunnel v10 همه تونل‌های معکوس را مسدود می‌کند؛ محدودیت path توسط Caddy انجام می‌شود |
| `RestartSec` | ۵ ثانیه | بازیابی سریع پس از crash |

**کرنل (سرور ایران — هنگام نصب خودکار اعمال می‌شود)**
| پارامتر | مقدار | دلیل |
|---|---|---|
| `net.ipv4.tcp_max_syn_backlog` | ۴۰۹۶ | پشتیبانی از burst reconnect |
| `net.core.netdev_max_backlog` | ۴۰۹۶ | افزایش عمق صف دریافت شبکه |
| `net.ipv4.tcp_syn_retries` | ۳ | شکست سریع‌تر روی مسیرهای مرده |
| `net.ipv4.tcp_fin_timeout` | ۱۵ ثانیه | آزادسازی سریع‌تر socket‌های بسته |
| `net.ipv4.tcp_tw_reuse` | ۱ | استفاده مجدد از socket‌های TIME_WAIT |

---

### تنظیم DNS

قبل از اجرای اسکریپت، دامنه را به IP سرور ایران اشاره بده:

```
tunnel.yourdomain.com  A  <IP_سرور_ایران>
```

پس از انتشار DNS، Caddy به صورت خودکار گواهی TLS صادر می‌کند.

---

### نمای کلی منو

```
What would you like to do?
  1) Install   — Iran VPS     (نصب روی سرور ایران)
  2) Install   — Foreign VPS  (نصب روی سرور خارج)
  3) Diagnose  — بررسی سلامت تونل لایه به لایه
  4) Edit      — مدیریت پورت، دامنه و مسیر مخفی
  5) Update    — بروزرسانی باینری wstunnel
  6) Restart   — ری‌استارت دستی همه سرویس‌های تونل
  7) Uninstall — حذف کامل wstunnel از این سرور
  8) Exit
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

### نکات مهم

**مسیر مخفی باید روی همه سرورها یکسان باشد.**
هر بار که سرور ایران دوباره نصب می‌شود، یک مسیر جدید تولید می‌شود. همه سرورهای خارج باید با مسیر جدید بروزرسانی شوند — در غیر این صورت خطای ۴۰۴ می‌گیرند. اسکریپت این مسیر را بعد از نصب سرور به وضوح نمایش می‌دهد و ورودی را اعتبارسنجی می‌کند تا از خرابی تصادفی جلوگیری شود.

**بعد از نصب مجدد سرور، CA cert باید دوباره نصب شود.**
`tls internal` در هر نصب تازه یک CA جدید تولید می‌کند. بعد از نصب مجدد سرور ایران، ویزارد نصب کلاینت را روی هر سرور خارج دوباره اجرا کن تا CA cert بروزرسانی شود.

---

برای راهنمای دستی نصب اولیه به [wstunnel_caddy.md](wstunnel_caddy.md) مراجعه کن.
