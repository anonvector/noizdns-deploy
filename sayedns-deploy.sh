#!/bin/bash

# SayeDNS Server Deploy Script
# One-click dnstt + SayeDNS server deployment for Linux
# https://github.com/anonvector/sayedns-deploy
#
# Supports: Fedora, Rocky, CentOS, Debian, Ubuntu
# The server auto-detects both dnstt and SayeDNS clients — same binary.

set -e

SCRIPT_VERSION="1.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/anonvector/sayedns-deploy/main/sayedns-deploy.sh"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Global variables
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sayedns"
SYSTEMD_DIR="/etc/systemd/system"
DNSTT_PORT="5300"
SERVICE_USER="sayedns"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
SCRIPT_INSTALL_PATH="/usr/local/bin/sayedns-deploy"
SERVICE_NAME="sayedns-server"

# Printing helpers
print_status()   { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()    { echo -e "${RED}[ERROR]${NC} $1"; }
print_question() { echo -ne "${BLUE}[?]${NC} $1"; }

# ─── OS / Arch Detection ─────────────────────────────────────────────────────

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    else
        print_error "Cannot detect OS"
        exit 1
    fi

    if command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    elif command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
    else
        print_error "Unsupported package manager"
        exit 1
    fi

    print_status "Detected OS: $OS ($PKG_MANAGER)"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)        ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv6l) ARCH="arm"   ;;
        i386|i686)     ARCH="386"   ;;
        *)
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
    GOARCH="$ARCH"
    print_status "Architecture: $ARCH"
}

# ─── Dependencies ────────────────────────────────────────────────────────────

install_dependencies() {
    print_status "Installing dependencies..."

    case $PKG_MANAGER in
        dnf|yum)
            $PKG_MANAGER install -y curl iptables iptables-services git 2>/dev/null || true
            ;;
        apt)
            apt update -qq
            apt install -y curl iptables git 2>/dev/null || true
            ;;
    esac
}

# ─── Go Installation ─────────────────────────────────────────────────────────

check_go() {
    if command -v go &>/dev/null; then
        local ver
        ver=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+')
        print_status "Go $ver found"
        return 0
    fi
    return 1
}

install_go() {
    if check_go; then return 0; fi

    print_status "Installing Go..."
    local go_ver="1.23.6"
    local go_arch="$ARCH"
    local tarball="go${go_ver}.linux-${go_arch}.tar.gz"

    curl -sL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${tarball}"
    rm "/tmp/${tarball}"

    export PATH="/usr/local/go/bin:$PATH"

    # Make persistent
    if ! grep -q '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null; then
        echo 'export PATH="/usr/local/go/bin:$PATH"' > /etc/profile.d/go.sh
    fi

    print_status "Go $(go version | grep -oP 'go\K[0-9]+\.[0-9]+') installed"
}

# ─── Build from source ───────────────────────────────────────────────────────

build_dnstt_server() {
    local binary="${INSTALL_DIR}/dnstt-server"
    local src_dir="/tmp/sayedns-build"

    # Check for existing binary
    if [ -f "$binary" ]; then
        print_question "dnstt-server already exists. Rebuild? [y/N]: "
        read -r rebuild
        if [[ ! "$rebuild" =~ ^[Yy]$ ]]; then
            print_status "Keeping existing binary"
            return 0
        fi
    fi

    echo ""
    echo "How do you want to install the dnstt-server binary?"
    echo "  1) Build from source (Go will be installed automatically)"
    echo "  2) Use pre-uploaded binary (you already scp'd it to this server)"
    print_question "Choice [1]: "
    read -r build_choice
    build_choice=${build_choice:-1}

    if [[ "$build_choice" == "2" ]]; then
        print_question "Path to dnstt-server binary: "
        read -r binary_path
        if [[ ! -f "$binary_path" ]]; then
            print_error "File not found: $binary_path"
            exit 1
        fi
        cp "$binary_path" "$binary"
        chmod +x "$binary"
        print_status "Binary installed from $binary_path"
        return 0
    fi

    # Build from source
    install_go

    print_status "Cloning source..."
    rm -rf "$src_dir"

    print_question "Git repository URL for dnstt source: "
    read -r repo_url

    if [[ -z "$repo_url" ]]; then
        print_error "Repository URL is required"
        exit 1
    fi

    if [[ -d "$repo_url" ]]; then
        cp -r "$repo_url" "$src_dir"
    else
        git clone --depth 1 "$repo_url" "$src_dir"
    fi

    # Find go.mod and dnstt-server
    local build_dir=""
    for candidate in "$src_dir" "$src_dir/dnstt" ; do
        if [[ -f "$candidate/go.mod" && -d "$candidate/dnstt-server" ]]; then
            build_dir="$candidate"
            break
        fi
    done

    if [[ -z "$build_dir" ]]; then
        # Try flat layout: go.mod + main.go in dnstt-server/
        if [[ -d "$src_dir/dnstt-server" ]]; then
            build_dir="$src_dir/dnstt-server"
        else
            print_error "Cannot find dnstt-server source in the repository"
            rm -rf "$src_dir"
            exit 1
        fi
    fi

    print_status "Building dnstt-server..."
    cd "$build_dir"

    if [[ -d "dnstt-server" ]]; then
        CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build \
            -trimpath -ldflags '-s -w' \
            -o "$binary" \
            ./dnstt-server/
    else
        CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build \
            -trimpath -ldflags '-s -w' \
            -o "$binary" \
            .
    fi

    chmod +x "$binary"
    rm -rf "$src_dir"

    print_status "dnstt-server built and installed at $binary"
}

