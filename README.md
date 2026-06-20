# black-box

A personal collection of code snippets, technical notes, and quick documentation.

---

## WStunnel + Caddy Setup

Interactive bash script that sets up a **WebSocket reverse tunnel** between an Iran VPS (server) and one or more Foreign VPS machines (clients) using [wstunnel v10.5.5](https://github.com/erebe/wstunnel) and [Caddy](https://caddyserver.com).

### Traffic Flow

```
User → Iran VPS :PORT  ──(-R reverse tunnel)──►  Foreign VPS :LOCAL_PORT (VPN / service)
            ▲
         Caddy TLS
       domain:443
            ▲
     wstunnel server
     ws://127.0.0.1:2018
```

---

### Quick Install

Run this **once** on either VPS — the script detects which role to set up:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh)
```

After the first install, a `ws` shortcut is placed at `/usr/local/bin/ws`.  
From that point on, just type:

```bash
ws
```

to relaunch the latest version of the script from anywhere on the server — no need to re-run the install command.

---

### Requirements

| Requirement | Notes |
|---|---|
| Root / sudo access | Both VPS machines |
| `curl` | For downloading binaries |
| Debian / Ubuntu | Script installs Caddy via apt or binary |
| Domain pointing to Iran VPS | DNS A record required for TLS |

---

### What Gets Installed

| VPS | Component | Details |
|---|---|---|
| Iran VPS | wstunnel (server mode) | Listens on `ws://127.0.0.1:2018` (local only) |
| Iran VPS | Caddy | Reverse proxy — terminates TLS, forwards to wstunnel |
| Iran VPS | systemd service | `wstunnel-server.service` (auto-start on reboot) |
| Foreign VPS | wstunnel (client mode) | Connects outbound via `wss://domain:443` |
| Foreign VPS | systemd service | `wstunnel-client.service` (auto-start on reboot) |
| Both | `ws` shortcut | `/usr/local/bin/ws` — reruns latest script from GitHub |

---

### Features

**Installation**
- Interactive guided setup for Iran VPS (server) and Foreign VPS (client)
- Automatically installs wstunnel binary and creates systemd service
- Installs and configures Caddy (via apt or binary) with automatic TLS
- Enables services on boot (`systemctl enable`) out of the box

**Multi-Domain (Iran VPS)**
- Add multiple domain names during install — each gets its own Caddy block routing to the same wstunnel port
- All domains handled natively by Caddy; no extra wstunnel instances needed

**Multi-Location (Multiple Foreign VPS)**
- Multiple Foreign VPS servers can connect to the same Iran VPS simultaneously
- Each client uses a different port number (e.g. `8443`, `9443`, `7443`) — natively supported by wstunnel

**Multiple Port Mappings (per Foreign VPS)**
- Each client can open multiple reverse-tunnel ports in a single service
- Manage individual mappings from the Edit menu

**Scheduled Auto-Restart**
- Configure periodic tunnel restarts (every 1 / 2 / 3 / 4 / 6 / 8 / 12 hours)
- Implemented via systemd timers — no cron required
- Configurable from the Edit menu without touching the main config

**Edit Menu**
- *Iran VPS*: add / remove domains, change bind IP & port, configure auto-restart — all without reinstalling
- *Foreign VPS*: add / edit / remove port mappings, change domain & WSS port, configure auto-restart

**Diagnose**
- Checks wstunnel service status, Caddy status, port reachability, firewall rules, and common misconfigurations
- Detects `--restrict-to` blocking and reports clear fix instructions

**Update**
- Updates **wstunnel** binary to a chosen version
- Updates **Caddy** binary (if installed by the script)
- Refreshes the **`ws` script shortcut** to the latest version from GitHub
- Restarts affected services automatically

**Full Uninstall**
- Removes wstunnel binary, systemd service files, and `wstunnel` user
- Removes Caddy (binary-installed or apt-installed), its config, user, and apt repo
- Removes all systemd restart timer files
- If Caddy was pre-existing, only removes the blocks added by the script

---

### DNS Setup

Point your domain to the Iran VPS IP before running the script:

```
tunnel.yourdomain.com  A  <IRAN_VPS_IP>
```

Caddy handles TLS automatically once DNS propagates.

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
# Relaunch the setup script
ws

# Check service status
systemctl status wstunnel-server.service   # Iran VPS
systemctl status wstunnel-client.service   # Foreign VPS

# View live logs
journalctl -u wstunnel-server.service -f
journalctl -u wstunnel-client.service -f

# Check Caddy
systemctl status caddy
cat /etc/caddy/Caddyfile

# Check restart timers
systemctl list-timers | grep wstunnel
```

---

For the original manual setup reference see [wstunnel_caddy.md](wstunnel_caddy.md).
