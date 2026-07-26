#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="${CADDYCTL_GO_REPOSITORY:-buglyz/caddy_cli}"
readonly VERSION="${CADDYCTL_GO_VERSION:-latest}"
readonly BIN_DIR="${CADDYCTL_GO_BIN_DIR:-/usr/local/bin}"
readonly LEGACY_BIN="${BIN_DIR}/caddyctl-legacy"
readonly GO_BIN="${BIN_DIR}/caddyctl-go"
readonly CLI_BIN="${BIN_DIR}/caddyctl"
readonly CLI_ALIAS="${BIN_DIR}/c"
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

Environment:
  CADDYCTL_GO_VERSION     Release tag, or latest (default)
  CADDYCTL_GO_REPOSITORY  GitHub owner/repository
  CADDYCTL_GO_BIN_DIR     Install directory (default /usr/local/bin)
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
        printf 'https://github.com/%s/releases/download/%s' "$REPOSITORY" "$VERSION"
    fi
}

verify_asset() {
    local binary="$1"
    local sums="$2"
    local name="$3"
    local expected actual
    expected="$(awk -v name="$name" '$2 == name { print $1; exit }' "$sums")"
    [[ -n "$expected" ]] || die "checksum entry missing: $name"
    actual="$(sha256sum "$binary" | awk '{ print $1 }')"
    [[ "$actual" == "$expected" ]] || die "checksum mismatch: $name"
}

preserve_legacy() {
    if [[ -e "$LEGACY_BIN" ]]; then
        return 0
    fi
    if [[ -f "$CLI_BIN" && ! -L "$CLI_BIN" ]]; then
        if head -n 1 "$CLI_BIN" | grep -q '^#!.*\(ba\)\?sh'; then
            install -m 0755 "$CLI_BIN" "$LEGACY_BIN"
        fi
    fi
    [[ -x "$LEGACY_BIN" ]] || die "legacy CLI not found; run the regular installer first"
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

    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "please run as root or sudo"
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

    local arch asset base tmpdir binary sums
    arch="$(asset_arch)"
    asset="caddyctl-linux-${arch}"
    base="$(release_base_url)"
    tmpdir="$(mktemp -d)"
    TEMP_DIR="$tmpdir"
    binary="$tmpdir/$asset"
    sums="$tmpdir/caddyctl-checksums.txt"

    download "$base/$asset" "$binary"
    download "$base/caddyctl-checksums.txt" "$sums"
    verify_asset "$binary" "$sums" "$asset"
    chmod 0755 "$binary"
    "$binary" --help >/dev/null

    preserve_legacy
    install -d -m 0755 "$BIN_DIR"
    install -m 0755 "$binary" "${GO_BIN}.new"
    mv -f "${GO_BIN}.new" "$GO_BIN"

    if (( CLOUDFLARE == 1 )); then
        install -d -m 0755 "$(dirname "$CF_MARKER")"
        : > "$CF_MARKER"
        chmod 0644 "$CF_MARKER"
    else
        rm -f "$CF_MARKER"
    fi

    ln -sfn "$GO_BIN" "$CLI_BIN"
    ln -sfn "$CLI_BIN" "$CLI_ALIAS"
    printf 'Installed Go CLI: %s\n' "$GO_BIN"
    printf 'Legacy fallback: %s\n' "$LEGACY_BIN"
    printf 'Rollback: ln -sfn %s %s\n' "$LEGACY_BIN" "$CLI_BIN"
}

main "$@"
