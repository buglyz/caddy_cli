#!/usr/bin/env bash
set -euo pipefail

readonly CLI_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy.sh"
readonly LIB_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy-lib.sh"
readonly CLI_BIN="/usr/local/bin/c"
readonly LIB_BIN="/usr/local/bin/caddy-lib.sh"

# Debian-specific
readonly CADDY_GPG_KEY_URL="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
readonly CADDY_APT_LIST_URL="https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"

DISTRO=""
apt_index_updated=0

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
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
}

# ── Debian ──────────────────────────────────────────────

apt_update_once() {
    if (( apt_index_updated == 0 )); then
        log "[1/7] Updating apt index..."
        apt-get update
        apt_index_updated=1
    fi
}

install_deps_debian() {
    log "[2/7] Installing dependencies..."
    apt_update_once
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg python3 debian-keyring debian-archive-keyring
}

setup_caddy_repo() {
    log "[3/7] Configuring official Caddy repository..."
    install -d -m 0755 /usr/share/keyrings

    curl -fsSL --retry 3 --retry-delay 1 "$CADDY_GPG_KEY_URL" \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -fsSL --retry 3 --retry-delay 1 "$CADDY_APT_LIST_URL" \
        -o /etc/apt/sources.list.d/caddy-stable.list

    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list
}

install_or_keep_caddy_debian() {
    if command -v caddy >/dev/null 2>&1; then
        log "[4/7] Caddy already installed: $(caddy version 2>/dev/null || echo unknown)"
        return
    fi

    setup_caddy_repo
    apt_index_updated=0
    apt_update_once
    log "[4/7] Installing Caddy..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
}

# ── Alpine ───────────────────────────────────────────────

install_deps_alpine() {
    log "[1/4] Installing dependencies (Alpine)..."
    apk update
    apk add --no-cache ca-certificates curl gnupg python3
}

enable_community_repo() {
    if grep -q '^http.*/community' /etc/apk/repositories 2>/dev/null; then
        return 0
    fi
    log "Enabling Alpine community repository..."
    local mirror ver
    mirror="$(grep '^http.*/main$' /etc/apk/repositories 2>/dev/null | head -1 | sed 's,/main$,,' || true)"
    if [[ -z "$mirror" ]]; then
        ver="$(cut -d. -f1,2 /etc/alpine-release)"
        mirror="https://dl-cdn.alpinelinux.org/alpine/v${ver}"
    fi
    echo "${mirror}/community" >> /etc/apk/repositories
}

install_or_keep_caddy_alpine() {
    if command -v caddy >/dev/null 2>&1; then
        log "[2/4] Caddy already installed: $(caddy version 2>/dev/null || echo unknown)"
        return
    fi
    enable_community_repo
    apk update
    log "[2/4] Installing Caddy from community repo..."
    apk add --no-cache caddy
}

# ── Shared (both distros) ────────────────────────────────

install_cli() {
    local step="$1"
    log "[${step}] Installing c command..."

    local tmp_lib tmp_cli

    tmp_lib="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 1 "$LIB_URL" -o "$tmp_lib"
    [[ -s "$tmp_lib" ]] || die "Downloaded library script is empty: $LIB_URL"
    bash -n "$tmp_lib"
    install -m 0644 "$tmp_lib" "$LIB_BIN"
    rm -f "$tmp_lib"

    tmp_cli="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 1 "$CLI_URL" -o "$tmp_cli"
    [[ -s "$tmp_cli" ]] || die "Downloaded CLI script is empty: $CLI_URL"
    bash -n "$tmp_cli"
    install -m 0755 "$tmp_cli" "$CLI_BIN"
    rm -f "$tmp_cli"
}

init_layout_and_permissions() {
    local step="$1"
    log "[${step}] Initializing layout and permissions..."

    install -d -m 0755 /etc/caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup /var/log/caddy
    touch /etc/caddy/caddyctl.conf
    chmod 644 /etc/caddy/caddyctl.conf

    if getent group caddy >/dev/null 2>&1; then
        chown root:caddy /etc/caddy /etc/caddy/caddyctl.conf || true
        chown -R root:caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup || true
        chown caddy:caddy /var/log/caddy || true
    fi

    chmod 755 /etc/caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup /var/log/caddy || true
    find /etc/caddy/sites.d -type f -name '*.conf' -exec chmod 644 {} + 2>/dev/null || true
    find /etc/caddy/globals.d -type f -name '*.inc' -exec chmod 644 {} + 2>/dev/null || true
}

enable_and_restart_service_debian() {
    log "[7/7] Enabling and restarting Caddy service..."
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl not found, skip service startup."
        return
    fi

    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy 2>/dev/null || log "(Warning) Caddy 启动失败，请手动检查配置"
}

enable_and_restart_service_alpine() {
    log "[4/4] Enabling and starting Caddy (OpenRC)..."
    if ! command -v rc-service >/dev/null 2>&1; then
        log "rc-service not found, skip service startup."
        return
    fi
    rc-update add caddy default 2>/dev/null || true
    rc-service caddy restart 2>/dev/null || log "(Warning) Caddy 启动失败，请手动检查配置"
}

# ── Main ─────────────────────────────────────────────────

install_debian() {
    require_command apt-get
    require_command curl

    log "Starting Caddy CLI installer (Debian/Ubuntu)..."
    install_deps_debian
    require_command gpg
    install_or_keep_caddy_debian
    install_cli "5/7"
    init_layout_and_permissions "6/7"
    enable_and_restart_service_debian

    echo
    log "Install complete."
    log "--------------------------------"
    log "Open panel: c"
    log "Run doctor: c doctor"
    log "Add site: c add example.com 8080"
    log "--------------------------------"
}

install_alpine() {
    require_command apk
    require_command curl

    log "Starting Caddy CLI installer (Alpine Linux)..."
    install_deps_alpine
    install_or_keep_caddy_alpine
    install_cli "3/4"
    init_layout_and_permissions "3/4"
    enable_and_restart_service_alpine

    echo
    log "Install complete."
    log "--------------------------------"
    log "Open panel: c"
    log "Run doctor: c doctor"
    log "Add site: c add example.com 8080"
    log "--------------------------------"
}

main() {
    require_root
    detect_distro

    case "$DISTRO" in
        debian) install_debian ;;
        alpine) install_alpine ;;
        *) die "Unsupported distribution. Currently supported: Debian/Ubuntu, Alpine Linux." ;;
    esac
}

main "$@"