# ─── System User ──────────────────────────────────────────────────────────────

create_service_user() {
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "SayeDNS service user" "$SERVICE_USER"
        print_status "Created user: $SERVICE_USER"
    else
        print_status "User $SERVICE_USER already exists"
    fi

    mkdir -p "$CONFIG_DIR"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

# ─── Key Generation ──────────────────────────────────────────────────────────

generate_keys() {
    local key_prefix
    key_prefix=$(echo "$NS_SUBDOMAIN" | sed 's/\./_/g')
    PRIVATE_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.key"
    PUBLIC_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.pub"

    if [[ -f "$PRIVATE_KEY_FILE" && -f "$PUBLIC_KEY_FILE" ]]; then
        print_status "Existing keys found for $NS_SUBDOMAIN"
        chown "$SERVICE_USER":"$SERVICE_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
        chmod 600 "$PRIVATE_KEY_FILE"
        chmod 644 "$PUBLIC_KEY_FILE"
        print_status "Public key:"
        echo -e "${YELLOW}$(cat "$PUBLIC_KEY_FILE")${NC}"

        print_question "Regenerate keys? [y/N]: "
        read -r regen
        if [[ ! "$regen" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    print_status "Generating new keypair..."
    dnstt-server -gen-key -privkey-file "$PRIVATE_KEY_FILE" -pubkey-file "$PUBLIC_KEY_FILE"

    chown "$SERVICE_USER":"$SERVICE_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
    chmod 600 "$PRIVATE_KEY_FILE"
    chmod 644 "$PUBLIC_KEY_FILE"

    print_status "Public key:"
    echo -e "${YELLOW}$(cat "$PUBLIC_KEY_FILE")${NC}"
}

# ─── User Input ───────────────────────────────────────────────────────────────

load_existing_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# SayeDNS Server Configuration
# Generated on $(date)
NS_SUBDOMAIN="$NS_SUBDOMAIN"
MTU_VALUE="$MTU_VALUE"
TUNNEL_MODE="$TUNNEL_MODE"
PRIVATE_KEY_FILE="$PRIVATE_KEY_FILE"
PUBLIC_KEY_FILE="$PUBLIC_KEY_FILE"
EOF
    chmod 640 "$CONFIG_FILE"
    chown root:"$SERVICE_USER" "$CONFIG_FILE"
}

get_user_input() {
    local existing_domain="" existing_mtu="" existing_mode=""

    if load_existing_config; then
        existing_domain="$NS_SUBDOMAIN"
        existing_mtu="$MTU_VALUE"
        existing_mode="$TUNNEL_MODE"
        print_status "Existing config: $existing_domain (mode: $existing_mode, mtu: $existing_mtu)"
    fi

    # Domain
    while true; do
        if [[ -n "$existing_domain" ]]; then
            print_question "Tunnel domain [${existing_domain}]: "
        else
            print_question "Tunnel domain (e.g. t.example.com): "
        fi
        read -r NS_SUBDOMAIN
        NS_SUBDOMAIN=${NS_SUBDOMAIN:-$existing_domain}
        [[ -n "$NS_SUBDOMAIN" ]] && break
        print_error "Domain is required"
    done

    # MTU
    if [[ -n "$existing_mtu" ]]; then
        print_question "MTU [${existing_mtu}]: "
    else
        print_question "MTU [1232]: "
    fi
    read -r MTU_VALUE
    MTU_VALUE=${MTU_VALUE:-${existing_mtu:-1232}}

    # Tunnel mode
    while true; do
        echo ""
        echo "Tunnel mode:"
        echo "  1) SSH   — forward to local SSH server"
        echo "  2) SOCKS — forward to Dante SOCKS5 proxy"
        if [[ -n "$existing_mode" ]]; then
            local mode_num="1"
            [[ "$existing_mode" == "socks" ]] && mode_num="2"
            print_question "Choice [${mode_num}]: "
        else
            print_question "Choice [1]: "
        fi
        read -r mode_input

        if [[ -z "$mode_input" && -n "$existing_mode" ]]; then
            TUNNEL_MODE="$existing_mode"
            break
        fi

        case ${mode_input:-1} in
            1) TUNNEL_MODE="ssh";   break ;;
            2) TUNNEL_MODE="socks"; break ;;
            *) print_error "Enter 1 or 2" ;;
        esac
    done

    echo ""
    print_status "Domain:      $NS_SUBDOMAIN"
    print_status "MTU:         $MTU_VALUE"
    print_status "Tunnel mode: $TUNNEL_MODE"
}

