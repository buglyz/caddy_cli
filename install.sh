#!/usr/bin/env bash
set -euo pipefail

readonly CADDY_CLI_REF="${CADDY_CLI_REF:-v2.11.3-cloudflare-r10}"
readonly CADDY_CLI_BASE_URL="${CADDY_CLI_BASE_URL:-https://raw.githubusercontent.com/buglyz/caddy_cli/${CADDY_CLI_REF}}"
readonly CLI_URL="${CADDY_CLI_URL:-${CADDY_CLI_BASE_URL}/caddy.sh}"
readonly LIB_URL="${CADDY_LIB_URL:-${CADDY_CLI_BASE_URL}/caddy-lib.sh}"
readonly CHECKSUMS_URL="${CADDY_CHECKSUMS_URL:-${CADDY_CLI_BASE_URL}/checksums.txt}"
readonly CLI_BIN="/usr/local/bin/caddyctl"
readonly CLI_ALIAS="/usr/local/bin/c"
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
    printf '%s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code="$?"
    local line_no="${1:-unknown}"
    printf 'Error: install failed (exit=%s, line=%s)\n' "$exit_code" "$line_no" >&2
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

# Portable download: prefers curl, falls back to wget (BusyBox compatible)
safe_download() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 120 "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 120 -O "$output" "$url"
    else
        die "Neither curl nor wget available; install one to continue"
    fi
}

verify_checksum() {
    local file="$1"
    local name="$2"
    local sums expected actual

    if [[ "${CADDYCTL_SKIP_CHECKSUM:-0}" == "1" ]]; then
        log "(Warning) Skipping checksum verification for $name"
        return 0
    fi

    require_command sha256sum
    sums="$(mktemp)"
    safe_download "$CHECKSUMS_URL" "$sums" || {
        rm -f "$sums"
        die "Failed to download checksums: $CHECKSUMS_URL"
    }

    expected="$(awk -v name="$name" '$2 == name { print $1; exit }' "$sums")"
    rm -f "$sums"
    [[ -n "$expected" ]] || die "Checksum entry not found for $name"

    actual="$(sha256sum "$file" | awk '{ print $1 }')"
    [[ "$actual" == "$expected" ]] || die "Checksum mismatch for $name"
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
    apk add --no-cache bash ca-certificates curl gnupg python3
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

    local tmp_lib tmp_cli lib_mod_dir
    local -a modules=(
        00-core.sh
        10-validate.sh
        20-config.sh
        30-service.sh
        40-lock-snapshot.sh
        50-sites.sh
        60-cmd-sites.sh
        70-cmd-ops.sh
    )
    local -a tmp_mods=()
    local mod tmp_mod
    tmp_lib=""
    tmp_cli=""
    lib_mod_dir="/usr/local/lib/caddyctl"
    trap 'rm -f "$tmp_lib" "$tmp_cli" "${tmp_mods[@]}"' RETURN

    tmp_lib="$(mktemp)"
    safe_download "$LIB_URL" "$tmp_lib"
    [[ -s "$tmp_lib" ]] || die "Downloaded library script is empty: $LIB_URL"
    verify_checksum "$tmp_lib" "caddy-lib.sh"
    bash -n "$tmp_lib"

    for mod in "${modules[@]}"; do
        tmp_mod="$(mktemp)"
        tmp_mods+=("$tmp_mod")
        safe_download "${CADDY_CLI_BASE_URL}/lib/${mod}" "$tmp_mod"
        [[ -s "$tmp_mod" ]] || die "Downloaded module is empty: $mod"
        verify_checksum "$tmp_mod" "lib/${mod}"
        bash -n "$tmp_mod"
    done

    tmp_cli="$(mktemp)"
    safe_download "$CLI_URL" "$tmp_cli"
    [[ -s "$tmp_cli" ]] || die "Downloaded CLI script is empty: $CLI_URL"
    verify_checksum "$tmp_cli" "caddy.sh"
    bash -n "$tmp_cli"

    install -d -m 0755 "$lib_mod_dir"
    install -m 0644 "$tmp_lib" "$LIB_BIN"
    local i=0
    for mod in "${modules[@]}"; do
        install -m 0644 "${tmp_mods[$i]}" "$lib_mod_dir/$mod"
        i=$((i + 1))
    done
    install -m 0755 "$tmp_cli" "$CLI_BIN"
    ln -sf "$CLI_BIN" "$CLI_ALIAS"
    rm -f "$tmp_lib" "$tmp_cli" "${tmp_mods[@]}"
    trap - RETURN
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
    log "[5/5] Enabling and starting Caddy (OpenRC)..."
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

    log "Starting Caddy CLI installer (Alpine Linux)..."
    install_deps_alpine
    install_or_keep_caddy_alpine
    install_cli "3/5"
    init_layout_and_permissions "4/5"
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
