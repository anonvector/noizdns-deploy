#!/bin/bash

# NoizDNS Server Deploy Script
# One-click dnstt + NoizDNS server deployment for Linux
# https://github.com/anonvector/noizdns-deploy
#
# Supports: Fedora, Rocky, CentOS, Debian, Ubuntu
# The server auto-detects both dnstt and NoizDNS clients — same binary.

set -e

SCRIPT_VERSION="1.2.0"
SCRIPT_URL="https://raw.githubusercontent.com/anonvector/noizdns-deploy/main/noizdns-deploy.sh"

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
BOLD='\033[1m'
NC='\033[0m'

# Global variables
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/noizdns"
SYSTEMD_DIR="/etc/systemd/system"
DNSTT_PORT="5300"
SERVICE_USER="noizdns"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
SCRIPT_INSTALL_PATH="/usr/local/bin/noizdns"
SERVICE_NAME="noizdns-server"
USERS_FILE="${CONFIG_DIR}/users.txt"
RELEASE_URL="https://github.com/anonvector/noizdns-deploy/releases/latest/download"

# Printing helpers
print_status()   { echo -e "${GREEN}[+]${NC} $1"; }
print_warning()  { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()    { echo -e "${RED}[-]${NC} $1"; }
print_question() { echo -ne "${BLUE}[?]${NC} $1"; }
print_line()     { echo -e "${CYAN}────────────────────────────────────────────${NC}"; }

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
            $PKG_MANAGER install -y curl iptables iptables-services 2>/dev/null || true
            ;;
        apt)
            apt update -qq
            apt install -y curl iptables 2>/dev/null || true
            ;;
    esac
}

# ─── Download Binary ─────────────────────────────────────────────────────────

download_binary() {
    local binary="${INSTALL_DIR}/dnstt-server"
    local filename="dnstt-server-linux-${ARCH}"

    print_status "Downloading $filename from GitHub..."

    if ! curl -fSL -o "/tmp/$filename" "${RELEASE_URL}/${filename}"; then
        print_error "Download failed"
        exit 1
    fi

    # Verify checksum
    print_status "Verifying checksum..."
    if curl -fsSL -o "/tmp/SHA256SUMS" "${RELEASE_URL}/SHA256SUMS" 2>/dev/null; then
        cd /tmp
        if sha256sum -c <(grep "$filename" SHA256SUMS) 2>/dev/null; then
            print_status "SHA256 checksum verified"
        else
            print_warning "Checksum verification failed — proceeding anyway"
        fi
    else
        print_warning "Could not download checksums — skipping verification"
    fi

    chmod +x "/tmp/$filename"
    mv "/tmp/$filename" "$binary"
    rm -f /tmp/SHA256SUMS

    print_status "dnstt-server installed at $binary"
}

# ─── System User ──────────────────────────────────────────────────────────────

create_service_user() {
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "NoizDNS service user" "$SERVICE_USER"
        print_status "Created user: $SERVICE_USER"
    else
        print_status "User $SERVICE_USER already exists"
    fi

    mkdir -p "$CONFIG_DIR"
    touch "$USERS_FILE" && chmod 640 "$USERS_FILE"
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
        echo ""
        echo -e "  ${CYAN}Public Key:${NC}"
        echo -e "  ${YELLOW}$(cat "$PUBLIC_KEY_FILE")${NC}"
        echo ""

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

    echo ""
    echo -e "  ${CYAN}Public Key:${NC}"
    echo -e "  ${YELLOW}$(cat "$PUBLIC_KEY_FILE")${NC}"
    echo ""
}

# ─── Configuration ────────────────────────────────────────────────────────────

load_existing_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# NoizDNS Server Configuration
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

    echo ""

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
        echo "  Tunnel mode:"
        echo "    1) SSH   — forward to local SSH server"
        echo "    2) SOCKS — forward to Dante SOCKS5 proxy"
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
    print_line
    print_status "Domain:      $NS_SUBDOMAIN"
    print_status "MTU:         $MTU_VALUE"
    print_status "Tunnel mode: $TUNNEL_MODE"
    print_line
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