# ─── Firewall / iptables ─────────────────────────────────────────────────────

configure_firewall() {
    print_status "Configuring firewall..."

    # Firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${DNSTT_PORT}"/udp
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --reload
        print_status "firewalld rules added"
    # UFW
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${DNSTT_PORT}"/udp
        ufw allow 53/udp
        print_status "ufw rules added"
    fi

    # iptables redirect 53 -> DNSTT_PORT
    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -1)
    iface=${iface:-eth0}

    print_status "Redirecting port 53 -> ${DNSTT_PORT} on $iface"

    # Remove old rules to avoid duplicates
    iptables  -D INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || true
    iptables  -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null || true

    iptables  -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT
    iptables  -t nat -I PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT"

    # IPv6
    if command -v ip6tables &>/dev/null && [ -f /proc/net/if_inet6 ]; then
        ip6tables -D INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || true
        ip6tables -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null || true

        ip6tables -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || true
        ip6tables -t nat -I PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null || true
    fi

    # Persist rules
    save_iptables_rules
}

save_iptables_rules() {
    case $PKG_MANAGER in
        dnf|yum)
            mkdir -p /etc/sysconfig
            iptables-save  > /etc/sysconfig/iptables  2>/dev/null || true
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
            systemctl enable iptables 2>/dev/null || true
            ;;
        apt)
            mkdir -p /etc/iptables
            iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            systemctl enable netfilter-persistent 2>/dev/null || true
            ;;
    esac
    print_status "iptables rules saved"
}

# ─── Dante SOCKS Proxy ───────────────────────────────────────────────────────

setup_dante() {
    print_status "Setting up Dante SOCKS proxy..."

    case $PKG_MANAGER in
        dnf|yum) $PKG_MANAGER install -y dante-server ;;
        apt)     apt install -y dante-server ;;
    esac

    local ext_iface
    ext_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    ext_iface=${ext_iface:-eth0}

    cat > /etc/danted.conf << EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

internal: 127.0.0.1 port = 1080
external: $ext_iface

socksmethod: none
compatibility: sameport
extension: bind

client pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    log: error
}
socks pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error
}
socks block {
    from: 0.0.0.0/0 to: ::/0
    log: error
}
client block {
    from: 0.0.0.0/0 to: ::/0
    log: error
}
EOF

    systemctl enable danted
    systemctl restart danted
    print_status "Dante running on 127.0.0.1:1080"
}

# ─── SSH Port Detection ──────────────────────────────────────────────────────

detect_ssh_port() {
    local port
    port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '[0-9]+$' | head -1)
    echo "${port:-22}"
}

