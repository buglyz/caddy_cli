#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="${CADDYCTL_GO_REPOSITORY:-buglyz/caddy_cli}"
readonly VERSION="${CADDYCTL_GO_VERSION:-latest}"
readonly BIN_DIR="${CADDYCTL_GO_BIN_DIR:-/usr/local/bin}"
readonly CLI_BIN="${BIN_DIR}/caddyctl"
readonly CLI_ALIAS="${BIN_DIR}/c"
readonly BACKUP_BIN="${CLI_BIN}.bak"
readonly CF_MARKER="${CADDYCTL_GO_CF_MARKER:-/etc/caddy/.caddyctl-cloudflare}"

CLOUDFLARE=0
TEMP_DIR=""

cleanup() {
    if [[ -n "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: sudo bash install-go.sh [--cloudflare]

Prerequisite:
  Install Caddy first. --cloudflare requires dns.providers.cloudflare.

Environment:
  CADDYCTL_GO_VERSION           Release tag, or latest (default)
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
    if [[ -n "${CADDYCTL_GO_RELEASE_BASE_URL:-}" ]]; then
        printf '%s' "${CADDYCTL_GO_RELEASE_BASE_URL%/}"
        return 0
    fi
    if [[ "$VERSION" == "latest" ]]; then
        printf 'https://github.com/%s/releases/latest/download' "$REPOSITORY"
    else
        [[ "$VERSION" != */* && "$VERSION" != *$'\r'* && "$VERSION" != *$'\n'* ]] \
            || die "invalid release tag"
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

check_environment() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        if [[ "$BIN_DIR" == "/usr/local/bin" || "$CF_MARKER" == /etc/* ]]; then
            die "please run as root or sudo"
        fi
    fi
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
    command -v caddy >/dev/null 2>&1 || die "Caddy is required; install it before caddyctl"
    if (( CLOUDFLARE == 1 )); then
        caddy list-modules 2>/dev/null | grep -Fxq 'dns.providers.cloudflare' \
            || die "Caddy does not include dns.providers.cloudflare"
    fi
    if [[ -e "$CLI_BIN" && ! -f "$CLI_BIN" && ! -L "$CLI_BIN" ]]; then
        die "install target is not a file: $CLI_BIN"
    fi
}

backup_current_binary() {
    if [[ ! -e "$CLI_BIN" ]]; then
        return 0
    fi
    cp -L -- "$CLI_BIN" "${BACKUP_BIN}.new"
    chmod 0755 "${BACKUP_BIN}.new"
    mv -f "${BACKUP_BIN}.new" "$BACKUP_BIN"
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            --cloudflare) CLOUDFLARE=1 ;;
            -h|--help) usage; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    check_environment

    local arch asset base binary sums
    arch="$(asset_arch)"
    asset="caddyctl-linux-${arch}"
    base="$(release_base_url)"
    TEMP_DIR="$(mktemp -d)"
    binary="$TEMP_DIR/$asset"
    sums="$TEMP_DIR/caddyctl-checksums.txt"

    download "$base/$asset" "$binary"
    download "$base/caddyctl-checksums.txt" "$sums"
    verify_asset "$binary" "$sums" "$asset"
    chmod 0755 "$binary"
    "$binary" --help >/dev/null

    install -d -m 0755 "$BIN_DIR"
    backup_current_binary
    install -m 0755 "$binary" "${CLI_BIN}.new"
    mv -f "${CLI_BIN}.new" "$CLI_BIN"
    ln -sfn "$CLI_BIN" "$CLI_ALIAS"

    if (( CLOUDFLARE == 1 )); then
        install -d -m 0755 "$(dirname "$CF_MARKER")"
        : > "$CF_MARKER"
        chmod 0644 "$CF_MARKER"
    else
        rm -f "$CF_MARKER"
    fi

    printf 'Installed Go CLI: %s\n' "$CLI_BIN"
    if [[ -f "$BACKUP_BIN" ]]; then
        printf 'Previous binary: %s\n' "$BACKUP_BIN"
        printf 'Rollback: install -m 0755 %s %s\n' "$BACKUP_BIN" "$CLI_BIN"
    fi
}

main "$@"