remove_iptables_rules() {
    print_status "Removing iptables rules..."

    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -1)
    iface=${iface:-eth0}

    iptables  -D INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || true
    iptables  -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null || true

    if command -v ip6tables &>/dev/null; then
        ip6tables -D INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || true
        ip6tables -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSTT_PORT" 2>/dev/null || true
    fi

    save_iptables_rules
    print_status "iptables rules removed"
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
Description=NoizDNS Server (dnstt + NoizDNS auto-detected)
After=network.target
Wants=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=TOR_PT_MANAGED_TRANSPORT_VER=1
Environment=TOR_PT_SERVER_TRANSPORTS=dnstt
Environment=TOR_PT_SERVER_BINDADDR=dnstt-0.0.0.0:${DNSTT_PORT}
Environment=TOR_PT_ORPORT=127.0.0.1:${target_port}
ExecStart=${INSTALL_DIR}/dnstt-server -privkey-file ${PRIVATE_KEY_FILE} -mtu ${MTU_VALUE} ${NS_SUBDOMAIN}
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

start_services() {
    print_status "Starting $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager -l
}

# ─── Info Display ─────────────────────────────────────────────────────────────

is_installed() {
    [ -f "${INSTALL_DIR}/dnstt-server" ] && [ -f "$CONFIG_FILE" ]
}

show_configuration_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "No configuration found. Run install first."
        return 1
    fi
    load_existing_config

    local status_text
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        status_text="${GREEN}Running${NC}"
    else
        status_text="${RED}Stopped${NC}"
    fi

    echo ""
    print_line
    echo -e "  ${CYAN}Configuration${NC}"
    print_line
    echo -e "  Domain:  ${YELLOW}$NS_SUBDOMAIN${NC}"
    echo -e "  MTU:     ${YELLOW}$MTU_VALUE${NC}"
    echo -e "  Mode:    ${YELLOW}$TUNNEL_MODE${NC}"
    echo -e "  Port:    ${YELLOW}$DNSTT_PORT${NC} (redirected from 53)"
    echo -e "  Status:  $status_text"
    echo ""

    if [ -f "$PUBLIC_KEY_FILE" ]; then
        echo -e "  ${CYAN}Public Key:${NC}"
        echo -e "  ${YELLOW}$(cat "$PUBLIC_KEY_FILE")${NC}"
        echo ""
    fi

    echo -e "  ${CYAN}Protocol:${NC}"
    echo -e "  Auto-detects both ${GREEN}dnstt${NC} and ${GREEN}NoizDNS${NC} clients."
    print_line

    if [ "$TUNNEL_MODE" = "socks" ]; then
        echo ""
        echo -e "  ${CYAN}SOCKS Proxy:${NC} 127.0.0.1:1080"
    fi

    local user_count=0
    if [ -f "$USERS_FILE" ]; then
        user_count=$(grep -c . "$USERS_FILE" 2>/dev/null || echo 0)
    fi
    echo -e "  ${CYAN}Managed Users:${NC} ${YELLOW}${user_count}${NC}"
    echo ""
}

print_success_box() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       NOIZDNS SERVER SETUP COMPLETE          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"

    show_configuration_info

    echo -e "  ${CYAN}DNS Records Required:${NC}"
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
    echo -e "  Run ${WHITE}noizdns${NC} anytime for the management menu."
    echo ""
}

# ─── User Management ─────────────────────────────────────────────────────────

enable_dante_auth() {
    local conf="/etc/danted.conf"
    if [ ! -f "$conf" ]; then
        print_warning "Dante config not found — skipping auth setup"
        return 1
    fi

    # Check if already using username auth
    if grep -q "^socksmethod: username" "$conf" 2>/dev/null; then
        return 0
    fi

    print_status "Enabling Dante username authentication..."

    # Replace global socksmethod
    sed -i 's/^socksmethod: none/socksmethod: username/' "$conf"

    # Add per-rule socksmethod to socks pass block if not present
    if ! grep -A1 "^socks pass {" "$conf" | grep -q "socksmethod:"; then
        sed -i '/^socks pass {/a\    socksmethod: username' "$conf"
    fi

    systemctl restart danted 2>/dev/null && print_status "Dante restarted with username auth" || print_error "Failed to restart Dante"
}