# ─── Systemd Service ─────────────────────────────────────────────────────────

create_systemd_service() {
    local target_port
    if [ "$TUNNEL_MODE" = "ssh" ]; then
        target_port=$(detect_ssh_port)
        print_status "SSH port detected: $target_port"
    else
        target_port="1080"
    fi

    # Stop existing service
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    cat > "${SYSTEMD_DIR}/${SERVICE_NAME}.service" << EOF
[Unit]
Description=SayeDNS Server (dnstt + SayeDNS auto-detected)
After=network.target
Wants=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=${INSTALL_DIR}/dnstt-server -udp :${DNSTT_PORT} -privkey-file ${PRIVATE_KEY_FILE} -mtu ${MTU_VALUE} ${NS_SUBDOMAIN} 127.0.0.1:${target_port}
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"

    print_status "Service created: $SERVICE_NAME"
    print_status "Tunneling to 127.0.0.1:$target_port ($TUNNEL_MODE)"
}

# ─── Start ────────────────────────────────────────────────────────────────────

start_services() {
    print_status "Starting $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager -l
}

# ─── Info Display ─────────────────────────────────────────────────────────────

show_configuration_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "No configuration found. Run install first."
        return 1
    fi
    load_existing_config

    local status_text
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        status_text="${GREEN}Running${NC}"
    else
        status_text="${RED}Stopped${NC}"
    fi

    echo ""
    echo -e "${CYAN}Configuration:${NC}"
    echo -e "  Domain:  ${YELLOW}$NS_SUBDOMAIN${NC}"
    echo -e "  MTU:     ${YELLOW}$MTU_VALUE${NC}"
    echo -e "  Mode:    ${YELLOW}$TUNNEL_MODE${NC}"
    echo -e "  Port:    ${YELLOW}$DNSTT_PORT${NC} (redirected from 53)"
    echo -e "  Status:  $status_text"
    echo ""

    if [ -f "$PUBLIC_KEY_FILE" ]; then
        echo -e "${CYAN}Public Key:${NC}"
        echo -e "${YELLOW}$(cat "$PUBLIC_KEY_FILE")${NC}"
        echo ""
    fi

    echo -e "${CYAN}Protocol Support:${NC}"
    echo -e "  This server auto-detects both ${GREEN}dnstt${NC} and ${GREEN}SayeDNS${NC} clients."
    echo -e "  No extra configuration needed — same binary handles both."
    echo ""

    echo -e "${CYAN}Commands:${NC}"
    echo -e "  Menu:    ${WHITE}sayedns-deploy${NC}"
    echo -e "  Start:   ${WHITE}systemctl start $SERVICE_NAME${NC}"
    echo -e "  Stop:    ${WHITE}systemctl stop $SERVICE_NAME${NC}"
    echo -e "  Status:  ${WHITE}systemctl status $SERVICE_NAME${NC}"
    echo -e "  Logs:    ${WHITE}journalctl -u $SERVICE_NAME -f${NC}"

    if [ "$TUNNEL_MODE" = "socks" ]; then
        echo ""
        echo -e "${CYAN}SOCKS Proxy:${NC}"
        echo -e "  Address: ${WHITE}127.0.0.1:1080${NC}"
        echo -e "  Status:  ${WHITE}systemctl status danted${NC}"
    fi
    echo ""
}

