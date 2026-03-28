# XxXjihad VPN Manager v5.0

**All-in-one SSH/VPN Infrastructure Manager for Ubuntu/Debian Servers**

Telegram: [https://t.me/XxXjihad](https://t.me/XxXjihad)

---

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jamal7720077-debug/XxXjihadVPNManager/main/xxjihad.sh)
```

After installation, type `xxjihad` to open the management menu.

## Usage

```bash
# Open management menu
xxjihad

# Quick status check
xxjihad --status

# Show DNSTT connection info
xxjihad --info

# Help
xxjihad --help
```

---

## Supported Connections

| Connection Type | Ports | Description |
|---|---|---|
| SSH + SSL No Payload | 22, 80, 443 | Direct SSH on multiple ports |
| SSH + Payload (no SSL) | 80, 443 | Via HAProxy Edge Stack |
| SSH + Payload + WebSocket + SSL | 443 | WebSocket over SSL |
| SSH + Random Payloads | 8080 | Falcon Proxy (Active) |
| V2Ray + Payload | 8080 | Custom Header: `x-firewallfalcon-port: v2rayPort` |
| V2Ray WS/gRPC/xHTTP | 443, 80 | Via X-UI Panel |
| DNS Tunnel (DNSTT) | 53 | DNS-based tunneling |

---

## Features

### User Management
- Create / Delete / List / Renew SSH users
- Change password
- Lock / Unlock accounts
- Edit user settings (password, expiry, limits, bandwidth)
- View per-user bandwidth usage with progress bar
- Trial/Test accounts with auto-expiry (1h to custom)
- Bulk user creation (up to 100 at once)
- Cleanup expired users
- Backup & Restore user database
- Client config generator

### Protocol & Tunnel Management
- **HAProxy Edge Stack** (ports 80/443) - SSH + SSL with SNI routing
- **DNSTT** (port 53) - DNS-based tunnel with auto key generation via deSEC.io
- **Falcon Proxy** (port 8080) - WebSocket proxy with random payloads
- **Nginx Reverse Proxy** - Full TLS/HTTP reverse proxy with Let's Encrypt support
- **badvpn-udpgw** (port 7300) - UDP gateway
- **ZiVPN** (port 5667) - UDP tunnel
- **X-UI Panel** - V2Ray/Xray management (WS/gRPC/xHTTP)

### Tools & Utilities
- Traffic Monitor (vnstat integration)
- Torrent/P2P Blocking (iptables rules)
- Auto-Reboot scheduling (daily/weekly/custom)
- SSH Banner management (per-user dynamic banners)
- Certbot SSL certificate management
- CloudFlare/deSEC DNS management
- Service Status Dashboard

### Network Optimization
- BBR congestion control
- TCP/UDP buffer tuning
- Sysctl optimizations for VPN workloads
- File descriptor limits

### Smart System
- Auto-detect and remove old versions during upgrade
- Preserve user data during upgrades
- Download retry mechanism (3 attempts)
- Real-time service status monitoring
- Background user limiter (connections, bandwidth, expiry enforcement)
- Auto-healing watchdog and heartbeat services

---

## Project Structure

```
XxXjihadVPNManager/
├── xxjihad.sh              # Main installer script
├── README.md               # This file
├── configs/
│   └── xxjihad-dnstt.service  # Systemd service template
├── lib/
│   ├── dnstt-core.sh       # DNSTT engine, DNS smart system, watchdog, heartbeat
│   ├── ssl-tunnel.sh       # HAProxy Edge Stack install/uninstall
│   ├── protocols.sh        # Falcon Proxy, ZiVPN, Nginx, X-UI, badvpn
│   ├── user-manager.sh     # User management, trial, bulk, bandwidth, backup
│   ├── net-optimizer.sh    # BBR, sysctl, traffic monitor, torrent block, auto-reboot
│   └── menu-system.sh      # Main menu, protocol menu, tools menu, banner, uninstall
└── bin/                    # (Reserved for compiled binaries)
```

---

## Menu Structure

```
Main Menu
├── [1] User Management
│   ├── Create User
│   ├── Delete User
│   ├── List Users
│   ├── Renew User
│   ├── Change Password
│   ├── View Bandwidth
│   ├── Create Trial Account
│   ├── Bulk Create Users
│   ├── Generate Client Config
│   ├── Lock User
│   ├── Unlock User
│   ├── Edit User
│   ├── Cleanup Expired Users
│   ├── Backup Users
│   └── Restore Users
├── [2] Protocol & Tunnel Management
│   ├── HAProxy Edge Stack (Install/Uninstall)
│   ├── DNSTT (Install/View/Uninstall)
│   ├── Falcon Proxy (Install/Uninstall)
│   ├── Nginx Proxy (Install/Manage/Uninstall)
│   ├── badvpn (Install/Uninstall)
│   ├── ZiVPN (Install/Uninstall)
│   └── X-UI Panel (Install/Uninstall)
├── [3] DNSTT Management
│   ├── Install DNSTT
│   ├── Show Connection Info
│   ├── Restart DNSTT
│   ├── View Logs
│   ├── Rotate Keys
│   └── Uninstall DNSTT
├── [4] Network Optimization
│   ├── Show Network Status
│   ├── Enable BBR
│   ├── Apply Sysctl Optimizations
│   └── Apply All
├── [5] Tools & Utilities
│   ├── Traffic Monitor
│   ├── Torrent Blocking
│   ├── Auto-Reboot Management
│   ├── SSH Banner Management
│   ├── Certbot SSL Certificate
│   ├── CloudFlare DNS
│   ├── Service Status Dashboard
│   └── View Logs
└── [99] Uninstall XxXjihad
```

---

## Requirements

- **OS**: Ubuntu 18.04+ / Debian 10+
- **Arch**: x86_64 (amd64) or ARM64 (aarch64)
- **Root**: Required (sudo)
- **RAM**: 512MB minimum
- **Ports**: 53 (DNSTT), 22 (SSH), 80/443 (Edge Stack), 8080 (Falcon)

---

## License

This project is provided as-is for educational and personal use.

**Telegram**: [https://t.me/XxXjihad](https://t.me/XxXjihad)