add_user() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "No configuration found. Run install first."
        return 1
    fi
    load_existing_config

    echo ""
    print_line
    echo -e "  ${BOLD}Add User${NC}"
    print_line

    local shell="/usr/sbin/nologin"
    if [ "$TUNNEL_MODE" = "ssh" ]; then
        shell="/bin/bash"
    fi
    echo -e "  Mode: ${YELLOW}${TUNNEL_MODE}${NC} (shell: ${shell})"
    echo ""

    # Username
    local username
    while true; do
        print_question "Username: "
        read -r username
        if [[ -z "$username" ]]; then
            print_error "Username cannot be empty"
            continue
        fi
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            print_error "Invalid username (lowercase letters, digits, hyphens, underscores)"
            continue
        fi
        if id "$username" &>/dev/null; then
            print_error "User '$username' already exists on this system"
            continue
        fi
        if grep -qx "$username" "$USERS_FILE" 2>/dev/null; then
            print_error "User '$username' is already managed by NoizDNS"
            continue
        fi
        break
    done

    # Password
    local password password2
    while true; do
        print_question "Password: "
        read -rs password
        echo ""
        if [[ -z "$password" ]]; then
            print_error "Password cannot be empty"
            continue
        fi
        print_question "Confirm password: "
        read -rs password2
        echo ""
        if [[ "$password" != "$password2" ]]; then
            print_error "Passwords do not match"
            continue
        fi
        break
    done

    # Create Linux user
    useradd -m -s "$shell" "$username"
    echo "$username:$password" | chpasswd

    # Register in users file
    echo "$username" >> "$USERS_FILE"

    print_status "User '$username' created (shell: $shell)"

    # Enable Dante auth on first SOCKS user
    if [ "$TUNNEL_MODE" = "socks" ]; then
        enable_dante_auth
    fi
}

remove_user() {
    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        print_warning "No managed users found."
        return 0
    fi

    echo ""
    print_line
    echo -e "  ${BOLD}Remove User${NC}"
    print_line

    echo ""
    echo "  Managed users:"
    local i=1
    local users=()
    while IFS= read -r user; do
        users+=("$user")
        echo -e "    ${WHITE}${i})${NC} ${user}"
        ((i++))
    done < "$USERS_FILE"
    echo ""

    print_question "Select user to remove (number): "
    read -r selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#users[@]}" ]; then
        print_error "Invalid selection"
        return 1
    fi

    local target="${users[$((selection - 1))]}"

    print_question "Remove user '$target'? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_status "Cancelled."
        return 0
    fi

    userdel -r "$target" 2>/dev/null || userdel "$target" 2>/dev/null || true

    # Remove from users file
    local tmp
    tmp=$(mktemp)
    grep -vx "$target" "$USERS_FILE" > "$tmp" || true
    mv "$tmp" "$USERS_FILE"
    chmod 640 "$USERS_FILE"

    print_status "User '$target' removed."
}

list_users() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "No configuration found. Run install first."
        return 1
    fi
    load_existing_config

    echo ""
    print_line
    echo -e "  ${BOLD}Managed Users${NC}"
    print_line

    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        echo ""
        echo "  No managed users."
        echo ""
        return 0
    fi

    echo ""
    local shell_expected="/usr/sbin/nologin"
    [ "$TUNNEL_MODE" = "ssh" ] && shell_expected="/bin/bash"

    local warned=false
    while IFS= read -r user; do
        local actual_shell
        actual_shell=$(getent passwd "$user" 2>/dev/null | cut -d: -f7)
        if [ -z "$actual_shell" ]; then
            echo -e "  ${RED}●${NC} ${user}  ${RED}(Linux user missing!)${NC}"
        elif [ "$actual_shell" != "$shell_expected" ]; then
            echo -e "  ${YELLOW}●${NC} ${user}  (shell: ${actual_shell})"
            warned=true
        else
            echo -e "  ${GREEN}●${NC} ${user}  (shell: ${actual_shell})"
        fi
    done < "$USERS_FILE"

    echo ""
    if [ "$warned" = true ]; then
        print_warning "Some users have a shell that doesn't match the current mode (${TUNNEL_MODE})."
        print_warning "Remove and re-add them, or change their shell manually."
        echo ""
    fi
}

change_user_password() {
    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        print_warning "No managed users found."
        return 0
    fi

    echo ""
    print_line
    echo -e "  ${BOLD}Change Password${NC}"
    print_line

    echo ""
    echo "  Managed users:"
    local i=1
    local users=()
    while IFS= read -r user; do
        users+=("$user")
        echo -e "    ${WHITE}${i})${NC} ${user}"
        ((i++))
    done < "$USERS_FILE"
    echo ""

    print_question "Select user (number): "
    read -r selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#users[@]}" ]; then
        print_error "Invalid selection"
        return 1
    fi

    local target="${users[$((selection - 1))]}"

    local password password2
    while true; do
        print_question "New password for '$target': "
        read -rs password
        echo ""
        if [[ -z "$password" ]]; then
            print_error "Password cannot be empty"
            continue
        fi
        print_question "Confirm password: "
        read -rs password2
        echo ""
        if [[ "$password" != "$password2" ]]; then
            print_error "Passwords do not match"
            continue
        fi
        break
    done

    echo "$target:$password" | chpasswd
    print_status "Password changed for '$target'."
}

