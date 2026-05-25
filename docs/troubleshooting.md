# Troubleshooting Guide

## Quick Diagnostics

```bash
# Full status dashboard
autoscript-status

# Run health check manually
autoscript-health-check

# View recent logs
tail -100 /var/log/vps-autoscript/autoscript.log

# View Xray logs
tail -50 /var/log/xray/error.log

# View Nginx logs
tail -50 /var/log/nginx/error.log
```

## Common Issues

### Xray not starting

**Symptom:** `systemctl status xray` shows failed.

**Check:**
```bash
# Validate config.json
python3 -m json.tool /etc/xray/config.json > /dev/null && echo "JSON OK" || echo "INVALID JSON"

# Check Xray logs
journalctl -u xray -n 50

# Test manually
xray run -config /etc/xray/config.json
```

**Fix:** If config.json is corrupted, restore from backup:
```bash
cp /etc/xray/config.json.bak /etc/xray/config.json
systemctl restart xray
```

---

### Nginx failing to start

**Symptom:** Port 443 not listening after restart.

**Check:**
```bash
# Test config
nginx -t

# Check who is using port 443
ss -tlnp | grep :443

# Nginx error log
cat /var/log/nginx/error.log | tail -20
```

**Fix:**
```bash
# If SSL cert missing
autoscript  →  [5] Settings  →  [2] Renew SSL Certificate

# If port conflict
ss -tlnp | grep :443
# Kill conflicting process, then restart nginx
```

---

### SSL Certificate expired / not found

**Symptom:** Clients get TLS errors, Xray/Nginx fails to start.

**Check:**
```bash
# Check cert expiry
openssl x509 -noout -enddate -in /etc/xray/xray.crt

# Check cert/key match
openssl x509 -noout -modulus -in /etc/xray/xray.crt | sha256sum
openssl pkey -noout -modulus -in /etc/xray/xray.key | sha256sum
# Both should match
```

**Fix:**
```bash
# Manual renew
/root/.acme.sh/acme.sh --renew -d your-domain.com --force
# Then install cert
autoscript  →  [5] Settings  →  [2] Renew SSL Certificate
```

---

### Client can connect to port 443 but Xray protocol not working

**Symptom:** TLS works (no handshake error), but VMess/VLESS fails.

**Check:**
```bash
# Verify Nginx is proxying correctly
curl -k https://localhost/vmess -H "Upgrade: websocket" -v 2>&1 | head -20

# Verify Xray internal port is listening
ss -tlnp | grep 23456  # VMess WS
ss -tlnp | grep 14016  # VLESS WS
```

**Fix:** If Xray internal listener not running:
```bash
systemctl restart xray
systemctl status xray
```

---

### SSH WebSocket (WS) not working

**Symptom:** HTTP Injector/v2rayNG SSH via WS fails.

**Check:**
```bash
# WS proxy service status
systemctl status ws-openssh
systemctl status ws-dropbear

# Test WebSocket locally
curl -v http://localhost:2095 -H "Upgrade: websocket" -H "Connection: Upgrade" 2>&1 | head -10
```

**Fix:**
```bash
systemctl restart ws-openssh ws-dropbear
```

---

### OpenVPN clients cannot connect

**Symptom:** OpenVPN client times out.

**Check:**
```bash
# OpenVPN service
systemctl status openvpn@server-tcp

# Check iptables NAT rule
iptables -t nat -L POSTROUTING -n

# Check IP forwarding
sysctl net.ipv4.ip_forward
```

**Fix:**
```bash
# Re-apply NAT
IFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -s 10.8.0.0/8 -o "$IFACE" -j MASQUERADE

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
```

---

### Dropbear / Stunnel SSH not working

**Check:**
```bash
systemctl status dropbear stunnel4

# Verify Stunnel config
cat /etc/stunnel/stunnel.conf

# Check Stunnel log
tail -20 /var/log/stunnel4/stunnel.log
```

**Fix:**
```bash
systemctl restart dropbear stunnel4
```

---

### Users showing as expired

**Symptom:** User is marked expired in menu but should still be active.

**Check:**
```bash
# Verify system date
date

# Verify against Google time (clock may have drifted)
curl -sI https://google.com 2>/dev/null | grep -i date

# Sync time
ntpdate pool.ntp.org 2>/dev/null || chronyc makestep
```

---

### Backup failing

**Symptom:** Error when running backup.

**Check:**
```bash
# rclone config
rclone listremotes --config /etc/vps-autoscript/config/rclone.conf

# Test rclone connection
rclone lsd gdrive: --config /etc/vps-autoscript/config/rclone.conf
```

**Fix:**
```bash
# Reconfigure rclone
rclone config --config /etc/vps-autoscript/config/rclone.conf
```

---

## Log File Locations

| Log | Purpose |
|-----|---------|
| `/var/log/vps-autoscript/autoscript.log` | Main audit + operational log |
| `/var/log/vps-autoscript/health.log` | Health check results |
| `/var/log/vps-autoscript/ssl.log` | SSL cert operations |
| `/var/log/xray/error.log` | Xray errors |
| `/var/log/xray/access.log` | Xray access (warning level) |
| `/var/log/nginx/error.log` | Nginx errors |
| `/var/log/openvpn/server-tcp.log` | OpenVPN TCP |
| `/var/log/openvpn/server-udp.log` | OpenVPN UDP |
| `/var/log/stunnel4/stunnel.log` | Stunnel4 |

## Emergency Reset

If the system is in a bad state, restart all services:

```bash
systemctl restart nginx xray trojan-go ssh dropbear stunnel4 \
  openvpn@server-tcp openvpn@server-udp ws-openssh ws-dropbear fail2ban
```

Or from menu: `autoscript` → `[r] Restart All Services`
