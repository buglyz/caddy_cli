#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    printf '%s\n' "错误: 需要 Bash 4.0+，当前: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

# Clean up on exit
trap 'cleanup_paths "${LAST_VALIDATE_LOG:-}"' EXIT

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

current_script_path() {
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        echo "${BASH_SOURCE[0]}"
    elif [[ -n "${0:-}" && -f "${0}" ]]; then
        echo "${0}"
    else
        return 1
    fi
}

require_command() {
    local cmd="$1"
    command_exists "$cmd" || {
        fail "未安装 $cmd"
        exit 1
    }
}

cleanup_paths() {
    rm -rf -- "$@" 2>/dev/null || true
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

sanitize_name() {
    printf '%s\n' "$1" | tr '/: ,' '____' | tr -cd 'A-Za-z0-9._-'
}

is_site_enabled() {
    local file="$1"
    [[ "$file" == *.conf ]]
}

site_file_status() {
    local file="$1"
    if is_site_enabled "$file"; then
        echo "启用"
    else
        echo "禁用"
    fi
}

validate_site_label() {
    local label="$1"
    local part
    label="$(trim "$label")"
    [[ -n "$label" ]] || return 1
    [[ "$label" != *"{"* ]] || return 1
    [[ "$label" != *"}"* ]] || return 1
    [[ "$label" != *$'\r'* ]] || return 1
    [[ "$label" != *$'\n'* ]] || return 1

    IFS=',' read -ra parts <<< "$label"
    for part in "${parts[@]}"; do
        [[ -n "$(trim "$part")" ]] || return 1
    done
    return 0
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

validate_email() {
    [[ -z "$1" ]] && return 0 # 允许空值用于清除 email
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$1" == *.* ]]
}

validate_static_dir() {
    local dir="$1"
    [[ -n "$dir" ]] || return 1
    [[ "$dir" != *$'\r'* ]] || return 1
    [[ "$dir" != *$'\n'* ]] || return 1
    return 0
}

validate_path_prefix() {
    local prefix="$1"
    [[ -n "$prefix" ]] || return 1
    [[ "$prefix" == /* ]] || return 1
    [[ "$prefix" != "/" ]] || return 1
    [[ "$prefix" != *" "* ]] || return 1
    [[ "$prefix" != *$'\r'* ]] || return 1
    [[ "$prefix" != *$'\n'* ]] || return 1
    return 0
}

normalize_path_prefix() {
    local prefix
    prefix="$(trim "$1")"
    prefix="${prefix%\*}"
    prefix="${prefix%/}"
    [[ -n "$prefix" ]] || prefix="/"
    printf '%s' "$prefix"
}

has_any_config() {
    if [[ -n "${EMAIL:-}" ]]; then
        return 0
    fi
    compgen -G "$SITES_DIR/*.conf" >/dev/null 2>&1 && return 0
    compgen -G "$GLOBALS_DIR/*.inc" >/dev/null 2>&1 && return 0
    return 1
}

render_caddyfile_to() {
    local target="$1"

    {
        echo "# managed by caddyctl"
        echo

        local have_global=0
        local hook_global
        hook_global="$(_hook_render_global_options)"
        if [[ -n "${EMAIL:-}" ]]; then
            have_global=1
        fi
        if compgen -G "$GLOBALS_DIR/*.inc" >/dev/null 2>&1; then
            have_global=1
        fi
        if [[ -n "$hook_global" ]]; then
            have_global=1
        fi

        if (( have_global )); then
            echo "{"
            if [[ -n "${EMAIL:-}" ]]; then
                echo "    email ${EMAIL}"
            fi
            if [[ -n "$hook_global" ]]; then
                echo "$hook_global"
            fi

            shopt -s nullglob
            local gfiles=("$GLOBALS_DIR"/*.inc)
            for f in "${gfiles[@]}"; do
                [[ -s "$f" ]] || continue
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ -n "${line//[[:space:]]/}" ]]; then
                        echo "    $line"
                    else
                        echo
                    fi
                done < "$f"
            done
            shopt -u nullglob

            echo "}"
            echo
        fi

        shopt -s nullglob
        local sfiles=("$SITES_DIR"/*.conf)
        for f in "${sfiles[@]}"; do
            [[ -s "$f" ]] || continue
            cat "$f"
            echo
        done
        shopt -u nullglob
    } > "$target"
}

validate_config_file() {
    local config_path="$1"
    if [[ -n "${LAST_VALIDATE_LOG:-}" ]]; then
        cleanup_paths "$LAST_VALIDATE_LOG"
    fi
    LAST_VALIDATE_LOG="$(mktemp /tmp/caddyctl-validate.XXXXXX)"
    local _validate_extra_args
    _validate_extra_args="$(_hook_validate_args)"
    # Caddy < 2.7 doesn't support --envfile; source env inline
    local _caddy_ver
    _caddy_ver="$(caddy version 2>/dev/null | sed -n 's/^v\?\([0-9]\{1,\}\)\.\([0-9]\{1,\}\).*/\1.\2/p' | head -1 || true)"
    if [[ -n "$_caddy_ver" ]] && caddy_supports_envfile "$_caddy_ver"; then
        :
    else
        if [[ "$_validate_extra_args" == *--envfile* ]]; then
            local _envf
            _envf="$(echo "$_validate_extra_args" | sed -n 's/.*--envfile *\([^ ]*\).*/\1/p')"
            if [[ -f "$_envf" ]]; then
                set -a
                # shellcheck disable=SC1090 # env file path is discovered from validated hook args
                source "$_envf" 2>/dev/null || true
                set +a
            fi
            _validate_extra_args=""
        fi
    fi
    # shellcheck disable=SC2086
    caddy validate $_validate_extra_args --config "$config_path" --adapter caddyfile >"$LAST_VALIDATE_LOG" 2>&1
}

backup_live_caddyfile() {
    local bak="$1"
    if [[ -f "$CADDYFILE" ]]; then
        cp -a "$CADDYFILE" "$bak"
        return 0
    fi
    : > "$bak"
    return 1
}

restore_live_caddyfile() {
    local bak="$1"
    local had_old="$2"
    if (( had_old )); then
        cp -a "$bak" "$CADDYFILE" 2>/dev/null || true
    else
        rm -f "$CADDYFILE" 2>/dev/null || true
    fi
    fix_permissions
}

service_ready() {
    command_exists systemctl || command_exists rc-service
}

# ── 服务抽象层（systemd / OpenRC） ──

detect_svc_backend() {
    if [[ -n "${SVC_BACKEND:-}" ]]; then
        return 0
    fi
    if command_exists systemctl; then
        SVC_BACKEND="systemd"
    elif command_exists rc-service; then
        SVC_BACKEND="openrc"
    else
        SVC_BACKEND=""
    fi
}

svc_is_active() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl is-active --quiet caddy 2>/dev/null ;;
        openrc)  rc-service -q caddy status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

_svc_with_timeout() {
    local cmd="$1"; shift
    if [[ "$SVC_BACKEND" == "systemd" ]] && command_exists timeout; then
        local to rc
        to="$(get_systemctl_timeout_seconds)"
        # BusyBox timeout lacks --foreground; detect and skip when unavailable
        local _fg_opt=""
        if timeout --foreground 0 true 2>/dev/null; then
            _fg_opt="--foreground"
        fi
        if timeout $_fg_opt "${to}s" systemctl "$cmd" caddy "$@"; then return 0; fi
        rc=$?
        if (( rc == 124 )); then
            fail "systemctl $cmd 超时（${to}s）"
        else
            fail "systemctl $cmd 执行失败"
        fi
        return "$rc"
    fi
    case "$SVC_BACKEND" in
        systemd) systemctl "$cmd" caddy "$@" ;;
        openrc)  rc-service caddy "$cmd" ;;
        *) fail "未检测到 service manager"; return 1 ;;
    esac
}

svc_reload()     { _svc_with_timeout reload; }
svc_restart()    { _svc_with_timeout restart; }
svc_start()      { _svc_with_timeout start; }
svc_stop()       { _svc_with_timeout stop; }
svc_daemon_reload() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl daemon-reload >/dev/null 2>&1 || true ;;
        openrc)  : ;;  # OpenRC has no daemon-reload equivalent
    esac
}

svc_enable() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl enable caddy >/dev/null 2>&1 || true ;;
        openrc)  rc-update add caddy default >/dev/null 2>&1 || true ;;
    esac
}

svc_status_show() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl status caddy --no-pager ;;
        openrc)  rc-service caddy status ;;
        *) fail "未检测到 service manager"; return 1 ;;
    esac
}

svc_unit_exists() {
    detect_svc_backend
    case "$SVC_BACKEND" in
        systemd) systemctl list-unit-files caddy.service >/dev/null 2>&1 ;;
        openrc)  [[ -f /etc/init.d/caddy ]] ;;
        *) return 1 ;;
    esac
}

svc_backend_name() { detect_svc_backend; echo "${SVC_BACKEND:-无}"; }


acquire_flock() {
    local fd="$1"
    local wait_seconds="$2"
    local elapsed=0

    if flock -w 0 "$fd" 2>/dev/null; then
        return 0
    fi

    while (( elapsed < wait_seconds )); do
        if flock -n "$fd" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 1
}

