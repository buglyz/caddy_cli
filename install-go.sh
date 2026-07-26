#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="${CADDYCTL_GO_REPOSITORY:-buglyz/caddy_cli}"
readonly VERSION="${CADDYCTL_GO_VERSION:-latest}"
readonly BIN_DIR="${CADDYCTL_GO_BIN_DIR:-/usr/local/bin}"
readonly CLI_BIN="${BIN_DIR}/caddyctl"
readonly CLI_ALIAS="${BIN_DIR}/c"
readonly BACKUP_BIN="${CLI_BIN}.bak"
readonly CF_MARKER="${CADDYCTL_GO_CF_MARKER:-/etc/caddy/.caddyctl-cloudflare}"
readonly CONFIG_DIR="${CADDYCTL_GO_CONFIG_DIR:-$(dirname "$CF_MARKER")}"
readonly LOG_DIR="${CADDYCTL_GO_LOG_DIR:-/var/log/caddy}"
readonly SYSTEMD_DROPIN_DIR="${CADDYCTL_GO_SYSTEMD_DROPIN_DIR:-/etc/systemd/system/caddy.service.d}"
readonly OPENRC_CONF="${CADDYCTL_GO_OPENRC_CONF:-/etc/conf.d/caddy}"
readonly CF_MODULE="${CADDYCTL_GO_CLOUDFLARE_MODULE:-github.com/caddy-dns/cloudflare}"
readonly CADDY_GPG_KEY_URL="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
readonly CADDY_APT_LIST_URL="https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"

CLOUDFLARE=0
CADDY_CHANGED=0
CADDY_INSTALLED=0
PREEXISTING_CONFIG=0
DISTRO=""
TEMP_DIR=""

cleanup() {
    if [[ -n "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: sudo bash install-go.sh [--cloudflare]

Installs:
  1. Caddy from its official Debian/Ubuntu repository or Alpine community.
  2. The verified pre-built caddyctl binary for linux/amd64 or linux/arm64.
  3. The c alias, managed directories, and service integration.

Options:
  --cloudflare  Add github.com/caddy-dns/cloudflare to Caddy.

Environment:
  CADDYCTL_GO_VERSION           Release tag, go-latest, or latest (default)
  CADDYCTL_GO_REPOSITORY        GitHub owner/repository
  CADDYCTL_GO_RELEASE_BASE_URL  Override release asset base URL (testing)
  CADDYCTL_GO_BIN_DIR           Install directory (default /usr/local/bin)
EOF
}

download() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 120 \
            "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 120 -O "$output" "$url"
    else
        die "curl or wget is required"
    fi
}

asset_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s' amd64 ;;
        aarch64|arm64) printf '%s' arm64 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

