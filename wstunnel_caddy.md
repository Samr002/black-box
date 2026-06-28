# WStunnel Setup Guide — Manual Reference

> **Note:** The interactive script in this repo handles all of the steps below automatically.
> Use the script for new setups — this document is kept as a low-level reference only.
>
> ```bash
> bash <(curl -fsSL https://raw.githubusercontent.com/Samr002/black-box/black-box-v2/setup.sh)
> ```

---

Setup WebSocket tunnels between Iran VPS (server) and Foreign VPS (client). Domain `tunnel.yourdomain.com` must point to Iran VPS IP.

## Prerequisites

- Iran VPS (server)
- Foreign VPS (client)
- Domain with SSL certificate (tunnel.yourdomain.com) pointing to Iran VPS IP
- Caddy installed on Iran VPS
- Root or sudo access on both

## DNS Setup

Point your domain to Iran VPS IP:

```
tunnel.yourdomain.com  A  <IRAN_VPS_IP>
```

Replace `<IRAN_VPS_IP>` with your Iran VPS public IP address. Wait for DNS propagation before proceeding.

## Installation

### Both VPS

```bash
cd /tmp
wget https://github.com/erebe/wstunnel/releases/download/v10.5.5/wstunnel_10.5.5_linux_amd64.tar.gz
tar xzf wstunnel_10.5.5_linux_amd64.tar.gz
sudo mv wstunnel /usr/local/bin/
sudo chmod +x /usr/local/bin/wstunnel
wstunnel --version
```

## Iran VPS Setup (Server)

### 1. Create systemd service

```bash
sudo nano /etc/systemd/system/wstunnel-server.service
```

Paste:
```ini
[Unit]
Description=WStunnel Server
After=network.target

[Service]
Type=simple
User=wstunnel
Group=wstunnel
WorkingDirectory=/home/wstunnel
ExecStart=/usr/local/bin/wstunnel server ws://127.0.0.1:2018
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 2. Setup user and directories

```bash
sudo useradd -r -s /bin/false wstunnel
sudo mkdir -p /home/wstunnel
sudo chown wstunnel:wstunnel /home/wstunnel
```

### 3. Start service

```bash
sudo systemctl daemon-reload
sudo systemctl enable wstunnel-server.service
sudo systemctl start wstunnel-server.service
sudo systemctl status wstunnel-server.service
```

### 4. Update Caddy config

Add to your Caddyfile:

```caddy
tunnel.yourdomain.com {
    reverse_proxy localhost:2018
}
```

Reload Caddy:
```bash
sudo systemctl reload caddy
```

## Foreign VPS Setup (Client)

### 1. Create systemd service

```bash
sudo nano /etc/systemd/system/wstunnel-client.service
```

Paste:
```ini
[Unit]
Description=WStunnel Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=wstunnel
Group=wstunnel
WorkingDirectory=/home/wstunnel
ExecStart=/usr/local/bin/wstunnel client -R tcp://0.0.0.0:8443:localhost:8443 wss://tunnel.yourdomain.com:443
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 2. Setup user and directories

```bash
sudo useradd -r -s /bin/false wstunnel
sudo mkdir -p /home/wstunnel
sudo chown wstunnel:wstunnel /home/wstunnel
```

### 3. Start service

```bash
sudo systemctl daemon-reload
sudo systemctl enable wstunnel-client.service
sudo systemctl start wstunnel-client.service
sudo systemctl status wstunnel-client.service
```

## Testing

### Check services

```bash
sudo systemctl status wstunnel-server.service
sudo systemctl status wstunnel-client.service
```

### View logs

Iran VPS:
```bash
sudo journalctl -u wstunnel-server.service -f
```

Foreign VPS:
```bash
sudo journalctl -u wstunnel-client.service -f
```

### Test connectivity

From Foreign VPS, verify port 8443 is open:
```bash
ss -tlnp | grep 8443
```

Should show:
```
LISTEN 0 128 0.0.0.0:8443 0.0.0.0:*
```

## Tunnel Usage

Once running, traffic sent to Foreign VPS port 8443 will tunnel through Caddy on Iran VPS to localhost:2018.

Connect via Foreign VPS:
```bash
curl -k https://localhost:8443
```

## Troubleshooting

### Connection refused on client

- Verify Caddy is running on Iran VPS: `sudo systemctl status caddy`
- Check Caddy config: `sudo caddy validate --config /etc/caddy/Caddyfile`
- Verify domain resolves to Iran VPS IP: `nslookup tunnel.yourdomain.com`

### Client fails to start

- Check certificate validity: `openssl s_client -connect tunnel.yourdomain.com:443`
- Review client logs: `sudo journalctl -u wstunnel-client.service -n 50`

### High latency

- Verify network path: `mtr tunnel.yourdomain.com`
- Check Iran VPS resources: `top`, `free -h`

### Port already in use

```bash
sudo lsof -i :2018
sudo lsof -i :8443
```

Kill process if needed:
```bash
sudo kill -9 <PID>
```

## Stopping/Restarting

```bash
sudo systemctl stop wstunnel-server.service
sudo systemctl restart wstunnel-client.service
```

## References

- WStunnel: https://github.com/erebe/wstunnel
- Caddy Docs: https://caddyserver.com/docs