with_global_lock() {
    local wait_seconds fd rc
    wait_seconds="$(get_lock_wait_seconds)"

    if (( LOCK_HELD == 1 )); then
        local _lock_opts
        _lock_opts="$(set +o)"
        set +e
        "$@"
        rc=$?
        eval "$_lock_opts"
        return "$rc"
    fi

    if ! command_exists flock; then
        fail "未安装 flock（通常来自 util-linux），无法启用并发锁。"
        return 1
    fi

    mkdir -p "$(dirname "$LOCK_FILE")"
    exec {fd}> "$LOCK_FILE"
    if ! acquire_flock "$fd" "$wait_seconds"; then
        fail "获取全局操作锁超时（${wait_seconds}s），请稍后重试。"
        exec {fd}>&-
        return 1
    fi

    LOCK_HELD=1
    local _lock_opts
    _lock_opts="$(set +o)"
    set +e
    "$@"
    rc=$?
    eval "$_lock_opts"
    LOCK_HELD=0

    flock -u "$fd" 2>/dev/null || true
    exec {fd}>&-
    return "$rc"
}

safe_remove_snapshot_dir() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    [[ "$path" == "$SNAPSHOT_DIR/"* ]] || return 1
    rm -rf -- "$path" 2>/dev/null || true
}

prune_snapshots() {
    local -a snapshots=()
    local idx keep_from
    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        return 0
    fi
    mapfile -t snapshots < <(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    if (( ${#snapshots[@]} <= MAX_SNAPSHOTS )); then
        return 0
    fi
    keep_from=$(( ${#snapshots[@]} - MAX_SNAPSHOTS ))
    for (( idx=0; idx<keep_from; idx++ )); do
        safe_remove_snapshot_dir "${snapshots[$idx]}"
    done
}

create_snapshot() {
    local action="$1"
    local snapshot_id snapshot_path created

    mkdir -p "$SNAPSHOT_DIR"
    snapshot_id="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    snapshot_path="$SNAPSHOT_DIR/$snapshot_id"
    mkdir -p "$snapshot_path/sites" "$snapshot_path/globals"

    cp -a "$SITES_DIR"/. "$snapshot_path/sites"/ 2>/dev/null || true
    cp -a "$GLOBALS_DIR"/. "$snapshot_path/globals"/ 2>/dev/null || true
    cp -a "$STATE_FILE" "$snapshot_path/state.conf" 2>/dev/null || true
    cp -a "$CADDYFILE" "$snapshot_path/Caddyfile" 2>/dev/null || true

    created="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    cat > "$snapshot_path/meta" <<EOF
ACTION=$action
CREATED_AT=$created
EOF

    prune_snapshots
    printf '%s' "$snapshot_path"
}

latest_snapshot_path() {
    local latest=""
    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        return 1
    fi
    latest="$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
    [[ -n "$latest" ]] || return 1
    printf '%s' "$latest"
}

restore_snapshot_contents() {
    local snapshot_path="$1"

    [[ -d "$snapshot_path" ]] || return 1
    ensure_dirs
    clear_managed_dir "$SITES_DIR"
    clear_managed_dir "$GLOBALS_DIR"

    cp -a "$snapshot_path/sites"/. "$SITES_DIR"/ 2>/dev/null || true
    cp -a "$snapshot_path/globals"/. "$GLOBALS_DIR"/ 2>/dev/null || true
    if [[ -f "$snapshot_path/state.conf" ]]; then
        cp -a "$snapshot_path/state.conf" "$STATE_FILE" 2>/dev/null || true
    else
        : > "$STATE_FILE"
        chmod 644 "$STATE_FILE" 2>/dev/null || true
    fi

    load_state
    fix_permissions
}

run_mutation() {
    local action="$1"
    local snapshot_path rc
    shift

    snapshot_path="$(create_snapshot "$action")" || {
        fail "创建回滚快照失败"
        return 1
    }

    local _run_opts
    _run_opts="$(set +o)"
    set +e
    "$@"
    rc=$?
    eval "$_run_opts"

    if (( rc == 0 )); then
        say "已保存回滚快照: $(basename "$snapshot_path")"
    fi
    return "$rc"
}

is_local_upstream_host() {
    case "$1" in
        127.0.0.1|localhost|::1|0.0.0.0|::) return 0 ;;
        *) return 1 ;;
    esac
}

is_tcp_port_listening() {
    local port="$1"
    if command_exists ss; then
        ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
        return $?
    fi
    if command_exists netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
        return $?
    fi
    return 2
}

check_local_upstreams_health() {
    local config_path="$1"
    local mode target hostport host port rc
    local missing=0
    local unknown=0
    local -a targets=()
    local -a checked_ports=()
    local -A seen_ports=()

    mode="$(get_upstream_check_mode)"
    while IFS= read -r target; do
        target="$(trim "$target")"
        [[ -n "$target" ]] || continue
        targets+=("$target")
    done < <(sed -n 's/^[[:space:]]*reverse_proxy[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' "$config_path")

    for target in "${targets[@]}"; do
        hostport="$target"
        hostport="${hostport#http://}"
        hostport="${hostport#https://}"
        hostport="${hostport%%/*}"

        if [[ "$hostport" =~ ^\[(.+)\]:(.+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        elif [[ "$hostport" == *:* ]]; then
            host="${hostport%:*}"
            port="${hostport##*:}"
        else
            continue
        fi

        if ! validate_port "$port"; then
            continue
        fi
        if ! is_local_upstream_host "$host"; then
            continue
        fi
        if [[ -n "${seen_ports[$port]:-}" ]]; then
            continue
        fi
        seen_ports[$port]=1
        checked_ports+=("$port")
    done

    if (( ${#checked_ports[@]} == 0 )); then
        return 0
    fi

    say "正在检查本地上游端口可用性（模式: $mode）..."
    for port in "${checked_ports[@]}"; do
        rc=0
        is_tcp_port_listening "$port" || rc=$?
        if (( rc == 0 )); then
            say "[OK] localhost:$port 正在监听"
        elif (( rc == 2 )); then
            say "[WARN] 无法检查端口 $port（缺少 ss/netstat）"
            ((unknown++))
        else
            say "[WARN] localhost:$port 未监听"
            ((missing++))
        fi
    done

    if (( missing > 0 )) && [[ "$mode" == "strict" ]]; then
        fail "上游健康检查失败（strict 模式，$missing 个端口未监听）"
        return 1
    fi

    if (( unknown > 0 )); then
        say "[WARN] 部分端口无法检查，可安装 iproute2(netstat/ss) 提升准确度。"
    fi
    return 0
}

reload_or_start_caddy() {
    if ! service_ready; then
        say "未检测到 service manager（systemd/OpenRC），配置已写入 $CADDYFILE，请手动重载 Caddy。"
        return 0
    fi

    if svc_is_active; then
        say "正在重载 Caddy 服务..."
        if ! svc_reload; then
            say "reload 失败，降级为 restart..."
            svc_restart
        fi
        say "已重载 Caddy"
    else
        say "Caddy 未运行，正在启动..."
        svc_start
        say "Caddy 未运行，已自动启动"
    fi
}

apply_config() {
    ensure_dirs

    local bak tmp had_old=0
    bak="$(mktemp "$BACKUP_DIR/Caddyfile.XXXXXX")"
    tmp="$(mktemp)"

    if backup_live_caddyfile "$bak"; then
        had_old=1
    fi

    say "正在生成 Caddy 配置..."
    render_caddyfile_to "$tmp"

    if ! check_local_upstreams_health "$tmp"; then
        cleanup_paths "$bak" "$tmp"
        return 1
    fi

    say "正在校验配置..."
    if ! validate_config_file "$tmp"; then
        fail "配置校验失败，已保留错误日志: ${LAST_VALIDATE_LOG:-unknown}"
        [[ -n "${LAST_VALIDATE_LOG:-}" ]] && cat "$LAST_VALIDATE_LOG"
        cleanup_paths "$bak" "$tmp"
        return 1
    fi

    say "正在应用配置到 $CADDYFILE ..."
    mv "$tmp" "$CADDYFILE"
    fix_permissions

    say "正在使配置生效..."
    if ! reload_or_start_caddy; then
        fail "Caddy 重载或启动失败，正在尝试回滚。"
        restore_live_caddyfile "$bak" "$had_old"
        if service_ready; then
            svc_restart || true
        fi
        cleanup_paths "$bak"
        return 1
    fi

    cleanup_paths "${LAST_VALIDATE_LOG:-}"
    LAST_VALIDATE_LOG=""
    cleanup_paths "$bak"
    return 0
}

site_path_for_label() {
    local label="$1"
    local base
    base="$(sanitize_name "$label")"
    [[ -n "$base" ]] || base="site"

    local path="$SITES_DIR/$base.conf"
    local n=1
    while [[ -e "$path" ]]; do
        if grep -Fq "$label" "$path" 2>/dev/null; then
            break
        fi
        path="$SITES_DIR/${base}-${n}.conf"
        ((n++))
        (( n > 1000 )) && { fail "无法生成唯一文件名"; return 1; }
    done
    echo "$path"
}

disabled_site_path_for() {
    local file="$1"
    printf '%s.disabled\n' "$file"
}

get_primary_label() {
    local label
    label="$(trim "$1")"
    if [[ "$label" == *,* ]]; then
        label="${label%%,*}"
    fi
    trim "$label"
}

emit_site_common_blocks() {
    local emit_tls="${1:-yes}"
    cat <<'EOF'
    encode zstd gzip
EOF
    if [[ "$emit_tls" != "no" ]]; then
        _hook_render_site_tls
    fi
}

build_reverse_proxy_site_block() {
    local label="$1"
    local port="$2"
    local scheme="$3"

    cat <<EOF
$label {
EOF
    if [[ "$scheme" == "http" ]]; then
        emit_site_common_blocks no
        cat <<EOF
    reverse_proxy http://127.0.0.1:$port
}
EOF
    else
        emit_site_common_blocks
        cat <<EOF
    reverse_proxy 127.0.0.1:$port
}
EOF
    fi
}

build_path_proxy_site_block() {
    local label="$1"
    local port="$2"
    local path_prefix="$3"
    local scheme="$4"
    local primary matcher_name
    primary="$(get_primary_label "$label")"
    matcher_name="@path_$(sanitize_name "$primary")_$(sanitize_name "$path_prefix")"

    cat <<EOF
$label {
EOF
    if [[ "$scheme" == "http" ]]; then
        emit_site_common_blocks no
    else
        emit_site_common_blocks
    fi
    cat <<EOF
    $matcher_name path $path_prefix $path_prefix/*
    handle $matcher_name {
        uri strip_prefix $path_prefix
EOF
    if [[ "$scheme" == "http" ]]; then
        cat <<EOF
        reverse_proxy http://127.0.0.1:$port
    }
    handle {
        respond "Not Found" 404
    }
}
EOF
    else
        cat <<EOF
        reverse_proxy 127.0.0.1:$port
    }
    handle {
        respond "Not Found" 404
    }
}
EOF
    fi
}

build_static_site_block() {
    local label="$1"
    local site_dir="$2"
    local spa_mode="$3"

    cat <<EOF
$label {
EOF
    emit_site_common_blocks
    cat <<EOF
    root * $site_dir
EOF
    if [[ "$spa_mode" == "on" ]]; then
        cat <<'EOF'
    try_files {path} /index.html
EOF
    fi
    cat <<'EOF'
    file_server
}
EOF
}

write_site_file_with_rollback() {
    local file="$1"
    local oldbak="${2:-}"

    chmod 644 "$file"
    chown root:caddy "$file" 2>/dev/null || true

    if ! apply_config; then
        restore_file_from_backup "$file" "$oldbak"
        fix_permissions
        return 1
    fi

    cleanup_paths "$oldbak"
    return 0
}

build_emby_site_block() {
    local label="$1"
    local target_domain="$2"
    local scheme="$3"

    local site_label="$label"
    [[ "$scheme" == "http" ]] && site_label="http://${label}"

    cat <<EMBYEOF
${site_label} {
    reverse_proxy ${target_domain} {
        header_up Host {upstream_hostport}
    }
}
EMBYEOF
}

write_site_file() {
    local file="$1"
    local label="$2"
    local content="$3"
    local oldbak="${4:-}"

    [[ -n "$file" && -n "$content" ]] || {
        fail "write_site_file: file or content empty"
        return 1
    }

    printf '%s\n' "$content" > "$file"
    chmod 644 "$file"
    chown root:caddy "$file" 2>/dev/null || true

    if ! apply_config; then
        if [[ -n "$oldbak" ]]; then
            cp -a "$oldbak" "$file"
            cleanup_paths "$oldbak"
            fail "Caddy 配置重载失败，已回滚到旧配置"
        else
            rm -f "$file"
            fail "Caddy 配置重载失败，临时文件已删除"
        fi
        return 1
    fi

    cleanup_paths "$oldbak"
    log_ok "站点 \e[1;36m${label}\e[0m 已写入并生效"
    return 0
}

# ════════════════════════ 网关站点块生成 ════════════════════════
build_gateway_site_block() {
    local label="$1"
    local scheme="${2:-https}"

    cat <<BLOCK
# Emby 通用反代网关 — $label
# 用法: ${scheme}://${label}/<上游主机:端口>/路径
# 生成: $(date '+%F %T')

${scheme}://${label} {
    request_body {
        max_size 500MB
    }

    handle / {
        respond <<INFO
OK

通用反代网关 — Emby Proxy Toolbox (Caddy)

使用方式：
  ${scheme}://${label}/<上游主机:端口>/路径
  ${scheme}://${label}/http/<上游主机:端口>/路径
  ${scheme}://${label}/https/<上游主机:端口>/路径

默认按 HTTPS 回源；若需 HTTP 回源请使用 /http 前缀。
INFO 200
    }

    @noSlashHttp path_regexp redir_http ^/http/([A-Za-z0-9.\-_:]+)\$
    redir @noSlashHttp /http/{re.redir_http.1}/ 308

    @noSlashHttps path_regexp redir_https ^/https/([A-Za-z0-9.\-_:]+)\$
    redir @noSlashHttps /https/{re.redir_https.1}/ 308

    @httpProxy path_regexp up_http ^/http/([^/]+)(/.*)
    handle @httpProxy {
        rewrite * {re.up_http.2}
        reverse_proxy {
            to {re.up_http.1}
            transport http
            header_up Host {re.up_http.1}
            flush_interval -1
        }
    }

    @httpsProxy path_regexp up_https ^/https/([^/]+)(/.*)
    handle @httpsProxy {
        rewrite * {re.up_https.2}
        reverse_proxy {
            to {re.up_https.1}
            transport http {
                tls
            }
            header_up Host {re.up_https.1}
            flush_interval -1
        }
    }

    @defaultProxy {
        path_regexp up_default ^/([^/]+)(/.*)
        not path /http/* /https/*
    }
    handle @defaultProxy {
        rewrite * {re.up_default.2}
        reverse_proxy {
            to {re.up_default.1}
            transport http {
                tls
            }
            header_up Host {re.up_default.1}
            flush_interval -1
        }
    }

    @noSlash path_regexp redir_bare ^/([A-Za-z0-9.\-_:]+)\$
    redir @noSlash /{re.redir_bare.1}/ 308
}
BLOCK
}

cmd_add_emby() {
    local label=""
    local target_domain=""
    local scheme="https"
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --http) scheme="http" ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 add-emby 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    label="${positional[0]:-}"
    target_domain="${positional[1]:-}"

    if [[ -z "$label" ]]; then
        read -rp "请输入你的域名: " label
    fi
    label="$(trim "$label")"
    if [[ -z "$label" ]]; then
        fail "域名不能为空"
        return 1
    fi

    if [[ -z "$target_domain" ]]; then
        read -rp "请输入目标 Emby 服务器地址（如 https://emby.example.com:443）: " target_domain
    fi
    target_domain="$(trim "$target_domain")"
    if [[ -z "$target_domain" ]]; then
        fail "目标地址不能为空"
        return 1
    fi

    # Auto-add https:// if missing
    if [[ "$target_domain" != http://* ]] && [[ "$target_domain" != https://* ]]; then
        target_domain="https://${target_domain}"
    fi

    local sanitized old_file new_file file site_block
    sanitized="$(sanitize_name "$label")"
    new_file="${SITES_DIR}/${sanitized}.conf"
    old_file="${SITES_DIR}/${sanitized}.conf.disabled"

    for file in "$new_file" "$old_file"; do
        if [[ -s "$file" ]]; then
            fail "配置已存在: $file"
            say "如需修改请使用 c set $label --target <新地址>"
            return 1
        fi
    done

    site_block="$(build_emby_site_block "$label" "$target_domain" "$scheme")"
    ensure_dirs
    write_site_file "$new_file" "$label" "$site_block"
    fix_permissions
    if [[ "$scheme" == "http" ]]; then
        say "已添加 Emby 反代站点（HTTP，不申请证书）: $label -> $target_domain"
    else
        say "已添加 Emby 反代站点: $label -> $target_domain"
    fi
    say "注意: Emby 反代不启用 gzip 压缩（避免影响流媒体传输）"
}

cmd_add_gateway() {
    local label=""
    local scheme="https"
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-ssl|--http) scheme="http" ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 add-gateway 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    label="${positional[0]:-}"

    if [[ -z "$label" ]]; then
        read -rp "请输入网关域名: " label
    fi
    label="$(trim "$label")"
    if [[ -z "$label" ]]; then
        fail "域名不能为空"
        return 1
    fi

    local sanitized old_file new_file file site_block
    sanitized="$(sanitize_name "$label")"
    new_file="${SITES_DIR}/${sanitized}.conf"
    old_file="${SITES_DIR}/${sanitized}.conf.disabled"

    for file in "$new_file" "$old_file"; do
        if [[ -s "$file" ]]; then
            fail "配置已存在: $file"
            say "如需修改请先 c rm $label 后再创建"
            return 1
        fi
    done

    site_block="$(build_gateway_site_block "$label" "$scheme")"
    ensure_dirs
    write_site_file "$new_file" "$label" "$site_block"
    fix_permissions
    if [[ "$scheme" == "http" ]]; then
        say "已添加通用反代网关（HTTP，不申请证书）: $label"
    else
        say "已添加通用反代网关: $label（自动申请 Let's Encrypt 证书）"
    fi
    say "用法: ${scheme}://${label}/<上游主机:端口>/路径"
}

cmd_add() {
    local label=""
    local port=""
    local scheme="https"
    local path_prefix=""
    local force_dns_tls=0
    local -a positional=()

    while (( $# > 0 )); do
        case "$1" in
            --http) scheme="http" ;;
            --https) scheme="https" ;;
            --dns-only) force_dns_tls=1 ;;
            --path)
                shift
                [[ $# -gt 0 ]] || { fail "--path 需要一个前缀"; return 1; }
                path_prefix="$1"
                ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 add 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    label="${positional[0]:-}"
    port="${positional[1]:-}"

    if [[ -z "$label" ]]; then
        read -rp "站点地址（如 example.com 或 example.com, api.example.com）: " label
    fi
    if [[ -z "$port" ]]; then
        read -rp "本地端口: " port
    fi

    label="$(trim "$label")"
    path_prefix="$(trim "$path_prefix")"

    if ! validate_site_label "$label"; then
        fail "站点地址不合法"
        return 1
    fi
    if ! validate_port "$port"; then
        fail "端口不合法"
        return 1
    fi
    if [[ -n "$path_prefix" ]]; then
        path_prefix="$(normalize_path_prefix "$path_prefix")"
        if ! validate_path_prefix "$path_prefix"; then
            fail "路径前缀不合法，请使用类似 /api 的形式"
            return 1
        fi
    fi

    local file oldbak=""
    file="$(site_path_for_label "$label")"
    oldbak="$(backup_file_if_exists "$file")"

    # --dns-only: force DNS-01 even if cloudflare_dns_ready check fails
    FORCE_DNS_TLS="$force_dns_tls"

    if [[ -n "$path_prefix" ]]; then
        build_path_proxy_site_block "$label" "$port" "$path_prefix" "$scheme" > "$file"
    else
        build_reverse_proxy_site_block "$label" "$port" "$scheme" > "$file"
    fi

    # shellcheck disable=SC2034 # read by Cloudflare variant hook while rendering site TLS
    FORCE_DNS_TLS=0

    if ! write_site_file_with_rollback "$file" "$oldbak"; then
        fail "已回滚站点修改"
        return 1
    fi

    if [[ -n "$path_prefix" ]]; then
        say "已添加路径反代: $label $path_prefix -> 127.0.0.1:$port"
    else
        say "已添加反代站点: $label -> 127.0.0.1:$port"
    fi
}

cmd_add_static() {
    local label=""
    local site_dir=""
    local spa_mode="off"
    local -a positional=()

    while (( $# > 0 )); do
        case "$1" in
            --spa) spa_mode="on" ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 add-static 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    label="${positional[0]:-}"
    site_dir="${positional[1]:-}"

    if [[ -z "$label" ]]; then
        read -rp "站点地址（如 static.example.com）: " label
    fi
    if [[ -z "$site_dir" ]]; then
        read -rp "静态目录路径: " site_dir
    fi

    label="$(trim "$label")"
    site_dir="$(trim "$site_dir")"

    if [[ "$spa_mode" == "off" ]] && prompt_yes_no "是否按单页应用启用 try_files /index.html？"; then
        spa_mode="on"
    fi

    if ! validate_site_label "$label"; then
        fail "站点地址不合法"
        return 1
    fi
    if ! validate_static_dir "$site_dir"; then
        fail "静态目录路径不合法"
        return 1
    fi

    local file oldbak=""
    file="$(site_path_for_label "$label")"
    oldbak="$(backup_file_if_exists "$file")"

    build_static_site_block "$label" "$site_dir" "$spa_mode" > "$file"

    if ! write_site_file_with_rollback "$file" "$oldbak"; then
        fail "已回滚站点修改"
        return 1
    fi

    say "已添加静态站点: $label -> $site_dir"
    if [[ ! -d "$site_dir" ]]; then
        say "注意: 当前目录不存在，后续创建后即可由 Caddy 提供访问。"
    fi
}

cmd_set_emby() {
    local file="$1"
    local site_type="$2"
    local label="$3"
    local query="$4"
    local override_emby_target="$5"

    # Extract current target from file
    local current_target scheme label_from_file
    current_target="$(sed -n 's/^[[:space:]]*reverse_proxy[[:space:]]\+//p' "$file" | head -n 1)"
    current_target="$(trim "$current_target")"

    if [[ -z "$current_target" ]]; then
        fail "无法解析 Emby 反代目标: $file"
        return 1
    fi

    # Detect scheme from site label: domain only = https, http://domain = http
    label_from_file="$(sed -n '1s/^[[:space:]]\{0,\}\(.\{1,\}\)[[:space:]]\{0,\}{/\1/p' "$file")"
    label_from_file="$(trim "$label_from_file")"
    if [[ "$label_from_file" == http://* ]]; then
        scheme="http"
        label="${label_from_file#http://}"
    else
        scheme="https"
        label="$label_from_file"
    fi

    if [[ -z "$label" ]]; then
        fail "无法解析站点标签: $file"
        return 1
    fi

    say "当前 Emby 反代: ${label} → ${current_target}"

    local new_target=""
    if [[ -n "$override_emby_target" ]]; then
        new_target="$override_emby_target"
        say "使用指定目标: $new_target"
    else
        read -rp "输入新的 Emby 目标地址 (格式 example.com 或 1.2.3.4:8096): " new_target
        new_target="$(trim "$new_target")"
    fi

    if [[ -z "$new_target" ]]; then
        say "未提供新目标，已取消。"
        return 0
    fi

    # 构建完整 URL：自动补 http/https 和默认端口 8096
    if [[ "$new_target" != *://* ]]; then
        # 纯 IP:port 或 domain:port
        if [[ "$new_target" == *:* ]]; then
            new_target="${scheme}://${new_target}"
        else
            new_target="${scheme}://${new_target}:8096"
        fi
    fi

    say "新目标: ${label} → ${new_target}"
    say "当前协议: ${scheme}，如需切换请在 cmd_set 调用时使用 --http / --https"

    local site_block
    site_block="$(build_emby_site_block "$label" "$new_target" "$scheme")"

    local oldbak=""
    oldbak="$(backup_file_if_exists "$file")"
    write_site_file "$file" "$label" "$site_block" "$oldbak"
    fix_permissions
}

cmd_set() {
    local query=""
    local override_port=""
    local override_path="__keep__"
    local override_scheme=""
    local override_emby_target=""
    local -a positional=()

    while (( $# > 0 )); do
        case "$1" in
            --port)
                shift
                [[ $# -gt 0 ]] || { fail "--port 需要端口参数"; return 1; }
                override_port="$1"
                ;;
            --path)
                shift
                [[ $# -gt 0 ]] || { fail "--path 需要路径参数"; return 1; }
                override_path="$1"
                ;;
            --target)
                shift
                [[ $# -gt 0 ]] || { fail "--target 需要目标地址参数"; return 1; }
                override_emby_target="$1"
                ;;
            --http) override_scheme="http" ;;
            --https) override_scheme="https" ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 set 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    query="${positional[0]:-}"

    if [[ -z "$query" ]]; then
        read -rp "输入要编辑的站点地址: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点地址不能为空"
        return 1
    fi

    local file site_type label target path_prefix scheme
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi

    site_type="$(detect_site_type "$file")"
    if [[ "$site_type" == "静态站点" ]]; then
        fail "当前仅支持编辑反代站点与路径反代站点，静态站点请使用 add-static 重新配置。"
        return 1
    fi

    if [[ "$site_type" == "Emby反代" ]]; then
        cmd_set_emby "$file" "$site_type" "${label:-}" "$query" "$override_emby_target"
        return $?
    fi

    if ! label="$(extract_primary_site_label_from_file "$file")"; then
        fail "无法解析站点标签"
        return 1
    fi

    target="$(extract_reverse_proxy_target "$file")"
    if [[ -z "$target" ]]; then
        fail "无法解析反代目标"
        return 1
    fi

    parse_reverse_target_to_scheme_and_port "$target"
    scheme="$TARGET_SCHEME"
    if ! validate_port "$TARGET_PORT"; then
        fail "解析端口失败，请手工检查站点文件"
        return 1
    fi

    path_prefix="$(sed -n 's/^[[:space:]]*uri strip_prefix[[:space:]]\+//p' "$file" | head -n 1)"

    if [[ -n "$override_port" ]]; then
        if ! validate_port "$override_port"; then
            fail "端口不合法"
            return 1
        fi
        TARGET_PORT="$override_port"
    fi
    if [[ -n "$override_scheme" ]]; then
        scheme="$override_scheme"
    fi
    if [[ "$override_path" != "__keep__" ]]; then
        override_path="$(trim "$override_path")"
        case "$override_path" in
            ""|none|off|disable) path_prefix="" ;;
            *)
                override_path="$(normalize_path_prefix "$override_path")"
                if ! validate_path_prefix "$override_path"; then
                    fail "路径前缀不合法，请使用类似 /api 的形式"
                    return 1
                fi
                path_prefix="$override_path"
                ;;
        esac
    fi

    local oldbak tmp
    oldbak="$(backup_file_if_exists "$file")"
    tmp="$(mktemp)"

    if [[ -n "$path_prefix" ]]; then
        build_path_proxy_site_block "$label" "$TARGET_PORT" "$path_prefix" "$scheme" > "$tmp"
    else
        build_reverse_proxy_site_block "$label" "$TARGET_PORT" "$scheme" > "$tmp"
    fi
    mv "$tmp" "$file"

    if is_site_enabled "$file"; then
        if ! write_site_file_with_rollback "$file" "$oldbak"; then
            fail "已回滚站点修改"
            return 1
        fi
        say "已更新站点: $label"
    else
        chmod 644 "$file"
        chown root:caddy "$file" 2>/dev/null || true
        cleanup_paths "$oldbak"
        say "已更新禁用站点（未生效）: $label"
    fi
}

find_site_file() {
    local query="$1"
    local normalized basename_no_ext f
    local -a fuzzy_matches=()

    query="$(trim "$query")"
    [[ -n "$query" ]] || return 1
    normalized="$(sanitize_name "$query")"

    shopt -s nullglob
    local files=("$SITES_DIR"/*.conf "$SITES_DIR"/*.conf.disabled)
    for f in "${files[@]}"; do
        [[ -s "$f" ]] || continue

        basename_no_ext="$(basename "$f")"
        basename_no_ext="${basename_no_ext%.disabled}"
        basename_no_ext="${basename_no_ext%.conf}"
        if [[ "$basename_no_ext" == "$normalized" ]]; then
            echo "$f"
            shopt -u nullglob
            return 0
        fi
        if grep -Fq "$query" "$f"; then
            fuzzy_matches+=("$f")
        fi
    done
    shopt -u nullglob

    if (( ${#fuzzy_matches[@]} == 1 )); then
        if [[ -t 0 ]]; then
            echo "检测到模糊匹配: $(basename "${fuzzy_matches[0]}")" >&2
            if prompt_yes_no "是否使用该站点"; then
                echo "${fuzzy_matches[0]}"
                return 0
            fi
        else
            fail "匹配到模糊结果，请使用更精确的站点标识。"
        fi
        return 1
    fi

    if (( ${#fuzzy_matches[@]} > 1 )); then
        fail "匹配到多个站点，请使用更精确的站点标识。"
        for f in "${fuzzy_matches[@]}"; do
            echo "  - $(basename "$f")" >&2
        done
    fi
    return 1
}

detect_site_type() {
    local file="$1"
    if grep -q '通用反代网关' "$file" 2>/dev/null; then
        echo "网关"
    elif grep -Eq '^[[:space:]]*file_server([[:space:]]|$)' "$file"; then
        echo "静态站点"
    elif grep -Eq '^[[:space:]]*@path_.* path ' "$file" && grep -Eq '^[[:space:]]*uri strip_prefix ' "$file"; then
        echo "路径反代"
    elif grep -Eq '^[[:space:]]*header_up Host \{upstream_hostport\}' "$file"; then
        echo "Emby反代"
    elif grep -Eq '^[[:space:]]*reverse_proxy ' "$file"; then
        echo "反代站点"
    else
        echo "未知类型"
    fi
}

site_summary() {
    local file="$1"
    local type target path_prefix root_path
    type="$(detect_site_type "$file")"
    case "$type" in
        "静态站点")
            root_path="$(sed -n 's/^[[:space:]]*root \* //p' "$file" | head -n 1)"
            echo "目录: ${root_path:-unknown}"
            ;;
        "路径反代")
            path_prefix="$(sed -n 's/^[[:space:]]*uri strip_prefix //p' "$file" | head -n 1)"
            target="$(sed -n 's/^[[:space:]]*reverse_proxy //p' "$file" | head -n 1)"
            echo "路径: ${path_prefix:-unknown} -> ${target:-unknown}"
            ;;
        "Emby反代")
            target="$(sed -n 's/^[[:space:]]*reverse_proxy //p' "$file" | head -n 1)"
            echo "Emby服务器: ${target:-unknown}"
            ;;
        "网关")
            echo "通用反代网关（动态上游，无需指定目标）"
            ;;
        "反代站点")
            target="$(sed -n 's/^[[:space:]]*reverse_proxy //p' "$file" | head -n 1)"
            echo "目标: ${target:-unknown}"
            ;;
        *)
            echo "摘要: 未识别"
            ;;
    esac
}

extract_primary_site_label_from_file() {
    local file="$1"
    local -a headers=()
    local header=""

    mapfile -t headers < <(sed -n 's/^\([^[:space:]].*\)[[:space:]]*{[[:space:]]*$/\1/p' "$file")
    for header in "${headers[@]}"; do
        header="$(trim "$header")"
        [[ -n "$header" ]] || continue
        if [[ "$header" != www.* ]]; then
            printf '%s' "$header"
            return 0
        fi
    done
    if (( ${#headers[@]} > 0 )); then
        printf '%s' "$(trim "${headers[0]}")"
        return 0
    fi
    return 1
}

extract_reverse_proxy_target() {
    local file="$1"
    sed -n 's/^[[:space:]]*reverse_proxy[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' "$file" | head -n 1
}

parse_reverse_target_to_scheme_and_port() {
    local target="$1"
    local hostport

    TARGET_SCHEME="https"
    TARGET_PORT=""

    hostport="$target"
    if [[ "$hostport" == http://* ]]; then
        TARGET_SCHEME="http"
        hostport="${hostport#http://}"
    elif [[ "$hostport" == https://* ]]; then
        TARGET_SCHEME="https"
        hostport="${hostport#https://}"
    fi
    hostport="${hostport%%/*}"

    if [[ "$hostport" == *:* ]]; then
        TARGET_PORT="${hostport##*:}"
    fi
}

cmd_rm() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        read -rp "输入要删除的站点地址: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点地址不能为空"
        return 1
    fi

    local file oldbak=""
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi

    oldbak="$(mktemp "$BACKUP_DIR/site.XXXXXX")"
    cp -a "$file" "$oldbak"
    rm -f "$file"

    if ! apply_config; then
        cp -a "$oldbak" "$file"
        cleanup_paths "$oldbak"
        fix_permissions
        fail "已回滚删除操作"
        return 1
    fi

    cleanup_paths "$oldbak"
    say "已删除: $query"
}

cmd_list() {
    echo "===== 邮箱 ====="
    echo "${EMAIL:-<未设置>}"
    echo

    echo "===== 全局片段 ====="
    shopt -s nullglob
    local gfiles=("$GLOBALS_DIR"/*.inc)
    if (( ${#gfiles[@]} == 0 )); then
        echo "暂无"
    else
        for f in "${gfiles[@]}"; do
            echo "---- $(basename "$f") ----"
            sed -n '1,80p' "$f"
            echo
        done
    fi
    shopt -u nullglob

    echo "===== 站点 ====="
    shopt -s nullglob
    local sfiles=("$SITES_DIR"/*.conf)
    local disabled_files=("$SITES_DIR"/*.conf.disabled)
    if (( ${#sfiles[@]} == 0 )); then
        echo "暂无"
    else
        for f in "${sfiles[@]}"; do
            echo "---- $(basename "$f") [$(detect_site_type "$f") / $(site_file_status "$f")] ----"
            site_summary "$f"
            sed -n '1,80p' "$f"
            echo
        done
    fi
    shopt -u nullglob

    _hook_list_extra

    echo "===== 已禁用站点 ====="
    shopt -s nullglob
    if (( ${#disabled_files[@]} == 0 )); then
        echo "暂无"
    else
        for f in "${disabled_files[@]}"; do
            echo "---- $(basename "$f") [$(detect_site_type "$f") / $(site_file_status "$f")] ----"
            site_summary "$f"
            sed -n '1,80p' "$f"
            echo
        done
    fi
    shopt -u nullglob
}

cmd_email() {
    local new_email="${1:-}"
    if [[ -z "$new_email" ]]; then
        read -rp "请输入邮箱（回车清空）: " new_email
    fi

    if ! validate_email "$new_email"; then
        fail "邮箱格式不合法"
        return 1
    fi

    local old_email="${EMAIL:-}"
    EMAIL="$new_email"
    save_state

    if ! apply_config; then
        EMAIL="$old_email"
        save_state
        fix_permissions
        fail "已回滚邮箱设置"
        return 1
    fi

    say "已更新邮箱"
}

cmd_timeout() {
    local new_timeout="${1:-}"
    local effective_timeout
    effective_timeout="$(get_systemctl_timeout_seconds)"

    if [[ -z "$new_timeout" ]]; then
        say "当前服务超时: ${effective_timeout}s（持久配置: ${SYSTEMCTL_TIMEOUT_SECONDS}s）"
        if [[ -n "${CADDYCTL_SYSTEMCTL_TIMEOUT:-}" ]]; then
            say "当前会话由环境变量 CADDYCTL_SYSTEMCTL_TIMEOUT 覆盖。"
        fi
        return 0
    fi

    if [[ "$new_timeout" == "default" ]]; then
        new_timeout="$DEFAULT_SYSTEMCTL_TIMEOUT"
    fi

    if ! validate_timeout_seconds "$new_timeout"; then
        fail "超时必须是 ${MIN_SYSTEMCTL_TIMEOUT}-${MAX_SYSTEMCTL_TIMEOUT} 秒内的整数"
        return 1
    fi

    SYSTEMCTL_TIMEOUT_SECONDS="$new_timeout"
    save_state
    say "已设置服务超时: ${SYSTEMCTL_TIMEOUT_SECONDS}s"
}

cmd_upstream_mode() {
    local new_mode="${1:-}"
    local effective_mode
    effective_mode="$(get_upstream_check_mode)"

    if [[ -z "$new_mode" ]]; then
        say "当前上游健康检查模式: ${effective_mode}（持久配置: ${UPSTREAM_CHECK_MODE}）"
        if [[ -n "${CADDYCTL_UPSTREAM_CHECK_MODE:-}" ]]; then
            say "当前会话由环境变量 CADDYCTL_UPSTREAM_CHECK_MODE 覆盖。"
        fi
        return 0
    fi

    if ! validate_upstream_check_mode "$new_mode"; then
        fail "模式仅支持 warn 或 strict"
        return 1
    fi

    UPSTREAM_CHECK_MODE="$new_mode"
    save_state
    say "已设置上游健康检查模式: $UPSTREAM_CHECK_MODE"
}

cmd_validate() {
    local tmp
    tmp="$(mktemp)"
    render_caddyfile_to "$tmp"

    if validate_config_file "$tmp"; then
        say "配置校验通过"
        cleanup_paths "$tmp"
        cleanup_paths "${LAST_VALIDATE_LOG:-}"
        LAST_VALIDATE_LOG=""
    else
        fail "配置校验失败，日志: ${LAST_VALIDATE_LOG:-unknown}"
        [[ -n "${LAST_VALIDATE_LOG:-}" ]] && cat "$LAST_VALIDATE_LOG"
        cleanup_paths "$tmp"
        return 1
    fi
}

cmd_apply() {
    if ! has_any_config; then
        say "没有可应用的配置"
        return 0
    fi
    apply_config
}

cmd_config() {
    if [[ -f "$CADDYFILE" ]]; then
        cat "$CADDYFILE"
    else
        fail "未找到 $CADDYFILE"
    fi
}

cmd_status() {
    service_ready || { fail "未检测到 service manager"; return 1; }
    svc_status_show
}

cmd_logs() {
    if command_exists journalctl && journalctl -u caddy -n 1 --no-pager >/dev/null 2>&1; then
        journalctl -u caddy -n 120 --no-pager
    elif [[ -f /var/log/caddy.log ]]; then
        tail -n 120 /var/log/caddy.log
    elif [[ -f /var/log/caddy/caddy.log ]]; then
        tail -n 120 /var/log/caddy/caddy.log
    else
        fail "未检测到 Caddy 日志（无 journalctl，/var/log/caddy.log 不存在）"
        return 1
    fi
}

cmd_start() {
    service_ready || { fail "未检测到 service manager"; return 1; }
    svc_start
}

cmd_restart() {
    service_ready || { fail "未检测到 service manager"; return 1; }
    svc_restart
}

cmd_stop() {
    service_ready || { fail "未检测到 service manager"; return 1; }
    svc_stop
}

cmd_disable() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        read -rp "输入要禁用的站点地址: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点地址不能为空"
        return 1
    fi

    local file target
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi
    if ! is_site_enabled "$file"; then
        fail "该站点已经是禁用状态"
        return 1
    fi

    target="$(disabled_site_path_for "$file")"
    mv "$file" "$target"

    if ! apply_config; then
        mv "$target" "$file"
        fix_permissions
        fail "已回滚禁用操作"
        return 1
    fi

    say "已禁用: $query"
}

cmd_enable() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        read -rp "输入要启用的站点地址: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点地址不能为空"
        return 1
    fi

    local file target
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi
    if is_site_enabled "$file"; then
        fail "该站点已经是启用状态"
        return 1
    fi

    target="${file%.disabled}"
    if [[ -e "$target" ]]; then
        fail "启用失败，目标文件已存在: $target"
        return 1
    fi

    mv "$file" "$target"

    if ! apply_config; then
        mv "$target" "$file"
        fix_permissions
        fail "已回滚启用操作"
        return 1
    fi

    say "已启用: $query"
}

cmd_undo() {
    local requested="${1:-latest}"
    local snapshot_path guard_snapshot

    if [[ "$requested" == "latest" || -z "$requested" ]]; then
        if ! snapshot_path="$(latest_snapshot_path)"; then
            fail "没有可回滚的快照"
            return 1
        fi
    else
        if [[ "$requested" == */* ]]; then
            fail "快照ID格式不合法"
            return 1
        fi
        snapshot_path="$SNAPSHOT_DIR/$requested"
        if [[ ! -d "$snapshot_path" ]]; then
            fail "快照不存在: $requested"
            return 1
        fi
    fi

    guard_snapshot="$(create_snapshot "undo-guard")" || {
        fail "创建回滚保护快照失败"
        return 1
    }

    if ! restore_snapshot_contents "$snapshot_path"; then
        fail "恢复快照内容失败"
        safe_remove_snapshot_dir "$guard_snapshot"
        return 1
    fi

    if ! apply_config; then
        fail "回滚后应用失败，正在恢复回滚前状态。"
        restore_snapshot_contents "$guard_snapshot" || true
        apply_config || true
        safe_remove_snapshot_dir "$guard_snapshot"
        return 1
    fi

    safe_remove_snapshot_dir "$snapshot_path"
    safe_remove_snapshot_dir "$guard_snapshot"
    say "已回滚到快照: $(basename "$snapshot_path")"
}

cmd_cert_check() {
    local domain="${1:-}"
    local http_code https_code matched_file=""

    if [[ -z "$domain" ]]; then
        read -rp "输入要诊断的域名: " domain
    fi
    domain="$(trim "$domain")"
    if ! validate_domain "$domain"; then
        fail "域名格式不合法"
        return 1
    fi

    echo "===== 证书诊断: $domain ====="

    if command_exists dig; then
        local a_records aaaa_records
        a_records="$(dig +short A "$domain" | tr '\n' ' ')"
        aaaa_records="$(dig +short AAAA "$domain" | tr '\n' ' ')"
        a_records="$(trim "$a_records")"
        aaaa_records="$(trim "$aaaa_records")"
        if [[ -n "$a_records" || -n "$aaaa_records" ]]; then
            echo "[OK] DNS 解析:"
            [[ -n "$a_records" ]] && echo "  A: $a_records"
            [[ -n "$aaaa_records" ]] && echo "  AAAA: $aaaa_records"
        else
            echo "[WARN] DNS 未解析到 A/AAAA 记录"
        fi
    elif command_exists getent; then
        local hosts
        hosts="$(getent hosts "$domain" | awk '{print $1}' | tr '\n' ' ')"
        hosts="$(trim "$hosts")"
        if [[ -n "$hosts" ]]; then
            echo "[OK] DNS 解析: $hosts"
        else
            echo "[WARN] DNS 未解析到记录"
        fi
    else
        echo "[WARN] 缺少 dig/getent，跳过 DNS 检查"
    fi

    local f
    shopt -s nullglob
    for f in "$SITES_DIR"/*.conf "$SITES_DIR"/*.conf.disabled; do
        [[ -s "$f" ]] || continue
        if grep -Fq "$domain" "$f"; then
            matched_file="$f"
            break
        fi
    done
    shopt -u nullglob
    if [[ -n "$matched_file" ]]; then
        echo "[OK] 站点配置存在: $(basename "$matched_file")"
    else
        echo "[WARN] 未在站点配置中发现该域名"
    fi

    if command_exists curl; then
        http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "http://$domain/" || echo 000)"
        https_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "https://$domain/" || echo 000)"
        if [[ "$http_code" == "000" ]]; then
            echo "[WARN] HTTP 不可达"
        else
            echo "[OK] HTTP 可达，状态码: $http_code"
        fi
        if [[ "$https_code" == "000" ]]; then
            echo "[WARN] HTTPS 不可达"
        else
            echo "[OK] HTTPS 可达，状态码: $https_code"
        fi
    else
        echo "[WARN] 缺少 curl，跳过连通性检查"
    fi

    if command_exists journalctl; then
        echo
        echo "===== 最近证书相关日志（最多20行） ====="
        journalctl -u caddy -n 300 --no-pager 2>/dev/null | grep -Ei 'acme|certificate|tls|challenge|issuer' | tail -n 20 || true
    elif [[ -f /var/log/caddy/caddy.log ]]; then
        echo
        echo "===== 最近证书相关日志（最多20行） ====="
        grep -Ei 'acme|certificate|tls|challenge|issuer' /var/log/caddy/caddy.log 2>/dev/null | tail -n 20 || true
    else
        echo "[WARN] 缺少 journalctl 和日志文件，跳过日志诊断"
    fi
}

cmd_doctor() {
    echo "===== 环境检查 ====="

    if command_exists caddy; then
        echo "[OK] 已安装 caddy: $(caddy version 2>/dev/null || echo unknown)"
    else
        echo "[NO] 未安装 caddy"
    fi

    if command_exists python3; then
        echo "[OK] 已安装 python3"
    else
        echo "[WARN] 未安装 python3，import 功能不可用"
    fi

    if service_ready; then
        echo "[OK] 检测到 service manager: $(svc_backend_name)"
        if svc_unit_exists; then
            echo "[OK] 检测到 caddy 服务单元"
        else
            echo "[WARN] 未检测到 caddy 服务单元"
        fi

        if svc_is_active; then
            echo "[OK] Caddy 正在运行"
        else
            echo "[WARN] Caddy 未运行"
        fi
    else
        echo "[WARN] 未检测到 service manager（systemd/OpenRC）"
    fi
    echo "[INFO] 操作锁等待: $(get_lock_wait_seconds)s（可用环境变量 CADDYCTL_LOCK_WAIT_SECONDS 覆盖）"
    echo "[INFO] 上游健康检查模式: $(get_upstream_check_mode)"
    _hook_cmd_doctor

    echo
    echo "===== 目录检查 ====="
    for path in /etc/caddy "$SITES_DIR" "$GLOBALS_DIR" "$BACKUP_DIR" "$STATE_FILE" "$ACCESS_LOG_DIR"; do
        if [[ -e "$path" ]]; then
            echo "[OK] $path"
        else
            echo "[WARN] $path 不存在"
        fi
    done
}

cmd_install_self() {
    local src target_bin target_alias
    src="$(current_script_path)" || {
        fail "无法定位当前脚本路径，不能自动安装命令"
        return 1
    }

    target_bin="/usr/local/bin/caddyctl"
    target_alias="/usr/local/bin/c"

    install -d -m 0755 "$(dirname "$target_bin")"
    install -m 0755 "$src" "$target_bin"
    ln -sf "$target_bin" "$target_alias"

    say "已安装脚本命令:"
    say "  $target_bin"
    say "  $target_alias -> $target_bin"
    say "现在可以直接运行: c"
}

cmd_update() {
    require_command curl
    require_command bash

    local url lib_url tmp tmp_lib target_bin target_alias lib_bin
    url="${CADDYCTL_UPDATE_URL:-$DEFAULT_UPDATE_URL}"
    lib_url="${url%/*}/caddy-lib.sh"

    target_bin="/usr/local/bin/caddyctl"
    target_alias="/usr/local/bin/c"
    lib_bin="/usr/local/bin/caddy-lib.sh"

    # 1) 下载并安装前端脚本
    tmp="$(mktemp)"
    say "正在下载: $url"
    if ! curl -fsSL --retry 3 --retry-delay 1 "$url" -o "$tmp"; then
        cleanup_paths "$tmp"
        fail "下载失败，请检查网络或 URL。"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        cleanup_paths "$tmp"
        fail "下载结果为空，已中止更新。"
        return 1
    fi
    if ! bash -n "$tmp"; then
        cleanup_paths "$tmp"
        fail "下载脚本语法校验失败，已中止更新。"
        return 1
    fi
    install -d -m 0755 "$(dirname "$target_bin")"
    install -m 0755 "$tmp" "$target_bin"
    ln -sf "$target_bin" "$target_alias"
    cleanup_paths "$tmp"

    # 2) 下载并安装共享库
    tmp_lib="$(mktemp)"
    say "正在下载: $lib_url"
    if ! curl -fsSL --retry 3 --retry-delay 1 "$lib_url" -o "$tmp_lib"; then
        cleanup_paths "$tmp_lib"
        fail "共享库下载失败，前端已更新但库未更新，请检查网络。"
        return 1
    fi
    if [[ ! -s "$tmp_lib" ]]; then
        cleanup_paths "$tmp_lib"
        fail "共享库下载为空，已中止。"
        return 1
    fi
    if ! bash -n "$tmp_lib"; then
        cleanup_paths "$tmp_lib"
        fail "共享库语法校验失败，已中止。"
        return 1
    fi
    install -d -m 0755 "$(dirname "$lib_bin")"
    install -m 0644 "$tmp_lib" "$lib_bin"
    cleanup_paths "$tmp_lib"

    say "更新完成:"
    say "  $target_bin"
    say "  $target_alias -> $target_bin"
    say "  $lib_bin"
}

install_caddy_via_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
}

install_caddy_via_dnf() {
    if dnf install -y dnf5-plugins >/dev/null 2>&1; then
        :
    else
        dnf install -y dnf-plugins-core
    fi
    dnf -y copr enable @caddy/caddy
    dnf install -y caddy
}

install_caddy_via_pacman() {
    pacman -Sy --noconfirm caddy
}

install_caddy_via_apk() {
    if ! grep -q '^[^#]*community' /etc/apk/repositories 2>/dev/null; then
        local ver
        ver=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "3.21")
        say "启用 Alpine community 仓库..."
        echo "https://dl-cdn.alpinelinux.org/alpine/v${ver}/community" >> /etc/apk/repositories
    fi
    apk update
    apk add caddy
}


cmd_install() {
    if command_exists caddy; then
        say "检测到 caddy 已安装: $(caddy version 2>/dev/null || echo unknown)"
    elif command_exists apt-get; then
        say "检测到 apt-get，按 Caddy 官方文档安装稳定版。"
        install_caddy_via_apt
    elif command_exists dnf; then
        say "检测到 dnf，按 Caddy 官方文档安装稳定版。"
        install_caddy_via_dnf
    elif command_exists pacman; then
        say "检测到 pacman，按发行版仓库安装 Caddy。"
        install_caddy_via_pacman
    elif command_exists apk; then
        say "检测到 apk（Alpine），安装 Caddy..."
        install_caddy_via_apk
    else
        fail "当前系统未适配自动安装，请按 https://caddyserver.com/docs/install 手动安装"
        return 1
    fi

    ensure_dirs
    fix_permissions

    if current_script_path >/dev/null 2>&1; then
        cmd_install_self
    else
        say "未能自动安装脚本命令，请手动把脚本放到 /usr/local/bin/c 并赋予执行权限。"
    fi

    if service_ready; then
        svc_enable
        if has_any_config; then
            apply_config
        else
            svc_start || true
        fi
    fi

    say "安装完成"
}

cmd_show_help() {
    cat <<'EOF'
用法:
  c install
  c install-self
  c update
  c doctor
  c add <域名> <本地端口> [--http] [--path <前缀>] [--dns-only]
  c add-static <域名> <目录> [--spa]
  c add-emby <域名> <目标地址> [--http]
  c add-gateway <域名> [--no-ssl]
  c set <域名> [--port <端口>] [--path <前缀|none>] [--http|--https] [--target <地址>]
  c rm <域名>
  c enable <域名>
  c disable <域名>
  c list
  c email [邮箱]
  c timeout [秒|default]
  c upstream-mode [warn|strict]
  c import [现有Caddyfile路径]
  c undo [快照ID]
  c apply
  c validate
  c cert-check <域名>
  c status
  c logs
  c config
  c start
  c restart
  c stop
  c menu

（别名: ls=list, rm=del=delete, check=validate, reload=apply, emby=add-emby, gateway=add-gateway）
示例:
  c add example.com 3000
  c add example.com 3000 --path /api
  c add example.com 3000 --dns-only
  c add-static static.example.com /var/www/site --spa
  c add-emby emby.example.com https://10.0.0.5:8096
  c add-emby lan.example.com http://10.0.0.5:8096 --http
  c add-gateway gate.example.com
  c add-gateway gate.local --no-ssl
  c update
  c set example.com --port 4000
  c set emby.example.com --target https://10.0.0.6:8096
  c timeout 45
  c upstream-mode strict
  c cert-check example.com
  c undo
  c disable example.com
  c enable example.com
EOF
    _hook_help_extra
}

restore_import_snapshot() {
    local sites_bak="$1"
    local globals_bak="$2"
    local state_bak="$3"
    local old_email="$4"

    clear_managed_dir "$SITES_DIR"
    clear_managed_dir "$GLOBALS_DIR"
    cp -a "$sites_bak"/. "$SITES_DIR"/ 2>/dev/null || true
    cp -a "$globals_bak"/. "$GLOBALS_DIR"/ 2>/dev/null || true
    cp -a "$state_bak" "$STATE_FILE" 2>/dev/null || true
    EMAIL="$old_email"
    save_state
    fix_permissions
}

cmd_import() {
    require_command python3

    local src="${1:-$CADDYFILE}"
    if [[ ! -f "$src" ]]; then
        fail "找不到源文件: $src"
        return 1
    fi

    local sites_bak globals_bak state_bak old_email
    sites_bak="$(mktemp -d "$BACKUP_DIR/sites.XXXXXX")"
    globals_bak="$(mktemp -d "$BACKUP_DIR/globals.XXXXXX")"
    state_bak="$(mktemp "$BACKUP_DIR/state.XXXXXX")"
    old_email="${EMAIL:-}"

    cp -a "$SITES_DIR"/. "$sites_bak"/ 2>/dev/null || true
    cp -a "$GLOBALS_DIR"/. "$globals_bak"/ 2>/dev/null || true
    cp -a "$STATE_FILE" "$state_bak" 2>/dev/null || true

    clear_managed_dir "$SITES_DIR"
    clear_managed_dir "$GLOBALS_DIR"

    local tmp_src meta
    tmp_src="$(mktemp)"
    cp -a "$src" "$tmp_src"
    caddy fmt --overwrite "$tmp_src" >/dev/null 2>&1 || true

    meta="$(python3 - "$tmp_src" "$GLOBALS_DIR" "$SITES_DIR" <<'PY'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])
globals_dir = Path(sys.argv[2])
sites_dir = Path(sys.argv[3])

text = src.read_text(encoding="utf-8", errors="ignore")
lines = text.splitlines()

def strip_comments(s: str) -> str:
    out = []
    in_sq = False
    in_dq = False
    esc = False
    for ch in s:
        if ch == "#" and not in_sq and not in_dq:
            break
        out.append(ch)
        if ch == '"' and not in_sq and not esc:
            in_dq = not in_dq
        elif ch == "'" and not in_dq and not esc:
            in_sq = not in_sq
        esc = (ch == "\\" and not esc)
        if ch != "\\":
            esc = False
    return "".join(out)

blocks = []
buf = []
depth = 0
started = False

for line in lines:
    clean = strip_comments(line)
    if not started and clean.strip() == "":
        continue
    if not started:
        started = True
    buf.append(line)
    depth += clean.count("{") - clean.count("}")
    if started and depth == 0 and buf:
        blocks.append(buf)
        buf = []
        started = False

if buf:
    blocks.append(buf)

global_lines = []
site_blocks = []
found_email = ""
email_re = re.compile(r"^\s*email\s+(\S+)")

for block in blocks:
    first = next((strip_comments(x).strip() for x in block if strip_comments(x).strip()), "")
    if not first:
        continue

    if first.startswith("{"):
        inner = block[1:-1] if len(block) >= 2 else []
        for ln in inner:
            raw = ln.rstrip()
            if not raw.strip():
                global_lines.append("")
                continue
            match = email_re.match(raw)
            if match and not found_email:
                found_email = match.group(1)
                continue
            global_lines.append(raw)
    else:
        site_blocks.append(block)

(globals_dir / "00-imported.inc").write_text(
    "\n".join(global_lines).rstrip() + ("\n" if global_lines else ""),
    encoding="utf-8",
)

def slugify(label: str) -> str:
    label = strip_comments(label).strip()
    label = label.split("{", 1)[0].strip()
    label = label.replace(",", "_")
    label = re.sub(r"[^A-Za-z0-9._-]+", "_", label)
    label = re.sub(r"_+", "_", label).strip("_")
    return label or "site"

for block in site_blocks:
    header = next((x for x in block if strip_comments(x).strip()), "")
    name = slugify(header)
    path = sites_dir / f"{name}.conf"
    if path.exists():
        existing = path.read_text(encoding="utf-8", errors="ignore").strip()
        new_content = "\n".join(block).strip()
        if existing != new_content:
            n = 1
            while True:
                alt = sites_dir / f"{name}-{n}.conf"
                if not alt.exists():
                    path = alt
                    break
                n += 1
    path.write_text("\n".join(block).rstrip() + "\n", encoding="utf-8")

if found_email:
    print(f"EMAIL={found_email}")
PY
    )" || {
        fail "导入失败，正在回滚目录。"
        restore_import_snapshot "$sites_bak" "$globals_bak" "$state_bak" "$old_email"
        cleanup_paths "$sites_bak" "$globals_bak" "$tmp_src" "$state_bak"
        return 1
    }

    if [[ "$meta" =~ ^EMAIL=(.*)$ ]]; then
        EMAIL="${BASH_REMATCH[1]}"
        save_state
    fi

    if ! apply_config; then
        fail "导入后应用失败，正在回滚目录。"
        restore_import_snapshot "$sites_bak" "$globals_bak" "$state_bak" "$old_email"
        cleanup_paths "$sites_bak" "$globals_bak" "$tmp_src" "$state_bak"
        return 1
    fi

    cleanup_paths "$sites_bak" "$globals_bak" "$tmp_src" "$state_bak"
    say "导入完成"
}

pause_menu() {
    echo
    read -rp "按回车继续..." _
}

show_menu_header() {
    local title="$1"
    clear
    echo "====== $title ======"
}

menu_main() {
    show_menu_header "Caddy CLI 管理面板"
    echo "1. 站点管理"
    echo "2. 配置管理"
    echo "3. 服务管理"
    echo "4. 安装与诊断"
    echo "0. 退出"
    echo "============================"
}

menu_sites() {
    show_menu_header "站点管理"
    echo "1. 添加反代站点"
    echo "2. 添加静态站点"
    echo "3. 添加 Emby 反代"
    echo "4. 添加通用反代网关"
    echo "5. 删除站点"
    echo "6. 启用站点"
    echo "7. 禁用站点"
    echo "8. 查看站点列表"
    echo "9. 修改站点配置"
    echo "0. 返回上一级"
    echo "======================"
}

menu_config() {
    show_menu_header "配置管理"
    echo "1. 查看配置列表"
    echo "2. 设置邮箱"
    echo "3. 导入现有配置"
    echo "4. 仅校验配置"
    echo "5. 应用配置"
    echo "6. 查看当前 Caddyfile"
    echo "7. 设置服务超时"
    echo "8. 设置上游检查模式"
    echo "9. 回滚上一步"
    _hook_menu_config_items
    echo "0. 返回上一级"
    echo "======================"
}

menu_service() {
    show_menu_header "服务管理"
    echo "1. 查看状态"
    echo "2. 查看日志"
    echo "3. 启动 Caddy"
    echo "4. 停止 Caddy"
    echo "5. 重启 Caddy"
    echo "6. 证书诊断"
    echo "0. 返回上一级"
    echo "======================"
}

menu_install() {
    show_menu_header "安装与诊断"
    echo "1. 安装/初始化 Caddy"
    echo "2. 安装当前脚本命令"
    echo "3. 环境检查"
    echo "4. 更新当前脚本"
    echo "0. 返回上一级"
    echo "======================"
}

interactive_sites_menu() {
    local choice=""
    while true; do
        menu_sites
        read -rp "选择: " choice
        case "$choice" in
            1) require_command caddy; with_global_lock run_mutation add cmd_add ;;
            2) require_command caddy; with_global_lock run_mutation add-static cmd_add_static ;;
            3) require_command caddy; with_global_lock run_mutation add-emby cmd_add_emby ;;
            4) require_command caddy; with_global_lock run_mutation add-gateway cmd_add_gateway ;;
            5) require_command caddy; with_global_lock run_mutation rm cmd_rm ;;
            6) require_command caddy; with_global_lock run_mutation enable cmd_enable ;;
            7) require_command caddy; with_global_lock run_mutation disable cmd_disable ;;
            8) cmd_list ;;
            9) require_command caddy; with_global_lock run_mutation set cmd_set ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_config_menu() {
    local choice=""
    while true; do
        menu_config
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_list ;;
            2) require_command caddy; with_global_lock run_mutation email cmd_email ;;
            3) require_command caddy; with_global_lock run_mutation import cmd_import ;;
            4) require_command caddy; cmd_validate ;;
            5) require_command caddy; with_global_lock run_mutation apply cmd_apply ;;
            6) cmd_config ;;
            7) with_global_lock run_mutation timeout cmd_timeout ;;
            8) with_global_lock run_mutation upstream-mode cmd_upstream_mode ;;
            9) require_command caddy; with_global_lock cmd_undo ;;
            0) return 0 ;;
            *) _hook_menu_config_handler "$choice" && continue ;&
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_service_menu() {
    local choice=""
    while true; do
        menu_service
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_status ;;
            2) cmd_logs ;;
            3) with_global_lock cmd_start ;;
            4) with_global_lock cmd_stop ;;
            5) with_global_lock cmd_restart ;;
            6) cmd_cert_check ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_install_menu() {
    local choice=""
    while true; do
        menu_install
        read -rp "选择: " choice
        case "$choice" in
            1) with_global_lock cmd_install ;;
            2) with_global_lock cmd_install_self ;;
            3) cmd_doctor ;;
            4) with_global_lock cmd_update ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_menu() {
    local choice=""
    while true; do
        menu_main
        read -rp "选择: " choice
        case "$choice" in
            1) interactive_sites_menu ;;
            2) interactive_config_menu ;;
            3) interactive_service_menu ;;
            4) interactive_install_menu ;;
            0) exit 0 ;;
            *) fail "无效输入"; pause_menu ;;
        esac
    done
}

main() {
    require_root

    ensure_dirs
    load_state
    fix_permissions

    local cmd="${1:-}"
    case "$cmd" in
        install) with_global_lock cmd_install ;;
        install-self|self-install) with_global_lock cmd_install_self ;;
        update) with_global_lock cmd_update ;;
        doctor|check-env) cmd_doctor ;;
        add) shift; require_command caddy; with_global_lock run_mutation add cmd_add "$@" ;;
        add-static|static) shift; require_command caddy; with_global_lock run_mutation add-static cmd_add_static "$@" ;;
        add-emby|emby) shift; require_command caddy; with_global_lock run_mutation add-emby cmd_add_emby "$@" ;;
        add-gateway|gateway) shift; require_command caddy; with_global_lock run_mutation add-gateway cmd_add_gateway "$@" ;;
        set) shift; require_command caddy; with_global_lock run_mutation set cmd_set "$@" ;;
        rm|del|delete) shift; require_command caddy; with_global_lock run_mutation rm cmd_rm "${1:-}" ;;
        enable) shift; require_command caddy; with_global_lock run_mutation enable cmd_enable "${1:-}" ;;
        disable) shift; require_command caddy; with_global_lock run_mutation disable cmd_disable "${1:-}" ;;
        list|ls) cmd_list ;;
        email) shift; require_command caddy; with_global_lock run_mutation email cmd_email "${1:-}" ;;
        timeout) shift; with_global_lock run_mutation timeout cmd_timeout "${1:-}" ;;
        upstream-mode) shift; with_global_lock run_mutation upstream-mode cmd_upstream_mode "${1:-}" ;;
        import) shift; require_command caddy; with_global_lock run_mutation import cmd_import "${1:-}" ;;
        apply|reload) require_command caddy; with_global_lock run_mutation apply cmd_apply ;;
        validate|check) require_command caddy; cmd_validate ;;
        cert-check) shift; cmd_cert_check "${1:-}" ;;
        undo) shift; require_command caddy; with_global_lock cmd_undo "${1:-latest}" ;;
        status) cmd_status ;;
        logs) cmd_logs ;;
        config|cat) cmd_config ;;
        start) with_global_lock cmd_start ;;
        restart) with_global_lock cmd_restart ;;
        stop) with_global_lock cmd_stop ;;
        help|-h|--help) cmd_show_help ;;
        ""|menu) interactive_menu ;;
        *) _hook_cli_command "$@" && exit 0 ;&
        *) fail "未知命令: $cmd"; cmd_show_help; exit 1 ;;
    esac
}