remove_all_managed_users() {
    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        return 0
    fi

    local count
    count=$(grep -c . "$USERS_FILE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        return 0
    fi

    echo ""
    print_warning "There are $count managed user(s) that will be removed:"
    while IFS= read -r user; do
        echo "    - $user"
    done < "$USERS_FILE"
    echo ""

    print_question "Remove all managed users? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Skipping user removal. Users will remain on the system."
        return 0
    fi

    while IFS= read -r user; do
        userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
        print_status "Removed user: $user"
    done < "$USERS_FILE"

    > "$USERS_FILE"
    print_status "All managed users removed."
}

user_management_menu() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "No configuration found. Run install first."
        return 1
    fi
    load_existing_config

    while true; do
        echo ""
        print_line
        echo -e "  ${BOLD}User Management${NC} (mode: ${YELLOW}${TUNNEL_MODE}${NC})"
        print_line

        local user_count=0
        if [ -f "$USERS_FILE" ]; then
            user_count=$(grep -c . "$USERS_FILE" 2>/dev/null || echo 0)
        fi
        echo -e "  Managed users: ${YELLOW}${user_count}${NC}"
        echo ""

        echo -e "  ${WHITE}1)${NC} Add user"
        echo -e "  ${WHITE}2)${NC} Remove user"
        echo -e "  ${WHITE}3)${NC} List users"
        echo -e "  ${WHITE}4)${NC} Change password"
        echo -e "  ${WHITE}0)${NC} Back"
        echo ""
        print_question "Choice: "
        read -r uchoice
        echo ""

        case $uchoice in
            1) add_user ;;
            2) remove_user ;;
            3) list_users ;;
            4) change_user_password ;;
            0) return 0 ;;
            *) print_error "Invalid choice" ;;
        esac

        echo ""
        print_question "Press Enter to continue..."
        read -r
    done
}

# ─── Script Update ────────────────────────────────────────────────────────────

update_script() {
    print_status "Checking for updates..."

    local temp="/tmp/noizdns-deploy-latest.sh"
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

# ─── Uninstall ────────────────────────────────────────────────────────────────

uninstall() {
    echo ""
    print_warning "This will remove NoizDNS server and all its data."
    echo ""
    echo "  The following will be deleted:"
    echo "    - Service:    ${SERVICE_NAME}"
    echo "    - Binary:     ${INSTALL_DIR}/dnstt-server"
    echo "    - Config:     ${CONFIG_DIR}/ (keys, settings)"
    echo "    - User:       ${SERVICE_USER}"
    echo "    - iptables:   port 53 -> ${DNSTT_PORT} redirect"
    echo "    - Script:     ${SCRIPT_INSTALL_PATH}"
    if systemctl is-active --quiet danted 2>/dev/null; then
        echo "    - Dante:      SOCKS proxy will be stopped"
    fi
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        local ucount
        ucount=$(grep -c . "$USERS_FILE" 2>/dev/null || echo 0)
        echo "    - Users:      ${ucount} managed user(s)"
    fi
    echo ""

    print_question "Are you sure? Type 'yes' to confirm: "
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        print_status "Uninstall cancelled."
        return 0
    fi

    echo ""

    # Stop and disable service
    print_status "Stopping service..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
    systemctl daemon-reload

    # Stop Dante if running
    if systemctl is-active --quiet danted 2>/dev/null; then
        print_status "Stopping Dante SOCKS proxy..."
        systemctl stop danted 2>/dev/null || true
        systemctl disable danted 2>/dev/null || true
    fi

    # Remove iptables rules
    detect_os >/dev/null 2>&1 || true
    remove_iptables_rules

    # Remove binary
    print_status "Removing binary..."
    rm -f "${INSTALL_DIR}/dnstt-server"

    # Remove managed users
    remove_all_managed_users

    # Remove config directory (keys and settings)
    print_status "Removing configuration and keys..."
    rm -rf "$CONFIG_DIR"

    # Remove user
    print_status "Removing service user..."
    userdel "$SERVICE_USER" 2>/dev/null || true

    # Remove this script
    print_status "Removing deploy script..."
    local self="$SCRIPT_INSTALL_PATH"
    rm -f "$self"

    echo ""
    print_status "NoizDNS server has been completely removed."
    echo ""

    exit 0
}

# ─── Interactive Menu ─────────────────────────────────────────────────────────

show_banner() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  NoizDNS Server  ${WHITE}v${SCRIPT_VERSION}${NC}${GREEN}                        ║${NC}"
    echo -e "${GREEN}║  dnstt + NoizDNS (auto-detected)             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
}

