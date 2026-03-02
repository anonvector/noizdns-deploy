# SayeDNS Deploy

One-click DNS tunnel server deployment for Linux. Deploys a dnstt server that **auto-detects** both standard **dnstt** and **SayeDNS** (DPI-evasion) clients — same binary, no extra configuration.

## Quick Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/anonvector/sayedns-deploy/main/sayedns-deploy.sh)
```

After installation, run `sayedns-deploy` anytime for the management menu.

## What is SayeDNS?

SayeDNS is a DPI-evasion layer on top of [dnstt](https://www.bamsoftware.com/software/dnstt/). It changes the DNS encoding to evade deep packet inspection fingerprinting:

| Feature | dnstt | SayeDNS |
|---|---|---|
| Subdomain encoding | Base32 (a-z, 2-7) | Hex (0-9, a-f) |
| Label length | 63 chars (max) | 32 chars |
| Query types | TXT only | Mixed A/AAAA/TXT |
| EDNS0 UDP size | 4096 | 1232 |
| Query timing | Regular | Jittered |
| Cover traffic | None | Periodic real DNS queries |

The server auto-detects which encoding a client uses per-query, so both dnstt and SayeDNS clients work simultaneously.

## Prerequisites

Before running the script, configure your DNS records:

| Record | Name | Value |
|---|---|---|
| **A** | `ns.example.com` | Your server's IP address |
| **AAAA** | `ns.example.com` | Your server's IPv6 address (optional) |
| **NS** | `t.example.com` | `ns.example.com` |

Replace `example.com` with your domain. The `t` subdomain is the tunnel endpoint.

## Features

- **Multi-distro**: Fedora, Rocky Linux, CentOS, Debian, Ubuntu
- **Two install methods**: Build from source (Go auto-installed) or use a pre-built binary
- **Tunnel modes**: SSH forwarding or SOCKS5 proxy (Dante)
- **Systemd integration**: Auto-start, restart on failure, security hardening
- **Firewall**: Automatic iptables/firewalld/ufw configuration with persistence
- **Key management**: Auto-generates keypairs, reuses existing keys on reconfiguration
- **Management menu**: Status, logs, restart, reconfigure — all from `sayedns-deploy`

## Usage

### First Install

```bash
# One-liner
bash <(curl -Ls https://raw.githubusercontent.com/anonvector/sayedns-deploy/main/sayedns-deploy.sh)
```

The script will prompt for:
1. **Tunnel domain** — e.g. `t.example.com`
2. **MTU** — default `1232`
3. **Tunnel mode** — SSH (forward to local sshd) or SOCKS (Dante proxy)
4. **Binary source** — build from Git repo or point to a pre-uploaded binary

### Management

```bash
sayedns-deploy
```

```
SayeDNS Server Management (v1.0.0)
========================================

  1) Install / Reconfigure server
  2) Check service status
  3) View live logs
  4) Show configuration
  5) Restart service
  6) Stop service
  7) Update this script
  0) Exit
```

### Manual Commands

```bash
systemctl start sayedns-server    # Start
systemctl stop sayedns-server     # Stop
systemctl status sayedns-server   # Status
journalctl -u sayedns-server -f   # Live logs
```

## Client Setup

In the SlipNet app:
1. Tap **+** → **SayeDNS** (or **DNSTT** for standard mode)
2. Enter the **tunnel domain** and **public key** shown after server setup
3. Add DNS resolvers
4. Connect

Both DNSTT and SayeDNS profiles point to the same server.

## How It Works

```
┌─────────────┐     DNS queries      ┌──────────────┐     ┌────────────┐
│  SlipNet     │ ──────────────────── │  DNS Resolver │ ──→ │  dnstt     │
│  (Android)   │  (hex or base32     │  (public)     │     │  server    │
│              │   in subdomains)     └──────────────┘     │            │
│  dnstt or    │                                           │ auto-detect│
│  SayeDNS     │ ←──────────────────────────────────────── │ encoding   │
└─────────────┘   TXT responses (downstream data)         └─────┬──────┘
                                                                 │
                                                           ┌─────▼──────┐
                                                           │  SSH or    │
                                                           │  SOCKS5    │
                                                           └────────────┘
```

## File Locations

| Path | Description |
|---|---|
| `/usr/local/bin/sayedns-deploy` | This script |
| `/usr/local/bin/dnstt-server` | Server binary |
| `/etc/sayedns/server.conf` | Configuration |
| `/etc/sayedns/*_server.key` | Private key |
| `/etc/sayedns/*_server.pub` | Public key |

## License

MIT
