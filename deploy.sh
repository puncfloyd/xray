#!/usr/bin/env bash

set -Eeuo pipefail

DEFAULT_XRAY_VERSION="v26.3.27"
XRAY_VERSION="${XRAY_VERSION:-$DEFAULT_XRAY_VERSION}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
PORT_MIN="${PORT_MIN:-5000}"
PORT_MAX="${PORT_MAX:-60000}"

XRAY_DIR="/etc/xray"
XRAY_BIN="${XRAY_DIR}/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_INFO="${XRAY_DIR}/node.info"
XRAY_SERVICE="/etc/systemd/system/xray.service"
DOWNLOAD_DIR="/tmp/xray-install.$$"
IPV6_DISABLE_CONF="/etc/sysctl.d/99-disable-ipv6.conf"
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

OS_ID=""
OS_VERSION_CODENAME=""
OS_VERSION_ID=""
OS_PRETTY_NAME=""

log() {
    printf '[INFO] %s\n' "$*" >&2
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    rm -rf "$DOWNLOAD_DIR"
}

trap cleanup EXIT

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Please run this script as root."
    fi
}

validate_settings() {
    [[ "$XRAY_VERSION" =~ ^v[0-9]+(\.[0-9]+){1,3}$ ]] ||
        die "Invalid XRAY_VERSION: $XRAY_VERSION"

    is_port "$PORT_MIN" || die "Invalid PORT_MIN: $PORT_MIN"
    is_port "$PORT_MAX" || die "Invalid PORT_MAX: $PORT_MAX"
    [ "$PORT_MIN" -le "$PORT_MAX" ] || die "PORT_MIN must be less than or equal to PORT_MAX."

    if [ "$LISTEN_ADDR" != "0.0.0.0" ] && [ "$LISTEN_ADDR" != "127.0.0.1" ] && ! is_ipv4 "$LISTEN_ADDR"; then
        die "Invalid LISTEN_ADDR: $LISTEN_ADDR"
    fi
}

is_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

detect_os() {
    if [ ! -r /etc/os-release ]; then
        die "Cannot read /etc/os-release."
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"

    case "$OS_ID" in
        debian|ubuntu)
            log "Detected OS: $OS_PRETTY_NAME"
            ;;
        *)
            die "Unsupported OS: $OS_PRETTY_NAME. This script supports Debian and Ubuntu."
            ;;
    esac
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "systemctl is not available."
    [ -d /run/systemd/system ] || die "systemd does not appear to be running."
}

apt_update() {
    if apt-get update >&2; then
        return 0
    fi

    if [ "$OS_ID" = "debian" ] &&
        { [ "$OS_VERSION_CODENAME" = "bullseye" ] || [ "$OS_VERSION_ID" = "11" ]; }; then
        warn "apt-get update failed on Debian bullseye; switching to archive.debian.org."
        configure_debian_bullseye_archive_sources
        apt-get update -o Acquire::Check-Valid-Until=false >&2
        return 0
    fi

    die "apt-get update failed. Fix your apt sources or network, then rerun this script."
}

configure_debian_bullseye_archive_sources() {
    local backup="/etc/apt/sources.list.backup.$(date +%Y%m%d%H%M%S)"

    if [ -f /etc/apt/sources.list ]; then
        cp -a /etc/apt/sources.list "$backup"
        log "Backed up /etc/apt/sources.list to $backup"
    fi

    cat > /etc/apt/sources.list <<'EOF'
deb http://archive.debian.org/debian bullseye main contrib non-free
deb http://archive.debian.org/debian bullseye-updates main contrib non-free
EOF

    cat > /etc/apt/apt.conf.d/99archive <<'EOF'
Acquire::Check-Valid-Until "false";
EOF
}

disable_ipv6() {
    log "Disabling IPv6"
    cat > "$IPV6_DISABLE_CONF" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    chmod 644 "$IPV6_DISABLE_CONF"
    sysctl --system >/dev/null 2>&1
}

enable_bbr() {
    local available current

    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ "$available" != *bbr* ]]; then
        warn "BBR is not available on this kernel."
        printf 'failed\n'
        return 0
    fi

    cat > "$BBR_CONF" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    chmod 644 "$BBR_CONF"

    if ! sysctl --system >/dev/null 2>&1; then
        warn "Failed to apply BBR sysctl settings."
        printf 'failed\n'
        return 0
    fi

    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    if [ "$current" = "bbr" ]; then
        printf 'ok\n'
    else
        warn "BBR sysctl applied, but current congestion control is: ${current:-unknown}"
        printf 'failed\n'
    fi
}

install_dependencies() {
    log "Installing dependencies"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates \
        curl \
        unzip \
        wget \
        iproute2 >&2
}

xray_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'Xray-linux-64.zip'
            ;;
        aarch64|arm64)
            printf 'Xray-linux-arm64-v8a.zip'
            ;;
        armv7l|armv7)
            printf 'Xray-linux-arm32-v7a.zip'
            ;;
        *)
            die "Unsupported CPU architecture: $(uname -m)"
            ;;
    esac
}