print_success_box() {
    echo ""
    echo -e "${GREEN}+================================================================================+${NC}"
    echo -e "${GREEN}|                       SAYEDNS SERVER SETUP COMPLETE                             |${NC}"
    echo -e "${GREEN}+================================================================================+${NC}"
    echo ""
    echo -e "${CYAN}This server supports both dnstt and SayeDNS clients (auto-detected).${NC}"
    echo ""

    show_configuration_info

    echo -e "${CYAN}DNS Records Required:${NC}"
    local domain_parts
    IFS='.' read -ra domain_parts <<< "$NS_SUBDOMAIN"
    local base_domain
    if [ ${#domain_parts[@]} -ge 3 ]; then
        base_domain="${domain_parts[*]:1}"
        base_domain="${base_domain// /.}"
    else
        base_domain="$NS_SUBDOMAIN"
    fi
    echo -e "  ${WHITE}A     ns.${base_domain}  ->  <your-server-ip>${NC}"
    echo -e "  ${WHITE}NS    ${NS_SUBDOMAIN}  ->  ns.${base_domain}${NC}"
    echo ""
    echo -e "${GREEN}+================================================================================+${NC}"
    echo ""
}

# ─── Script Update ────────────────────────────────────────────────────────────

update_script() {
    print_status "Checking for updates..."

    local temp="/tmp/sayedns-deploy-latest.sh"
    if ! curl -sL "$SCRIPT_URL" -o "$temp" 2>/dev/null; then
        print_error "Failed to download latest version"
        return 1
    fi

    local cur new
    cur=$(sha256sum "$SCRIPT_INSTALL_PATH" 2>/dev/null | cut -d' ' -f1)
    new=$(sha256sum "$temp" | cut -d' ' -f1)

    if [ "$cur" = "$new" ]; then
        print_status "Already up to date (v${SCRIPT_VERSION})"
        rm "$temp"
        return 0
    fi

    chmod +x "$temp"
    cp "$temp" "$SCRIPT_INSTALL_PATH"
    rm "$temp"
    print_status "Updated! Restarting..."
    exec "$SCRIPT_INSTALL_PATH"
}

# ─── Menu ─────────────────────────────────────────────────────────────────────

show_menu() {
    echo ""
    echo -e "${CYAN}SayeDNS Server Management (v${SCRIPT_VERSION})${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo "  1) Install / Reconfigure server"
    echo "  2) Check service status"
    echo "  3) View live logs"
    echo "  4) Show configuration"
    echo "  5) Restart service"
    echo "  6) Stop service"
    echo "  7) Update this script"
    echo "  0) Exit"
    echo ""
    print_question "Choice [0-7]: "
}

handle_menu() {
    while true; do
        show_menu
        read -r choice
        case $choice in
            1) return 0 ;;
            2)
                systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || print_warning "Service not installed"
                ;;
            3)
                print_status "Showing logs (Ctrl+C to exit)..."
                journalctl -u "$SERVICE_NAME" -f
                ;;
            4) show_configuration_info ;;
            5)
                systemctl restart "$SERVICE_NAME" 2>/dev/null && print_status "Restarted" || print_error "Failed"
                ;;
            6)
                systemctl stop "$SERVICE_NAME" 2>/dev/null && print_status "Stopped" || print_error "Failed"
                ;;
            7) update_script ;;
            0)
                print_status "Goodbye!"
                exit 0
                ;;
            *) print_error "Invalid choice" ;;
        esac

        if [ "$choice" != "3" ]; then
            echo ""
            print_question "Press Enter to continue..."
            read -r
        fi
    done
}

# ─── Install Script to PATH ──────────────────────────────────────────────────

install_script() {
    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        local cur new
        cur=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
        new=$(sha256sum "$0" | cut -d' ' -f1)
        if [ "$cur" = "$new" ]; then
            return 0
        fi
    fi
    cp "$0" "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    print_status "Script installed to $SCRIPT_INSTALL_PATH"
    print_status "Run 'sayedns-deploy' anytime for the management menu"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  SayeDNS Server Deploy  v${SCRIPT_VERSION}              ║${NC}"
    echo -e "${GREEN}║  dnstt + SayeDNS (auto-detected)          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    # Install script to PATH
    install_script

    # If running from installed location, show menu
    if [ "$(realpath "$0" 2>/dev/null || echo "$0")" = "$SCRIPT_INSTALL_PATH" ]; then
        handle_menu
    fi

    # Detect environment
    detect_os
    detect_arch

    # Install deps
    install_dependencies

    # Get configuration
    get_user_input

    # Build or install binary
    build_dnstt_server

    # Create service user
    create_service_user

    # Generate keys
    generate_keys

    # Save config
    save_config

    # Firewall
    configure_firewall

    # Tunnel mode setup
    if [ "$TUNNEL_MODE" = "socks" ]; then
        setup_dante
    else
        if systemctl is-active --quiet danted 2>/dev/null; then
            print_status "Stopping Dante (switching to SSH mode)..."
            systemctl stop danted
            systemctl disable danted
        fi
    fi

    # Systemd service
    create_systemd_service

    # Start
    start_services

    # Done
    print_success_box
}

main "$@"
