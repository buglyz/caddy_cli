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
readonly OPENRC_CONF_D="/etc/conf.d/caddy"

DISTRO=""
BUILD_FROM_SOURCE=0

detect_distro() {
    if [ -f /etc/alpine-release ]; then
        DISTRO="alpine"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
    else
        DISTRO="unknown"
    fi
}

log() {
    echo "$*"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

on_error() {
    local exit_code="$?"
    local line_no="${1:-unknown}"
    echo "Error: install failed (exit=${exit_code}, line=${line_no})" >&2
    exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Please run this script as root (or with sudo)."
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

# ── Debian ──────────────────────────────────────────────

install_deps_debian() {
    log "[1/5] Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git python3
}

install_build_deps_debian() {
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
    local step_label="${1:-}"
    [[ -n "$step_label" ]] && log "[${step_label}] Downloading pre-built Caddy from repo..." || log "Downloading pre-built Caddy from repo..."
    local tmp
    tmp="$(mktemp)"

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

prepare_layout_debian() {
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

enable_service_debian() {
    log "Enabling and restarting Caddy service..."
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl not found, skip service startup."
        return
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy 2>/dev/null || log "(Warning) Caddy 启动失败，请手动检查配置"
}

# ── Alpine ───────────────────────────────────────────────

# Install only the init script from Alpine caddy package (gives us /etc/init.d/caddy).
# We overwrite the binary later with the CF build.
install_alpine_init_script() {
    if [[ -f /etc/init.d/caddy ]]; then
        log "OpenRC init script already present"
        return 0
    fi
    enable_community_repo
    apk update
    log "Installing caddy package for OpenRC init script (binary will be replaced)..."
    apk add --no-cache caddy
}

install_deps_alpine() {
    log "[1/5] Installing dependencies (Alpine)..."
    apk update
    apk add --no-cache ca-certificates curl gnupg python3
}

install_build_deps_alpine() {
    log "[build] Installing build dependencies (Alpine)..."
    apk update
    apk add --no-cache ca-certificates curl gnupg git go python3
}

prepare_layout_alpine() {
    log "[4/5] Preparing layout and OpenRC service config..."
    install -d -m 0755 /etc/caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup /var/log/caddy
    touch /etc/caddy/caddyctl.conf
    chmod 644 /etc/caddy/caddyctl.conf

    # OpenRC: source cloudflare env from conf.d
    if [[ ! -f "$OPENRC_CONF_D" ]]; then
        cat > "$OPENRC_CONF_D" <<'EOF'
# Managed by caddyctl
[ -f /etc/caddy/cloudflare.env ] && . /etc/caddy/cloudflare.env
EOF
        chmod 644 "$OPENRC_CONF_D"
    fi

    if getent group caddy >/dev/null 2>&1; then
        chown root:caddy /etc/caddy /etc/caddy/caddyctl.conf || true
        chown -R root:caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup || true
        chown caddy:caddy /var/log/caddy || true
    fi

    chmod 755 /etc/caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup /var/log/caddy || true
    find /etc/caddy/sites.d -type f -name '*.conf' -exec chmod 644 {} \; 2>/dev/null || true
    find /etc/caddy/globals.d -type f -name '*.inc' -exec chmod 644 {} \; 2>/dev/null || true
}

enable_service_alpine() {
    log "[5/5] Enabling and starting Caddy (OpenRC)..."
    if ! command -v rc-service >/dev/null 2>&1; then
        log "rc-service not found, skip service startup."
        return
    fi
    rc-update add caddy default 2>/dev/null || true
    rc-service caddy restart 2>/dev/null || log "(Warning) Caddy 启动失败，请手动检查配置"
}

# ── Shared ───────────────────────────────────────────────

install_cli_cf() {
    local step="$1"
    log "[${step}] Installing c command (Cloudflare edition)..."

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

# ── Main ─────────────────────────────────────────────────

install_debian() {
    require_command apt-get
    require_command curl

    log "Mode: $([ "$BUILD_FROM_SOURCE" -eq 1 ] && echo 'Build from source' || echo 'Pre-built binary (default)')"

    if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
        install_build_deps_debian
        require_command go
        install_xcaddy
        build_caddy_with_cloudflare
    else
        install_deps_debian
        download_caddy_from_repo "3/5"
    fi

    install_cli_cf "4/5"
    prepare_layout_debian
    enable_service_debian

    echo
    log "Install complete."
    log "--------------------------------"
    log "c doctor            检查环境"
    log "c cloudflare <token>  设置 Cloudflare Token"
    log "c cloudflare check    检查 DNS-01 就绪"
    log "--------------------------------"
}

install_alpine() {
    require_command apk
    require_command curl

    log "Starting Caddy Cloudflare installer (Alpine Linux)..."
    log "Mode: $([ "$BUILD_FROM_SOURCE" -eq 1 ] && echo 'Build from source' || echo 'Pre-built binary (default)')"

    if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
        install_alpine_init_script
        install_build_deps_alpine
        require_command go
        log "[2/5] Building Caddy with Cloudflare DNS module..."
        install_xcaddy
        build_caddy_with_cloudflare
    else
        install_alpine_init_script
        install_deps_alpine
        log "[2/5] Downloading pre-built Caddy (CGO_ENABLED=0, musl compatible)..."
        download_caddy_from_repo "2/5"
        # Verify the binary actually works on this system
        if ! "$CADDY_BIN" version >/dev/null 2>&1; then
            log "Pre-built binary failed on this system, falling back to build from source..."
            install_build_deps_alpine
            require_command go
            install_xcaddy
            build_caddy_with_cloudflare
        fi
    fi

    install_cli_cf "3/5"
    prepare_layout_alpine
    enable_service_alpine

    echo
    log "Install complete."
    log "--------------------------------"
    log "c doctor            检查环境"
    log "c cloudflare <token>  设置 Cloudflare Token"
    log "c cloudflare check    检查 DNS-01 就绪"
    log "--------------------------------"
}

print_usage() {
    cat <<EOF
Usage: $0 [--build-from-source]

  Default (Debian): download pre-built Caddy from GitHub repo (fast, no Go needed)
  --build-from-source  Build Caddy from source with xcaddy (needs Go)

  Alpine: uses pre-built binary by default (CGO_ENABLED=0, musl compatible).
          Use --build-from-source to compile locally instead.
EOF
}

main() {
    require_root
    require_command bash

    for arg in "$@"; do
        case "$arg" in
            --build-from-source) BUILD_FROM_SOURCE=1 ;;
            --help|-h) print_usage; exit 0 ;;
            --use-release) ;;  # backwards compat, now default
            *) die "Unknown option: $arg (use --help)" ;;
        esac
    done

    detect_distro

    case "$DISTRO" in
        debian) install_debian ;;
        alpine) install_alpine ;;
        *) die "Unsupported distribution. Currently supported: Debian/Ubuntu, Alpine Linux." ;;
    esac
}

main "$@"