release_base_url() {
    [[ "$VERSION" != "." && "$VERSION" != ".." \
        && "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] \
        || die "invalid release tag"
    if [[ -n "${CADDYCTL_GO_RELEASE_BASE_URL:-}" ]]; then
        printf '%s' "${CADDYCTL_GO_RELEASE_BASE_URL%/}"
        return 0
    fi
    [[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || die "invalid GitHub repository"
    local owner="${REPOSITORY%%/*}"
    local name="${REPOSITORY#*/}"
    [[ "$owner" != "." && "$owner" != ".." && "$name" != "." && "$name" != ".." ]] \
        || die "invalid GitHub repository"
    if [[ "$VERSION" == "latest" ]]; then
        printf 'https://github.com/%s/releases/latest/download' "$REPOSITORY"
    else
        printf 'https://github.com/%s/releases/download/%s' "$REPOSITORY" "$VERSION"
    fi
}

verify_asset() {
    local binary="$1"
    local sums="$2"
    local name="$3"
    local expected actual
    expected="$(awk -v name="$name" '$2 == name { print $1; exit }' "$sums")"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "checksum entry missing or invalid: $name"
    actual="$(sha256sum "$binary" | awk '{ print $1 }')"
    [[ "$actual" == "$expected" ]] || die "checksum mismatch: $name"
}

path_requires_root() {
    case "$1" in
        /etc|/etc/*|/usr|/usr/*|/var|/var/*) return 0 ;;
        *) return 1 ;;
    esac
}

check_environment() {
    command -v awk >/dev/null 2>&1 || die "awk is required"
    command -v install >/dev/null 2>&1 || die "install is required"
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        if ! command -v caddy >/dev/null 2>&1 \
            || path_requires_root "$BIN_DIR" \
            || path_requires_root "$CONFIG_DIR" \
            || path_requires_root "$LOG_DIR" \
            || (( CLOUDFLARE == 1 )); then
            die "please run as root or sudo"
        fi
    fi
    if [[ -e "$CLI_BIN" && ! -f "$CLI_BIN" && ! -L "$CLI_BIN" ]]; then
        die "install target is not a file: $CLI_BIN"
    fi
    if [[ -e "$CLI_ALIAS" && ! -f "$CLI_ALIAS" && ! -L "$CLI_ALIAS" ]]; then
        die "CLI alias target is not a file: $CLI_ALIAS"
    fi
}

detect_distro() {
    if [[ -f /etc/alpine-release ]]; then
        DISTRO="alpine"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
    else
        die "unsupported distribution; use Debian, Ubuntu, or Alpine Linux"
    fi
}

backup_existing_config() {
    local backup_dir stamp
    [[ -d "$CONFIG_DIR" ]] || return 0
    [[ -e "$CONFIG_DIR/Caddyfile" || -e "$CONFIG_DIR/sites.d" \
        || -e "$CONFIG_DIR/globals.d" || -e "$CONFIG_DIR/caddyctl.conf" ]] || return 0
    PREEXISTING_CONFIG=1
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$CONFIG_DIR/backup/pre-install-$stamp"
    install -d -m 0700 "$backup_dir"
    for name in Caddyfile sites.d globals.d caddyctl.conf cloudflare.env; do
        if [[ -e "$CONFIG_DIR/$name" ]]; then
            cp -a -- "$CONFIG_DIR/$name" "$backup_dir/$name"
        fi
    done
    log "Existing Caddy configuration backed up to $backup_dir"
}

install_caddy_debian() {
    local armored_key keyring repo_list
    log "Installing Caddy from the official Debian/Ubuntu repository..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg debian-keyring debian-archive-keyring
    armored_key="$TEMP_DIR/caddy-stable.asc"
    keyring="$TEMP_DIR/caddy-stable.gpg"
    repo_list="$TEMP_DIR/caddy-stable.list"
    download "$CADDY_GPG_KEY_URL" "$armored_key"
    gpg --batch --yes --dearmor -o "$keyring" "$armored_key"
    download "$CADDY_APT_LIST_URL" "$repo_list"
    install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
    install -m 0644 "$keyring" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    install -m 0644 "$repo_list" /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y --no-install-recommends caddy
}

enable_alpine_community() {
    local main_repo
    if grep -Eq '/community/?$' /etc/apk/repositories; then
        return 0
    fi
    main_repo="$(grep -E '/main/?$' /etc/apk/repositories | head -n 1 || true)"
    [[ -n "$main_repo" ]] || die "cannot determine Alpine community repository"
    printf '%s/community\n' "${main_repo%/main}" >> /etc/apk/repositories
}

install_caddy_alpine() {
    log "Installing Caddy from the Alpine community repository..."
    enable_alpine_community
    apk update
    apk add --no-cache bash ca-certificates curl caddy
}

install_caddy_if_needed() {
    if command -v caddy >/dev/null 2>&1; then
        log "Keeping existing Caddy: $(caddy version 2>/dev/null || printf unknown)"
        return 0
    fi
    backup_existing_config
    case "$DISTRO" in
        debian) install_caddy_debian ;;
        alpine) install_caddy_alpine ;;
    esac
    command -v caddy >/dev/null 2>&1 || die "Caddy installation did not provide a caddy command"
    CADDY_CHANGED=1
    CADDY_INSTALLED=1
    log "Caddy installed: $(caddy version)"
}

configure_cloudflare() {
    if (( CLOUDFLARE == 0 )); then
        return 0
    fi
    if ! caddy list-modules 2>/dev/null | grep -Fxq dns.providers.cloudflare; then
        log "Adding the Cloudflare DNS module to Caddy..."
        caddy add-package --keep-backup "$CF_MODULE"
        CADDY_CHANGED=1
    fi
    caddy list-modules 2>/dev/null | grep -Fxq dns.providers.cloudflare \
        || die "Caddy does not include dns.providers.cloudflare"
    install -d -m 0755 "$CONFIG_DIR"
    : > "$CF_MARKER"
    chmod 0644 "$CF_MARKER"
}

prepare_layout() {
    install -d -m 0755 \
        "$CONFIG_DIR" "$CONFIG_DIR/sites.d" "$CONFIG_DIR/globals.d" \
        "$CONFIG_DIR/backup" "$CONFIG_DIR/backup/snapshots" "$LOG_DIR"
    if [[ ! -e "$CONFIG_DIR/caddyctl.conf" ]]; then
        install -m 0644 /dev/null "$CONFIG_DIR/caddyctl.conf"
    fi
    if command -v getent >/dev/null 2>&1 && getent group caddy >/dev/null 2>&1; then
        chown root:caddy "$CONFIG_DIR" "$CONFIG_DIR/caddyctl.conf" 2>/dev/null || true
        chown -R root:caddy "$CONFIG_DIR/sites.d" "$CONFIG_DIR/globals.d" \
            "$CONFIG_DIR/backup" 2>/dev/null || true
        chown caddy:caddy "$LOG_DIR" 2>/dev/null || true
    fi
}

configure_service_environment() {
    (( CLOUDFLARE == 1 )) || return 0
    if [[ "$DISTRO" == "debian" ]]; then
        install -d -m 0755 "$SYSTEMD_DROPIN_DIR"
        printf '[Service]\nEnvironmentFile=-%s/cloudflare.env\n' "$CONFIG_DIR" \
            > "$SYSTEMD_DROPIN_DIR/10-cloudflare-env.conf"
        chmod 0644 "$SYSTEMD_DROPIN_DIR/10-cloudflare-env.conf"
    elif [[ "$DISTRO" == "alpine" ]]; then
        install -d -m 0755 "$(dirname "$OPENRC_CONF")"
        cat > "$OPENRC_CONF" <<EOF
# Managed by caddyctl
set -a
if [ -f "$CONFIG_DIR/cloudflare.env" ]; then
    . "$CONFIG_DIR/cloudflare.env"
fi
set +a
EOF
        chmod 0644 "$OPENRC_CONF"
    fi
}

restart_caddy_if_changed() {
    (( CADDY_CHANGED == 1 )) || return 0
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable caddy >/dev/null 2>&1 || true
        systemctl restart caddy >/dev/null 2>&1 \
            || log "Warning: Caddy is installed but systemd could not start it."
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add caddy default >/dev/null 2>&1 || true
        rc-service caddy restart >/dev/null 2>&1 \
            || log "Warning: Caddy is installed but OpenRC could not start it."
    fi
}

backup_current_binary() {
    [[ -e "$CLI_BIN" ]] || return 0
    cp -L -- "$CLI_BIN" "${BACKUP_BIN}.new"
    chmod 0755 "${BACKUP_BIN}.new"
    mv -f "${BACKUP_BIN}.new" "$BACKUP_BIN"
}

install_cli() {
    local binary="$1"
    install -d -m 0755 "$BIN_DIR"
    backup_current_binary
    install -m 0755 "$binary" "${CLI_BIN}.new"
    mv -f "${CLI_BIN}.new" "$CLI_BIN"
    ln -sfn "$CLI_BIN" "$CLI_ALIAS"
}

initialize_fresh_config() {
    local managed
    (( CADDY_INSTALLED == 1 && PREEXISTING_CONFIG == 0 )) || return 0
    managed="$TEMP_DIR/Caddyfile"
    printf '# managed by caddyctl\n\n' > "$managed"
    caddy validate --config "$managed" --adapter caddyfile >/dev/null 2>&1
    install -m 0644 "$managed" "$CONFIG_DIR/Caddyfile"
    if command -v getent >/dev/null 2>&1 && getent group caddy >/dev/null 2>&1; then
        chown root:caddy "$CONFIG_DIR/Caddyfile" 2>/dev/null || true
    fi
    log "Initialized a clean caddyctl-managed Caddyfile."
}

main() {
    local arch asset base binary sums
    while (( $# > 0 )); do
        case "$1" in
            --cloudflare) CLOUDFLARE=1 ;;
            -h|--help) usage; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    check_environment
    TEMP_DIR="$(mktemp -d)"
    detect_distro

    arch="$(asset_arch)"
    asset="caddyctl-linux-${arch}"
    base="$(release_base_url)"
    binary="$TEMP_DIR/$asset"
    sums="$TEMP_DIR/caddyctl-checksums.txt"

    log "Downloading the pre-built caddyctl ${VERSION} binary..."
    download "$base/$asset" "$binary"
    download "$base/caddyctl-checksums.txt" "$sums"
    verify_asset "$binary" "$sums" "$asset"
    chmod 0755 "$binary"
    "$binary" --help >/dev/null

    install_caddy_if_needed
    prepare_layout
    configure_cloudflare
    configure_service_environment

    install_cli "$binary"
    initialize_fresh_config
    restart_caddy_if_changed

    log "Installed Caddy: $(caddy version)"
    log "Installed Go CLI: $CLI_BIN ($("$CLI_BIN" version))"
    if [[ -f "$BACKUP_BIN" ]]; then
        log "Previous CLI binary: $BACKUP_BIN"
    fi
    log "Run 'c doctor' to verify the installation."
}

main "$@"