download_and_install_xray() {
    local asset url

    asset="$(xray_asset_name)"
    url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${asset}"

    log "Installing Xray ${XRAY_VERSION} (${asset})"
    mkdir -p "$DOWNLOAD_DIR" "$XRAY_DIR"

    wget -q "$url" -O "${DOWNLOAD_DIR}/xray.zip"
    unzip -o "${DOWNLOAD_DIR}/xray.zip" -d "$XRAY_DIR" >/dev/null

    [ -x "$XRAY_BIN" ] || chmod 755 "$XRAY_BIN"
    "$XRAY_BIN" version >&2
}

port_is_free() {
    local port="$1"
    ! ss -H -lnt "( sport = :$port )" | grep -q .
}

choose_random_port() {
    local port attempts

    for attempts in $(seq 1 100); do
        port="$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 1)"
        if port_is_free "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done

    die "Could not find a free TCP port in ${PORT_MIN}-${PORT_MAX} after 100 attempts."
}

detect_public_ip() {
    local ip api host
    local apis=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )

    for api in "${apis[@]}"; do
        ip="$(curl -4fsS --max-time 10 "$api" 2>/dev/null | tr -d '[:space:]' || true)"
        host="${api#https://}"
        host="${host%%/*}"

        if is_ipv4 "$ip" && ! is_private_or_reserved_ipv4 "$ip"; then
            printf '%s|external_api:%s|normal\n' "$ip" "$host"
            return 0
        elif [ -n "$ip" ]; then
            warn "$host returned an invalid or private/reserved IPv4 address: $ip"
        fi
    done

    ip="$(detect_local_route_ipv4)"
    if is_ipv4 "$ip"; then
        if is_private_or_reserved_ipv4 "$ip"; then
            warn "External IP detection failed. Local route IP is private/reserved: $ip"
            warn "The SOCKS5 service may not be reachable from the public internet with this address."
        else
            warn "External IP detection failed. Falling back to local route IP: $ip"
        fi

        printf '%s|local_route|low\n' "$ip"
        return 0
    fi

    die "Failed to detect an IPv4 address."
}

detect_local_route_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

is_ipv4() {
    local ip="$1"

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS=.
    local octets octet
    read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

is_private_or_reserved_ipv4() {
    local ip="$1"
    local IFS=.
    local octets a b

    is_ipv4 "$ip" || return 1
    read -r -a octets <<< "$ip"
    a="${octets[0]}"
    b="${octets[1]}"

    [ "$a" -eq 10 ] && return 0
    [ "$a" -eq 127 ] && return 0
    [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
    [ "$a" -eq 0 ] && return 0
    [ "$a" -ge 224 ] && return 0

    return 1
}

random_alnum() {
    local length="$1"

    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length" || true
}

write_xray_config() {
    local port="$1"
    local public_ip="$2"
    local socks_user="$3"
    local socks_pass="$4"

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ]
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "$LISTEN_ADDR",
      "port": $port,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$socks_user",
            "pass": "$socks_pass"
          }
        ],
        "udp": true,
        "ip": "$public_ip"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

    chmod 600 "$XRAY_CONFIG"
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >&2
}

write_systemd_service() {
    cat > "$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray SOCKS5 Proxy
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_node_info() {
    local port="$1"
    local public_ip="$2"
    local socks_user="$3"
    local socks_pass="$4"

    cat > "$XRAY_INFO" <<EOF
IP=$public_ip
PORT=$port
USER=$socks_user
PASS=$socks_pass
LISTEN=$LISTEN_ADDR
XRAY_VERSION=$XRAY_VERSION
EOF

    chmod 600 "$XRAY_INFO"
}

start_service() {
    systemctl daemon-reload >&2
    systemctl enable xray >&2
    systemctl restart xray >&2
    systemctl is-active --quiet xray || die "xray service failed to start. Check: journalctl -u xray --no-pager"
    log "xray service is active"
}

print_result() {
    local port="$1"
    local public_ip="$2"
    local socks_user="$3"
    local socks_pass="$4"
    local bbr_status="$5"

    printf 'host: %s\n' "$public_ip"
    printf 'port: %s\n' "$port"
    printf 'user: %s\n' "$socks_user"
    printf 'pass: %s\n' "$socks_pass"
    printf 'bbr: %s\n' "$bbr_status"
}

main() {
    local port ip_result public_ip ip_source ip_confidence socks_user socks_pass bbr_status

    require_root
    validate_settings
    detect_os
    require_systemd
    disable_ipv6
    bbr_status="$(enable_bbr)"
    apt_update
    install_dependencies
    download_and_install_xray

    port="$(choose_random_port)"
    ip_result="$(detect_public_ip)"
    IFS='|' read -r public_ip ip_source ip_confidence <<< "$ip_result"
    socks_user="$(random_alnum 12)"
    socks_pass="$(random_alnum 20)"

    [ -n "$socks_user" ] || die "Failed to generate SOCKS5 username."
    [ -n "$socks_pass" ] || die "Failed to generate SOCKS5 password."

    write_xray_config "$port" "$public_ip" "$socks_user" "$socks_pass"
    write_systemd_service
    write_node_info "$port" "$public_ip" "$socks_user" "$socks_pass"
    start_service
    print_result "$port" "$public_ip" "$socks_user" "$socks_pass" "$bbr_status"
}

main "$@"
