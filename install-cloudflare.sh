#!/usr/bin/env bash
set -euo pipefail

readonly CADDY_CF_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy-cloudflare"
readonly LIB_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy-lib.sh"
readonly CADDY_RAW_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy"
readonly CLI_BIN="/usr/local/bin/c"
readonly LIB_BIN="/usr/local/bin/caddy-lib.sh"
readonly CADDY_BIN="/usr/bin/caddy"
readonly XCADDY_BIN="/usr/local/bin/xcaddy"
readonly CLOUDFLARE_MODULE="github.com/caddy-dns/cloudflare"
readonly CLOUD_FILE_DROPIN="/etc/systemd/system/caddy.service.d/10-cloudflare-env.conf"
readonly CLOUD_ENV_FILE="/etc/caddy/cloudflare.env"

BUILD_FROM_SOURCE=0

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
    log "[1/5] Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git python3
}

install_build_deps() {
    log "[build] Installing build dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git golang-go build-essential python3
}

install_xcaddy() {
    log "[build] Installing xcaddy..."
    if [[ -x "$XCADDY_BIN" ]]; then
        log "xcaddy already installed: $XCADDY_BIN"
        return
    fi

    require_command go
    GOBIN="$(dirname "$XCADDY_BIN")" go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    [[ -x "$XCADDY_BIN" ]] || die "xcaddy installation failed: $XCADDY_BIN"
}

build_caddy_with_cloudflare() {
    log "[build] Building Caddy with Cloudflare DNS module..."
    local tmpdir built
    tmpdir="$(mktemp -d)"
    built="$tmpdir/caddy"

    "$XCADDY_BIN" build --with "$CLOUDFLARE_MODULE" --output "$built"
    [[ -s "$built" ]] || die "Built Caddy binary is empty"

    install_caddy_binary "$built"
    rm -rf "$tmpdir"
}

download_caddy_from_repo() {
    log "[3/5] Downloading pre-built Caddy from repo..."
    local tmp
    tmp="$(mktemp)"

    # Try GitHub raw first, fall back to jsDelivr CDN
    if ! curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 120 \
        "$CADDY_RAW_URL" -o "$tmp" 2>/dev/null; then
        log "GitHub raw slow, trying jsDelivr CDN..."
        curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 120 \
            "https://cdn.jsdelivr.net/gh/buglyz/caddy_cli@main/caddy" -o "$tmp" \
            || die "Download failed: $CADDY_RAW_URL"
    fi

    [[ -s "$tmp" ]] || die "Downloaded Caddy binary is empty"

    install_caddy_binary "$tmp"
    rm -f "$tmp"
}

install_caddy_binary() {
    local src="$1"
    if command -v dpkg-divert >/dev/null 2>&1; then
        dpkg-divert --local --add --rename --divert /usr/bin/caddy.default /usr/bin/caddy >/dev/null 2>&1 || true
    fi
    install -m 0755 "$src" "$CADDY_BIN"
    log "Caddy installed: $("$CADDY_BIN" version 2>&1 | head -1)"
}

install_cli() {
    log "[4/5] Installing c command..."

    local tmp_lib
    tmp_lib="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 1 "$LIB_URL" -o "$tmp_lib"
    [[ -s "$tmp_lib" ]] || die "Downloaded library script is empty: $LIB_URL"
    bash -n "$tmp_lib"
    install -m 0644 "$tmp_lib" "$LIB_BIN"
    rm -f "$tmp_lib"

    local tmp_cli
    tmp_cli="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 1 "$CADDY_CF_URL" -o "$tmp_cli"
    [[ -s "$tmp_cli" ]] || die "Downloaded CLI script is empty: $CADDY_CF_URL"
    bash -n "$tmp_cli"
    install -m 0755 "$tmp_cli" "$CLI_BIN"
    rm -f "$tmp_cli"
}

prepare_layout() {
    log "[5/5] Preparing layout and Cloudflare service drop-in..."
    install -d -m 0755 /etc/caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup /var/log/caddy
    touch /etc/caddy/caddyctl.conf
    chmod 644 /etc/caddy/caddyctl.conf

    install -d -m 0755 /etc/systemd/system/caddy.service.d
    cat > "$CLOUD_FILE_DROPIN" <<EOF
[Service]
EnvironmentFile=-$CLOUD_ENV_FILE
EOF
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
    log "Enabling and restarting Caddy service..."
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl not found, skip service startup."
        return
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy 2>/dev/null || log "(Warning) Caddy 启动失败，请手动检查配置"
}

main() {
    require_root
    require_command apt-get
    require_command curl
    require_command bash

    for arg in "$@"; do
        case "$arg" in
            --build-from-source) BUILD_FROM_SOURCE=1 ;;
            --help|-h)
                echo "Usage: $0 [--build-from-source]"
                echo ""
                echo "  Default: download pre-built Caddy from GitHub repo (fast, no Go needed)"
                echo "  --build-from-source  Build Caddy from source with xcaddy (needs Go)"
                exit 0
                ;;
            --use-release) ;;  # backwards compat, now default
        esac
    done

    log "Starting Caddy Cloudflare installer..."
    log "Mode: $([ "$BUILD_FROM_SOURCE" -eq 1 ] && echo 'Build from source' || echo 'Pre-built binary (default)')"

    if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
        install_build_deps
        require_command go
        install_xcaddy
        build_caddy_with_cloudflare
    else
        install_dependencies
        download_caddy_from_repo
    fi

    install_cli
    prepare_layout
    enable_and_restart_service

    echo
    log "Install complete."
    log "--------------------------------"
    log "c doctor            检查环境"
    log "c cloudflare <token>  设置 Cloudflare Token"
    log "c cloudflare check    检查 DNS-01 就绪"
    log "--------------------------------"
}

main "$@"
