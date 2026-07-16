# caddyctl library module: 00-core.sh
# shellcheck shell=bash
# Globals below are shared across modules (sourced into the same shell).
# shellcheck disable=SC2034

CADDYFILE="/etc/caddy/Caddyfile"
SITES_DIR="/etc/caddy/sites.d"
GLOBALS_DIR="/etc/caddy/globals.d"
STATE_FILE="/etc/caddy/caddyctl.conf"
BACKUP_DIR="/etc/caddy/backup"
LAST_VALIDATE_LOG=""
ACCESS_LOG_DIR="/var/log/caddy"
DEFAULT_SYSTEMCTL_TIMEOUT="30"
MIN_SYSTEMCTL_TIMEOUT="1"
MAX_SYSTEMCTL_TIMEOUT="600"
DEFAULT_LOCK_WAIT_SECONDS="30"
LOCK_FILE_CANDIDATES=("/run/lock/caddyctl.lock" "/var/lock/caddyctl.lock" "/tmp/caddyctl.lock")
LOCK_FILE="/run/lock/caddyctl.lock"
LOCK_HELD=0
# shellcheck disable=SC2034 # reserved defaults for generated Caddy access-log roll policy
ACCESS_LOG_ROLL_SIZE="20MiB"
# shellcheck disable=SC2034 # reserved defaults for generated Caddy access-log roll policy
ACCESS_LOG_ROLL_KEEP="10"
# shellcheck disable=SC2034 # reserved defaults for generated Caddy access-log roll policy
ACCESS_LOG_ROLL_KEEP_FOR="720h"
DEFAULT_UPSTREAM_CHECK_MODE="warn"
SNAPSHOT_DIR="$BACKUP_DIR/snapshots"
MAX_SNAPSHOTS="30"
# DEFAULT_UPDATE_URL is set by the sourcing script (caddy.sh or caddy-cloudflare.sh)

# --- Extension hooks (override in variant scripts) ---
_hook_ensure_dirs() { :; }
_hook_fix_permissions() { :; }
_hook_menu_config_items() { :; }
_hook_menu_config_handler() { return 1; }
_hook_cli_command() { return 1; }
_hook_cmd_doctor() { :; }
_hook_help_extra() { :; }
_hook_list_extra() { :; }
_hook_render_global_options() { :; }
_hook_render_site_tls() { :; }
_hook_validate_args() { printf '%s' ''; }

say() {
    printf '%s\n' "$*"
}

fail() {
    printf '错误: %s\n' "$*" >&2
}

log_ok() {
    printf '%b\n' "$*"
}

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

validate_timeout_seconds() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( MIN_SYSTEMCTL_TIMEOUT <= 10#$1 && 10#$1 <= MAX_SYSTEMCTL_TIMEOUT ))
}

validate_upstream_check_mode() {
    case "$1" in
        warn|strict) return 0 ;;
        *) return 1 ;;
    esac
}

get_systemctl_timeout_seconds() {
    local candidate="${CADDYCTL_SYSTEMCTL_TIMEOUT:-${SYSTEMCTL_TIMEOUT_SECONDS:-$DEFAULT_SYSTEMCTL_TIMEOUT}}"
    if validate_timeout_seconds "$candidate"; then
        printf '%s' "$candidate"
    else
        printf '%s' "$DEFAULT_SYSTEMCTL_TIMEOUT"
    fi
}

get_upstream_check_mode() {
    local candidate="${CADDYCTL_UPSTREAM_CHECK_MODE:-${UPSTREAM_CHECK_MODE:-$DEFAULT_UPSTREAM_CHECK_MODE}}"
    if validate_upstream_check_mode "$candidate"; then
        printf '%s' "$candidate"
    else
        printf '%s' "$DEFAULT_UPSTREAM_CHECK_MODE"
    fi
}

get_lock_wait_seconds() {
    local candidate="${CADDYCTL_LOCK_WAIT_SECONDS:-$DEFAULT_LOCK_WAIT_SECONDS}"
    if validate_timeout_seconds "$candidate"; then
        printf '%s' "$candidate"
    else
        printf '%s' "$DEFAULT_LOCK_WAIT_SECONDS"
    fi
}

