# WStunnel Setup Guide

Setup WebSocket tunnels between Server VPS and Client VPS. Uses example domain `tunnel.yourdomain.com`.

## Prerequisites

- Two VPS instances: Server and Client
- Domain with SSL certificate (tunnel.yourdomain.com)
- Caddy installed and running
- Root or sudo access

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

## Server VPS Setup

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

## Client VPS Setup

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

Server VPS:
```bash
sudo journalctl -u wstunnel-server.service -f
```

Client VPS:
```bash
sudo journalctl -u wstunnel-client.service -f
```

### Test connectivity

From Client VPS, verify port 8443 is open:
```bash
ss -tlnp | grep 8443
```

Should show:
```
LISTEN 0 128 0.0.0.0:8443 0.0.0.0:*
```

## Tunnel Usage

Once running, traffic sent to Client VPS port 8443 will tunnel through Caddy on Server VPS to localhost:2018.

Connect via Client VPS:
```bash
curl -k https://localhost:8443
```

## Troubleshooting

### Connection refused on client

- Verify Caddy is running on Server VPS: `sudo systemctl status caddy`
- Check Caddy config: `sudo caddy validate --config /etc/caddy/Caddyfile`
- Verify domain resolves: `nslookup tunnel.yourdomain.com`

### Client fails to start

- Check certificate validity: `openssl s_client -connect tunnel.yourdomain.com:443`
- Review client logs: `sudo journalctl -u wstunnel-client.service -n 50`

### High latency

- Verify network path: `mtr tunnel.yourdomain.com`
- Check Server VPS resources: `top`, `free -h`

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
