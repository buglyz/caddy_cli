#!/usr/bin/env bash
set -euo pipefail

readonly CADDY_GPG_KEY_URL="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
readonly CADDY_APT_LIST_URL="https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"
readonly CLI_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy.sh"
readonly LIB_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy-lib.sh"
readonly CLI_BIN="/usr/local/bin/c"
readonly LIB_BIN="/usr/local/bin/caddy-lib.sh"

apt_index_updated=0

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

apt_update_once() {
    if (( apt_index_updated == 0 )); then
        log "[1/7] Updating apt index..."
        apt-get update
        apt_index_updated=1
    fi
}

install_dependencies() {
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

install_or_keep_caddy() {
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

install_cli() {
    log "[5/7] Installing c command..."
    local tmp_lib tmp_cli

    # Download and install shared library
    tmp_lib="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 1 "$LIB_URL" -o "$tmp_lib"
    [[ -s "$tmp_lib" ]] || die "Downloaded library script is empty: $LIB_URL"
    bash -n "$tmp_lib"
    install -m 0644 "$tmp_lib" "$LIB_BIN"
    rm -f "$tmp_lib"

    # Download and install CLI frontend
    tmp_cli="$(mktemp)"
    curl -fsSL --retry 3 --retry-delay 1 "$CLI_URL" -o "$tmp_cli"
    [[ -s "$tmp_cli" ]] || die "Downloaded CLI script is empty: $CLI_URL"
    bash -n "$tmp_cli"
    install -m 0755 "$tmp_cli" "$CLI_BIN"
    rm -f "$tmp_cli"
}

init_layout_and_permissions() {
    log "[6/7] Initializing layout and permissions..."

    install -d -m 0755 /etc/caddy /etc/caddy/sites.d /etc/caddy/globals.d /etc/caddy/backup /var/log/caddy
    touch /etc/caddy/caddyctl.conf
    chmod 644 /etc/caddy/caddyctl.conf

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
    log "[7/7] Enabling and restarting Caddy service..."
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl not found, skip service startup."
        return
    fi

    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy
}

main() {
    require_root
    require_command apt-get
    require_command curl
    require_command gpg
    require_command bash

    log "Starting Caddy CLI installer..."
    install_dependencies
    install_or_keep_caddy
    install_cli
    init_layout_and_permissions
    enable_and_restart_service

    echo
    log "Install complete."
    log "--------------------------------"
    log "Open panel: c"
    log "Run doctor: c doctor"
    log "Add site: c add example.com 8080"
    log "--------------------------------"
}

main "$@"