show_menu() {
    # Check if installed
    local installed=false
    is_installed && installed=true

    echo ""
    print_line
    echo -e "  ${BOLD}NoizDNS Server Management${NC}"
    print_line
    echo ""

    if [ "$installed" = true ]; then
        local status_text
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            status_text="${GREEN}Running${NC}"
        else
            status_text="${RED}Stopped${NC}"
        fi
        echo -e "  Status: $status_text"
        echo ""
    fi

    echo -e "  ${WHITE}1)${NC} Install / Reconfigure"
    echo -e "  ${WHITE}2)${NC} Show configuration"
    echo -e "  ${WHITE}3)${NC} Service status"
    echo -e "  ${WHITE}4)${NC} View live logs"
    echo -e "  ${WHITE}5)${NC} User management"
    echo -e "  ${WHITE}6)${NC} Restart service"
    echo -e "  ${WHITE}7)${NC} Stop service"
    echo -e "  ${WHITE}8)${NC} Start service"
    echo -e "  ${WHITE}9)${NC} Update binary"
    echo -e "  ${WHITE}10)${NC} Update this script"
    echo -e "  ${RED}11)${NC} Uninstall"
    echo -e "  ${WHITE}0)${NC} Exit"
    echo ""
    print_question "Choice: "
}

handle_menu() {
    while true; do
        show_menu
        read -r choice
        echo ""
        case $choice in
            1)
                return 0
                ;;
            2)
                show_configuration_info
                ;;
            3)
                if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                    print_status "Service is running"
                else
                    print_warning "Service is not running"
                fi
                systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || true
                ;;
            4)
                print_status "Showing logs (Ctrl+C to exit)..."
                journalctl -u "$SERVICE_NAME" -f
                ;;
            5)
                user_management_menu
                ;;
            6)
                systemctl restart "$SERVICE_NAME" 2>/dev/null && print_status "Service restarted" || print_error "Failed to restart"
                ;;
            7)
                systemctl stop "$SERVICE_NAME" 2>/dev/null && print_status "Service stopped" || print_error "Failed to stop"
                ;;
            8)
                systemctl start "$SERVICE_NAME" 2>/dev/null && print_status "Service started" || print_error "Failed to start"
                ;;
            9)
                detect_os
                detect_arch
                download_binary
                print_status "Binary updated. Restarting service..."
                systemctl restart "$SERVICE_NAME" 2>/dev/null && print_status "Service restarted" || print_warning "Service not running"
                ;;
            10)
                update_script
                ;;
            11)
                uninstall
                ;;
            0)
                echo -e "  ${GREEN}Goodbye!${NC}"
                echo ""
                exit 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac

        if [ "$choice" != "4" ] && [ "$choice" != "5" ]; then
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
    print_status "Run ${WHITE}noizdns${NC} anytime for the management menu"
}

# ─── Main Install Flow ───────────────────────────────────────────────────────

do_install() {
    # Detect environment
    detect_os
    detect_arch

    # Install deps
    install_dependencies

    # Get configuration
    get_user_input

    # Download binary
    download_binary

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

# ─── Entry Point ──────────────────────────────────────────────────────────────

main() {
    show_banner

    # Install script to PATH
    install_script

    # If running from installed location, show interactive menu
    if [ "$(realpath "$0" 2>/dev/null || echo "$0")" = "$SCRIPT_INSTALL_PATH" ]; then
        # handle_menu returns 0 when user picks "Install / Reconfigure"
        while true; do
            handle_menu
            do_install
            echo ""
            print_question "Press Enter to return to menu..."
            read -r
        done
    fi

    # First-time install (run via curl)
    do_install
}

main "$@"
