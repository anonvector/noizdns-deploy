# NoizDNS Deploy

One-click DNS tunnel server deployment for Linux. Deploys a dnstt server that **auto-detects** both standard **dnstt** and **NoizDNS** (DPI-evasion) clients — same binary, no extra configuration.

## Quick Install

```bash
bash <(curl -Ls https://gitlab.com/anonvector/noizdns-deploy/-/raw/main/noizdns-deploy.sh)
```

After installation, run `noizdns` anytime for the management menu.

## What is NoizDNS?

NoizDNS is a DPI-evasion layer on top of [dnstt](https://www.bamsoftware.com/software/dnstt/). The server auto-detects which protocol a client uses per-query, so both standard dnstt and NoizDNS clients work simultaneously through the same server.

## Client

[**SlipNet**](https://gitlab.com/anonvector/slipnet) — Android VPN client with built-in DNSTT and NoizDNS support, DNS scanner, and SSH tunneling.

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
- **Auto-download**: Pre-built server binary downloaded from GitLab
- **Non-interactive mode**: CLI flags for fully automated deployments
- **SOCKS5 proxy**: Dante-based SOCKS proxy with optional user authentication
- **Systemd integration**: Auto-start, restart on failure, security hardening
- **Firewall**: Automatic iptables/firewalld/ufw configuration with persistence
- **Key management**: Auto-generates keypairs, reuses existing keys on reconfiguration
- **Management menu**: Status, logs, restart, reconfigure, update, uninstall
- **Self-updating**: Update binary or script from the management menu

## Usage

### Interactive Install

```bash
bash <(curl -Ls https://gitlab.com/anonvector/noizdns-deploy/-/raw/main/noizdns-deploy.sh)
```

The script will prompt for:
1. **Tunnel domain** — e.g. `t.example.com`
2. **MTU** — default `1232`

### Non-Interactive Install (Automated)

Pass `--domain` to skip all prompts and run a fully automated deployment:

```bash
# Auto-install with defaults (generates new keys)
noizdns --domain t.example.com

# Custom MTU
noizdns --domain t.example.com --mtu 1400

# Use existing key files
noizdns --domain t.example.com \
  --privkey-file /path/to/server.key \
  --pubkey-file /path/to/server.pub

# One-liner via curl
bash <(curl -Ls https://gitlab.com/anonvector/noizdns-deploy/-/raw/main/noizdns-deploy.sh) \
  --domain t.example.com
```

#### CLI Options

| Flag | Description |
|---|---|
| `-d, --domain <domain>` | Tunnel domain (required for auto mode) |
| `-m, --mtu <value>` | MTU value (default: 1232) |
| `--pubkey-file <path>` | Path to existing public key file |
| `--privkey-file <path>` | Path to existing private key file |
| `-h, --help` | Show help |

> When `--domain` is provided, the script runs non-interactively. Keys are auto-generated if not provided, or reused if they already exist on the server. If providing key files, both `--pubkey-file` and `--privkey-file` are required.

### Management

```bash
noizdns
```

```
────────────────────────────────────────────
  NoizDNS Server Management
────────────────────────────────────────────

  Status: Running

  1) Install / Reconfigure
  2) Show configuration
  3) Service status
  4) View live logs
  5) User management
  6) Restart service
  7) Stop service
  8) Start service
  9) Update binary
  10) Update this script
  11) Uninstall
  0) Exit
```

### Manual Commands

```bash
systemctl start noizdns-server    # Start
systemctl stop noizdns-server     # Stop
systemctl status noizdns-server   # Status
journalctl -u noizdns-server -f   # Live logs
```

## Uninstall

From the menu, select option **11**. This removes:
- Systemd service
- Server binary
- Configuration and keys
- Service user
- iptables rules
- The deploy script itself

## How It Works

```
┌─────────────┐     DNS queries      ┌──────────────┐     ┌────────────┐
│  SlipNet     │ ──────────────────── │  DNS Resolver │ ──→ │  dnstt     │
│  (Android)   │  (hex or base32     │  (public)     │     │  server    │
│              │   in subdomains)     └──────────────┘     │            │
│  dnstt or    │                                           │ auto-detect│
│  NoizDNS     │ ←──────────────────────────────────────── │ encoding   │
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
| `/usr/local/bin/noizdns` | Management script |
| `/usr/local/bin/dnstt-server` | Server binary |
| `/etc/noizdns/server.conf` | Configuration |
| `/etc/noizdns/*_server.key` | Private key |
| `/etc/noizdns/*_server.pub` | Public key |

## License

MIT
