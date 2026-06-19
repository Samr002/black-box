# black-box

A personal collection of code snippets, technical notes, and quick documentation.

---

## WStunnel + Caddy Setup

Sets up a WebSocket tunnel between an Iran VPS (server) and a Foreign VPS (client) using [wstunnel](https://github.com/erebe/wstunnel) and Caddy.

### Quick Install

Run this single command on either VPS — the script will ask which one you are on:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh)
```

> Requires `curl` and `sudo`/root access. The script installs wstunnel, creates a systemd service, and guides you through the configuration interactively.

### What the script sets up

| VPS | Role | What gets installed |
|---|---|---|
| Iran VPS | Server | wstunnel in server mode + Caddy reverse proxy block |
| Foreign VPS | Client | wstunnel in client mode connecting outbound via WSS |

### Manual usage

```bash
# Download
wget https://raw.githubusercontent.com/Samr002/black-box/main/setup.sh

# Run
sudo bash setup.sh
```

For full setup details see [wstunnel_caddy.md](wstunnel_caddy.md).