caddy_supports_envfile() {
    local version="$1"
    local major minor
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)$ ]] || return 1
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    (( 10#$major > 2 || (10#$major == 2 && 10#$minor >= 7) ))
}

strip_wrapping_quotes() {
    local value="$1"
    if (( ${#value} >= 2 )); then
        if [[ "${value:0:1}" == "\"" && "${value: -1}" == "\"" ]]; then
            value="${value:1:-1}"
        elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:-1}"
        fi
    fi
    printf '%s' "$value"
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        fail "请用 root 或 sudo 运行，例如: sudo c"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_is_caddyctl_library_file() {
    local src base
    src="$1"
    base="$(basename "$src")"
    [[ "$base" == "caddy-lib.sh" ]] && return 0
    # Modular library files: 00-core.sh ... 70-cmd-ops.sh
    [[ "$base" == [0-9][0-9]-*.sh ]] && return 0
    if [[ -n "${_CADDYCTL_LIBDIR:-}" ]]; then
        case "$src" in
            "$_CADDYCTL_LIBDIR"/*) return 0 ;;
        esac
    fi
    return 1
}

current_script_path() {
    local src base
    # Prefer the real frontend (caddy.sh / caddy-cloudflare / caddyctl), never a library module.
    for src in "${BASH_SOURCE[@]}"; do
        [[ -n "$src" && -f "$src" ]] || continue
        _is_caddyctl_library_file "$src" && continue
        printf '%s\n' "$src"
        return 0
    done
    if [[ -n "${0:-}" && -f "${0}" ]]; then
        base="$(basename "$0")"
        [[ "$base" == "bash" || "$base" == "sh" ]] && return 1
        _is_caddyctl_library_file "$0" && return 1
        printf '%s\n' "$0"
        return 0
    fi
    return 1
}

current_library_path() {
    # Set by caddy-lib.sh entry when sourced; reliable after modular split.
    if [[ -n "${_CADDYCTL_ENTRY:-}" && -f "$_CADDYCTL_ENTRY" ]]; then
        printf '%s\n' "$_CADDYCTL_ENTRY"
        return 0
    fi
    local src
    for src in "${BASH_SOURCE[@]}"; do
        [[ -n "$src" && -f "$src" ]] || continue
        [[ "$(basename "$src")" == "caddy-lib.sh" ]] || continue
        printf '%s\n' "$src"
        return 0
    done
    [[ -f /usr/local/bin/caddy-lib.sh ]] || return 1
    printf '%s\n' /usr/local/bin/caddy-lib.sh
}

caddy_binary() {
    local candidate src_dir svc_path

    if [[ -n "${CADDY_BIN:-}" ]]; then
        if [[ "$CADDY_BIN" == */* ]]; then
            [[ -x "$CADDY_BIN" ]] || return 1
            printf '%s\n' "$CADDY_BIN"
            return 0
        fi
        if command -v "$CADDY_BIN" >/dev/null 2>&1; then
            command -v "$CADDY_BIN"
            return 0
        fi
        return 1
    fi

    if command_exists caddy; then
        command -v caddy
        return 0
    fi

    if candidate="$(current_script_path 2>/dev/null)"; then
        src_dir="$(dirname "$(readlink -f "$candidate")")"
        if [[ -x "$src_dir/caddy" ]]; then
            printf '%s\n' "$src_dir/caddy"
            return 0
        fi
    fi

    if candidate="$(current_library_path 2>/dev/null)"; then
        src_dir="$(dirname "$(readlink -f "$candidate")")"
        if [[ -x "$src_dir/caddy" ]]; then
            printf '%s\n' "$src_dir/caddy"
            return 0
        fi
    fi

    if command_exists systemctl; then
        svc_path="$(systemctl show caddy.service -p ExecStart --value 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1 || true)"
        if [[ -n "$svc_path" && -x "$svc_path" ]]; then
            printf '%s\n' "$svc_path"
            return 0
        fi
    fi

    for candidate in /usr/local/bin/caddy /usr/bin/caddy /opt/ccconnect/caddy_cli/caddy; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

caddy_version_text() {
    local bin version
    bin="$(caddy_binary)" || {
        printf '%s\n' "unknown"
        return 1
    }
    version="$("$bin" version 2>/dev/null || true)"
    printf '%s\n' "${version:-unknown}"
}

require_command() {
    local cmd="$1"
    if [[ "$cmd" == "caddy" ]]; then
        caddy_binary >/dev/null 2>&1 || {
            fail "未安装 caddy（PATH、脚本目录和 caddy.service 均未找到可执行二进制）"
            exit 1
        }
        return 0
    fi
    command_exists "$cmd" || {
        fail "未安装 $cmd"
        exit 1
    }
}

cleanup_paths() {
    rm -rf -- "$@" 2>/dev/null || true
}

verify_download_checksum() {
    local file="$1"
    local name="$2"
    local checksums_url="$3"
    local sums expected actual

    if [[ "${CADDYCTL_SKIP_CHECKSUM:-0}" == "1" ]]; then
        say "(Warning) 跳过 SHA256 校验: $name"
        return 0
    fi

    require_command sha256sum
    sums="$(mktemp)"
    if ! curl -fsSL --retry 3 --retry-delay 1 "$checksums_url" -o "$sums"; then
        cleanup_paths "$sums"
        fail "无法下载校验文件: $checksums_url"
        return 1
    fi

    expected="$(awk -v name="$name" '$2 == name { print $1; exit }' "$sums")"
    cleanup_paths "$sums"
    if [[ -z "$expected" ]]; then
        fail "校验文件缺少条目: $name"
        return 1
    fi

    actual="$(sha256sum "$file" | awk '{ print $1 }')"
    if [[ "$actual" != "$expected" ]]; then
        fail "SHA256 校验失败: $name"
        return 1
    fi
}

backup_file_if_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local bak
        bak="$(mktemp "$BACKUP_DIR/site.XXXXXX")"
        cp -a "$file" "$bak"
        printf '%s\n' "$bak"
    fi
}

restore_file_from_backup() {
    local file="$1"
    local bak="${2:-}"

    if [[ -n "$bak" ]]; then
        cp -a "$bak" "$file"
        cleanup_paths "$bak"
    else
        rm -f "$file"
    fi
}

prompt_yes_no() {
    local prompt="$1"
    local answer=""
    [[ -t 0 ]] || return 1

    read -rp "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

prompt_yes_no_default_yes() {
    local prompt="$1"
    local answer=""
    [[ -t 0 ]] || return 0

    read -rp "$prompt [Y/n]: " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

prompt_tls_scheme() {
    if prompt_yes_no_default_yes "是否启用 TLS/HTTPS（自动申请证书）？"; then
        printf '%s' "https"
    else
        printf '%s' "http"
    fi
}

clear_managed_dir() {
    local dir="$1"
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
}

ensure_dirs() {
    mkdir -p "$SITES_DIR" "$GLOBALS_DIR" "$BACKUP_DIR" "$ACCESS_LOG_DIR"
    touch "$STATE_FILE"
    chmod 644 "$STATE_FILE" 2>/dev/null || true

    chown caddy:caddy "$ACCESS_LOG_DIR" 2>/dev/null || true
    chmod 755 "$ACCESS_LOG_DIR" 2>/dev/null || true

    find "$ACCESS_LOG_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$ACCESS_LOG_DIR" -type f -exec chown caddy:caddy {} + 2>/dev/null || true
    find "$ACCESS_LOG_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
    _hook_ensure_dirs
}

load_state() {
    EMAIL=""
    SYSTEMCTL_TIMEOUT_SECONDS="$DEFAULT_SYSTEMCTL_TIMEOUT"
    UPSTREAM_CHECK_MODE="$DEFAULT_UPSTREAM_CHECK_MODE"
    if [[ -f "$STATE_FILE" ]]; then
        local line key raw value
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="$(trim "$line")"
            [[ -n "$line" ]] || continue
            [[ "$line" != \#* ]] || continue
            [[ "$line" == *=* ]] || continue

            key="$(trim "${line%%=*}")"
            raw="$(trim "${line#*=}")"
            value="$(strip_wrapping_quotes "$raw")"

            case "$key" in
                EMAIL)
                    if validate_email "$value"; then
                        EMAIL="$value"
                    fi
                    ;;
                SYSTEMCTL_TIMEOUT_SECONDS)
                    if validate_timeout_seconds "$value"; then
                        SYSTEMCTL_TIMEOUT_SECONDS="$value"
                    fi
                    ;;
                UPSTREAM_CHECK_MODE)
                    if validate_upstream_check_mode "$value"; then
                        UPSTREAM_CHECK_MODE="$value"
                    fi
                    ;;
            esac
        done < "$STATE_FILE"
    fi
    if ! validate_timeout_seconds "$SYSTEMCTL_TIMEOUT_SECONDS"; then
        SYSTEMCTL_TIMEOUT_SECONDS="$DEFAULT_SYSTEMCTL_TIMEOUT"
    fi
    if ! validate_upstream_check_mode "$UPSTREAM_CHECK_MODE"; then
        UPSTREAM_CHECK_MODE="$DEFAULT_UPSTREAM_CHECK_MODE"
    fi
}

save_state() {
    # Persist only validated scalar settings. Validators reject characters that
    # would require shell-style escaping, keeping the state file simple and
    # load_state-compatible.
    validate_email "${EMAIL:-}" || EMAIL=""
    validate_timeout_seconds "${SYSTEMCTL_TIMEOUT_SECONDS:-}" || SYSTEMCTL_TIMEOUT_SECONDS="$DEFAULT_SYSTEMCTL_TIMEOUT"
    validate_upstream_check_mode "${UPSTREAM_CHECK_MODE:-}" || UPSTREAM_CHECK_MODE="$DEFAULT_UPSTREAM_CHECK_MODE"
    cat > "$STATE_FILE" <<EOF
EMAIL="${EMAIL:-}"
SYSTEMCTL_TIMEOUT_SECONDS="${SYSTEMCTL_TIMEOUT_SECONDS:-$DEFAULT_SYSTEMCTL_TIMEOUT}"
UPSTREAM_CHECK_MODE="${UPSTREAM_CHECK_MODE:-$DEFAULT_UPSTREAM_CHECK_MODE}"
EOF
    chmod 644 "$STATE_FILE" 2>/dev/null || true
}

fix_permissions() {
    chown root:caddy /etc/caddy 2>/dev/null || true
    chmod 755 /etc/caddy 2>/dev/null || true

    if [[ -f "$CADDYFILE" ]]; then
        chown root:caddy "$CADDYFILE" 2>/dev/null || true
        chmod 644 "$CADDYFILE" 2>/dev/null || true
    fi

    chown -R root:caddy "$SITES_DIR" 2>/dev/null || true
    chmod 755 "$SITES_DIR" 2>/dev/null || true
    find "$SITES_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$SITES_DIR" -type f -name '*.conf' -exec chmod 644 {} + 2>/dev/null || true
    find "$SITES_DIR" -type f -name '*.conf.disabled' -exec chmod 644 {} + 2>/dev/null || true

    chown -R root:caddy "$GLOBALS_DIR" 2>/dev/null || true
    chmod 755 "$GLOBALS_DIR" 2>/dev/null || true
    find "$GLOBALS_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$GLOBALS_DIR" -type f -name '*.inc' -exec chmod 644 {} + 2>/dev/null || true

    chown root:caddy "$STATE_FILE" 2>/dev/null || true
    chmod 644 "$STATE_FILE" 2>/dev/null || true

    if [[ -d "$ACCESS_LOG_DIR" ]]; then
        chown -R caddy:caddy "$ACCESS_LOG_DIR" 2>/dev/null || true
        chmod 755 "$ACCESS_LOG_DIR" 2>/dev/null || true
        find "$ACCESS_LOG_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$ACCESS_LOG_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
    fi
    _hook_fix_permissions
}
