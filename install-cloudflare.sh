#!/usr/bin/env bash
set -euo pipefail

readonly CADDY_CF_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy-cloudflare.sh"
readonly CLI_BIN="/usr/local/bin/c"
readonly CADDY_BIN="/usr/bin/caddy"
readonly XCADDY_BIN="/usr/local/bin/xcaddy"
readonly CLOUDFLARE_MODULE="github.com/caddy-dns/cloudflare"
readonly CLOUD_FILE_DROPIN="/etc/systemd/system/caddy.service.d/10-cloudflare-env.conf"
readonly CLOUD_ENV_FILE="/etc/caddy/cloudflare.env"

log() {
    echo "$*"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Please run this script as root (or with sudo)."
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

install_dependencies() {
    log "[1/6] Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git golang-go build-essential python3
}

install_xcaddy() {
    log "[2/6] Installing xcaddy..."
    if [[ -x "$XCADDY_BIN" ]]; then
        log "xcaddy already installed: $XCADDY_BIN"
        return
    fi

    GOBIN="$(dirname "$XCADDY_BIN")" go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    [[ -x "$XCADDY_BIN" ]] || die "xcaddy installation failed: $XCADDY_BIN"
}

build_caddy_with_cloudflare() {
    log "[3/6] Building Caddy with Cloudflare DNS module..."
    local tmpdir built
    tmpdir="$(mktemp -d)"
    built="$tmpdir/caddy"

    "$XCADDY_BIN" build --with "$CLOUDFLARE_MODULE" --output "$built"
    [[ -s "$built" ]] || die "Built Caddy binary is empty"

    if command -v dpkg-divert >/dev/null 2>&1; then
        dpkg-divert --package caddyctl --add --rename --divert /usr/bin/caddy.default /usr/bin/caddy >/dev/null 2>&1 || true
    fi

    install -m 0755 "$built" "$CADDY_BIN"
    rm -rf "$tmpdir"
}

install_cli() {
    log "[4/6] Installing c command..."
    local tmp
    tmp="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 1 "$CADDY_CF_URL" -o "$tmp"
    [[ -s "$tmp" ]] || die "Downloaded CLI script is empty: $CADDY_CF_URL"
    bash -n "$tmp"
    install -m 0755 "$tmp" "$CLI_BIN"
    rm -f "$tmp"
}

prepare_layout() {
    log "[5/6] Preparing layout and Cloudflare service drop-in..."
    install -d -m 0755 /etc/caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup /var/log/caddy
    touch /etc/caddy/caddyctl.conf
    chmod 644 /etc/caddy/caddyctl.conf

    install -d -m 0755 /etc/systemd/system/caddy.service.d
    cat > "$CLOUD_FILE_DROPIN" <<EOF2
[Service]
EnvironmentFile=-$CLOUD_ENV_FILE
EOF2
    chmod 644 "$CLOUD_FILE_DROPIN"

    if getent group caddy >/dev/null 2>&1; then
        chown root:caddy /etc/caddy /etc/caddy/caddyctl.conf || true
        chown -R root:caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup || true
        chown caddy:caddy /var/log/caddy || true
    fi

    chmod 755 /etc/caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup /var/log/caddy || true
    find /etc/caddy/sites.d -type f -name '*.conf' -exec chmod 644 {} \; 2>/dev/null || true
    find /etc/caddy/globals.d -type f -name '*.inc' -exec chmod 644 {} \; 2>/dev/null || true
}

enable_and_restart_service() {
    log "[6/6] Enabling and restarting Caddy service..."
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl not found, skip service startup."
        return
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy
}

main() {
    require_root
    require_command apt-get
    require_command curl
    require_command bash
    require_command go

    log "Starting Caddy Cloudflare installer..."
    install_dependencies
    install_xcaddy
    build_caddy_with_cloudflare
    install_cli
    prepare_layout
    enable_and_restart_service

    echo
    log "Install complete."
    log "--------------------------------"
    log "Open panel: c"
    log "Run doctor: c doctor"
    log "Set Cloudflare token: c cloudflare <token>"
    log "--------------------------------"
}

main "$@"
