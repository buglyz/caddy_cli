#!/usr/bin/env bash
set -euo pipefail

# Clean up on exit: remove validate log + release lock if held
trap 'cleanup_paths "${LAST_VALIDATE_LOG:-}"; [[ -n "${_LOCK_FD:-}" ]] && { flock -u "$_LOCK_FD" 2>/dev/null || true; exec {_LOCK_FD}>&- || true; }' EXIT

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
ACCESS_LOG_ROLL_SIZE="20MiB"
ACCESS_LOG_ROLL_KEEP="10"
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
_hook_validate_args() { printf '%s' ''; }

say() {
    echo "$*"
}

fail() {
    echo "错误: $*" >&2
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
    [[ -z "$1" ]] && return 0
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
        if [[ -n "${EMAIL:-}" ]]; then
            have_global=1
        fi
        if compgen -G "$GLOBALS_DIR/*.inc" >/dev/null 2>&1; then
            have_global=1
        fi

        if (( have_global )); then
            echo "{"
            if [[ -n "${EMAIL:-}" ]]; then
                echo "    email ${EMAIL}"
            fi
            _hook_render_global_options

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
    LAST_VALIDATE_LOG="$(mktemp /tmp/caddyctl-validate.XXXXXX.log)"
    local _validate_extra_args
    _validate_extra_args="$(_hook_validate_args)"
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
    command_exists systemctl
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
    if ! flock -w "$wait_seconds" "$fd"; then
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

run_systemctl_with_timeout() {
    local timeout_seconds action rc
    timeout_seconds="$(get_systemctl_timeout_seconds)"
    action="${1:-systemctl}"

    if command_exists timeout; then
        if timeout --foreground "${timeout_seconds}s" systemctl "$@"; then
            return 0
        fi
        rc=$?
        if (( rc == 124 )); then
            fail "systemctl $action 超时（${timeout_seconds}s）"
        else
            fail "systemctl $action 执行失败"
        fi
        return "$rc"
    fi

    systemctl "$@"
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
            say "[OK] 127.0.0.1:$port 正在监听"
        elif (( rc == 2 )); then
            say "[WARN] 无法检查端口 $port（缺少 ss/netstat）"
            ((unknown++))
        else
            say "[WARN] 127.0.0.1:$port 未监听"
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
        say "未检测到 systemctl，配置已写入 $CADDYFILE，请手动重载 Caddy。"
        return 0
    fi

    if systemctl is-active --quiet caddy; then
        say "正在重载 Caddy 服务..."
        run_systemctl_with_timeout reload caddy
        say "已重载 Caddy"
    else
        say "Caddy 未运行，正在启动..."
        run_systemctl_with_timeout start caddy
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
            run_systemctl_with_timeout restart caddy || true
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

emit_security_headers() {
    cat <<'EOF'
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "accelerometer=(), ambient-light-sensor=(), autoplay=(), browsing-topics=(), camera=(), clipboard-read=(), clipboard-write=(), geolocation=(), gyroscope=(), hid=(), microphone=(), payment=(), usb=()"
    }
EOF
}

emit_access_log_block() {
    local primary="$1"
    cat <<EOF
    log {
        output file $ACCESS_LOG_DIR/$(sanitize_name "$primary").log {
            roll_size $ACCESS_LOG_ROLL_SIZE
            roll_keep $ACCESS_LOG_ROLL_KEEP
            roll_keep_for $ACCESS_LOG_ROLL_KEEP_FOR
        }
        format console
    }
EOF
}

emit_site_common_blocks() {
    local primary="$1"
    local access_log="$2"

    cat <<'EOF'
    encode zstd gzip
EOF
    emit_security_headers
    if [[ "$access_log" == "on" ]]; then
        emit_access_log_block "$primary"
    fi
}

emit_www_redirect_block() {
    local primary="$1"
    local scheme="$2"
    cat <<EOF
www.$primary {
    redir ${scheme}://$primary{uri} 308
}

EOF
}

build_reverse_proxy_site_block() {
    local label="$1"
    local port="$2"
    local scheme="$3"
    local www_mode="$4"
    local access_log="$5"
    local primary
    primary="$(get_primary_label "$label")"

    if [[ "$www_mode" == "on" && "$primary" != www.* ]]; then
        emit_www_redirect_block "$primary" "https"
    fi

    cat <<EOF
$label {
EOF
    emit_site_common_blocks "$primary" "$access_log"
    if [[ "$scheme" == "http" ]]; then
        cat <<EOF
    reverse_proxy http://127.0.0.1:$port
}
EOF
    else
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
    local www_mode="$5"
    local access_log="$6"
    local primary matcher_name
    primary="$(get_primary_label "$label")"
    matcher_name="@path_$(sanitize_name "$primary")_$(sanitize_name "$path_prefix")"

    if [[ "$www_mode" == "on" && "$primary" != www.* ]]; then
        emit_www_redirect_block "$primary" "https"
    fi

    cat <<EOF
$label {
EOF
    emit_site_common_blocks "$primary" "$access_log"
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
    local www_mode="$3"
    local access_log="$4"
    local spa_mode="$5"
    local primary
    primary="$(get_primary_label "$label")"

    if [[ "$www_mode" == "on" && "$primary" != www.* ]]; then
        emit_www_redirect_block "$primary" "https"
    fi

    cat <<EOF
$label {
EOF
    emit_site_common_blocks "$primary" "$access_log"
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

cmd_add() {
    local label="${1:-}"
    local port="${2:-}"
    local scheme="https"
    local www_mode="off"
    local access_log="off"
    local path_prefix=""

    shift $(( $# > 2 ? 2 : $# ))

    while (( $# > 0 )); do
        case "$1" in
            --http) scheme="http" ;;
            --https) scheme="https" ;;
            --www) www_mode="on" ;;
            --log) access_log="on" ;;
            --path)
                shift
                [[ $# -gt 0 ]] || { fail "--path 需要一个前缀"; return 1; }
                path_prefix="$1"
                ;;
            *) fail "未知 add 参数: $1"; return 1 ;;
        esac
        shift
    done

    if [[ -z "$label" ]]; then
        read -rp "站点地址（如 example.com 或 example.com, api.example.com）: " label
    fi
    if [[ -z "$port" ]]; then
        read -rp "本地端口: " port
    fi

    label="$(trim "$label")"
    path_prefix="$(trim "$path_prefix")"

    if [[ "$www_mode" == "off" ]] && prompt_yes_no "是否自动把 www 跳转到主域名？"; then
        www_mode="on"
    fi
    if [[ "$access_log" == "off" ]] && prompt_yes_no "是否为该站点开启访问日志？"; then
        access_log="on"
    fi

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

    if [[ -n "$path_prefix" ]]; then
        build_path_proxy_site_block "$label" "$port" "$path_prefix" "$scheme" "$www_mode" "$access_log" > "$file"
    else
        build_reverse_proxy_site_block "$label" "$port" "$scheme" "$www_mode" "$access_log" > "$file"
    fi

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
    local label="${1:-}"
    local site_dir="${2:-}"
    local www_mode="off"
    local access_log="off"
    local spa_mode="off"

    shift $(( $# > 2 ? 2 : $# ))

    while (( $# > 0 )); do
        case "$1" in
            --www) www_mode="on" ;;
            --log) access_log="on" ;;
            --spa) spa_mode="on" ;;
            *) fail "未知 add-static 参数: $1"; return 1 ;;
        esac
        shift
    done

    if [[ -z "$label" ]]; then
        read -rp "站点地址（如 static.example.com）: " label
    fi
    if [[ -z "$site_dir" ]]; then
        read -rp "静态目录路径: " site_dir
    fi

    label="$(trim "$label")"
    site_dir="$(trim "$site_dir")"

    if [[ "$www_mode" == "off" ]] && prompt_yes_no "是否自动把 www 跳转到主域名？"; then
        www_mode="on"
    fi
    if [[ "$access_log" == "off" ]] && prompt_yes_no "是否为该站点开启访问日志？"; then
        access_log="on"
    fi
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

    build_static_site_block "$label" "$site_dir" "$www_mode" "$access_log" "$spa_mode" > "$file"

    if ! write_site_file_with_rollback "$file" "$oldbak"; then
        fail "已回滚站点修改"
        return 1
    fi

    say "已添加静态站点: $label -> $site_dir"
    if [[ ! -d "$site_dir" ]]; then
        say "注意: 当前目录不存在，后续创建后即可由 Caddy 提供访问。"
    fi
}

cmd_set() {
    local query="${1:-}"
    local override_port=""
    local override_path="__keep__"
    local override_scheme=""
    local override_www=""
    local override_log=""

    shift $(( $# > 0 ? 1 : 0 ))

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
            --http) override_scheme="http" ;;
            --https) override_scheme="https" ;;
            --www) override_www="on" ;;
            --no-www) override_www="off" ;;
            --log) override_log="on" ;;
            --no-log) override_log="off" ;;
            *) fail "未知 set 参数: $1"; return 1 ;;
        esac
        shift
    done

    if [[ -z "$query" ]]; then
        read -rp "输入要编辑的站点地址: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点地址不能为空"
        return 1
    fi

    local file site_type label target path_prefix scheme www_mode access_log
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi

    site_type="$(detect_site_type "$file")"
    if [[ "$site_type" == "静态站点" ]]; then
        fail "当前仅支持编辑反代站点与路径反代站点，静态站点请使用 add-static 重新配置。"
        return 1
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
    www_mode="off"
    access_log="off"
    if grep -Eq '^www\.[^[:space:]]+[[:space:]]*\{' "$file"; then
        www_mode="on"
    fi
    if grep -Eq '^[[:space:]]*log[[:space:]]*\{' "$file"; then
        access_log="on"
    fi

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
    if [[ -n "$override_www" ]]; then
        www_mode="$override_www"
    fi
    if [[ -n "$override_log" ]]; then
        access_log="$override_log"
    fi

    local oldbak tmp
    oldbak="$(backup_file_if_exists "$file")"
    tmp="$(mktemp)"

    if [[ -n "$path_prefix" ]]; then
        build_path_proxy_site_block "$label" "$TARGET_PORT" "$path_prefix" "$scheme" "$www_mode" "$access_log" > "$tmp"
    else
        build_reverse_proxy_site_block "$label" "$TARGET_PORT" "$scheme" "$www_mode" "$access_log" > "$tmp"
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
    if grep -Eq '^[[:space:]]*file_server([[:space:]]|$)' "$file"; then
        echo "静态站点"
    elif grep -Eq '^[[:space:]]*@path_.* path ' "$file" && grep -Eq '^[[:space:]]*uri strip_prefix ' "$file"; then
        echo "路径反代"
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
            echo "$(site_summary "$f")"
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
            echo "$(site_summary "$f")"
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
        say "当前 systemctl 超时: ${effective_timeout}s（持久配置: ${SYSTEMCTL_TIMEOUT_SECONDS}s）"
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
    say "已设置 systemctl 超时: ${SYSTEMCTL_TIMEOUT_SECONDS}s"
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
    require_command systemctl
    systemctl status caddy --no-pager
}

cmd_logs() {
    require_command journalctl
    journalctl -u caddy -n 120 --no-pager
}

cmd_start() {
    require_command systemctl
    run_systemctl_with_timeout start caddy
}

cmd_restart() {
    require_command systemctl
    run_systemctl_with_timeout restart caddy
}

cmd_stop() {
    require_command systemctl
    run_systemctl_with_timeout stop caddy
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
    else
        echo "[WARN] 缺少 journalctl，跳过日志诊断"
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
        if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
            echo "[OK] 检测到 caddy.service"
        else
            echo "[WARN] 未检测到 caddy.service"
        fi

        if systemctl is-active --quiet caddy; then
            echo "[OK] Caddy 正在运行"
        else
            echo "[WARN] Caddy 未运行"
        fi
    else
        echo "[WARN] 未检测到 systemctl"
    fi
    echo "[INFO] systemctl 超时: $(get_systemctl_timeout_seconds)s（持久配置: ${SYSTEMCTL_TIMEOUT_SECONDS}s）"
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

    install -Dm755 "$src" "$target_bin"
    ln -sf "$target_bin" "$target_alias"

    say "已安装脚本命令:"
    say "  $target_bin"
    say "  $target_alias -> $target_bin"
    say "现在可以直接运行: c"
}

cmd_update() {
    require_command curl
    require_command bash

    local url tmp target_bin target_alias
    url="${CADDYCTL_UPDATE_URL:-$DEFAULT_UPDATE_URL}"
    target_bin="/usr/local/bin/caddyctl"
    target_alias="/usr/local/bin/c"
    tmp="$(mktemp)"

    say "正在下载最新脚本: $url"
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

    install -Dm755 "$tmp" "$target_bin"
    ln -sf "$target_bin" "$target_alias"
    cleanup_paths "$tmp"

    say "更新完成:"
    say "  $target_bin"
    say "  $target_alias -> $target_bin"
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
        systemctl enable caddy >/dev/null 2>&1 || true
        if has_any_config; then
            apply_config
        else
            run_systemctl_with_timeout start caddy || true
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
  c add <域名> <本地端口> [--www] [--log] [--http]
  c add <域名> <本地端口> --path <前缀> [--www] [--log] [--http]
  c add-static <域名> <目录> [--www] [--log] [--spa]
  c set <域名> [--port <端口>] [--path <前缀|none>] [--http|--https] [--www|--no-www] [--log|--no-log]
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
  c

示例:
  c add example.com 3000 --www --log
  c add example.com 3000 --path /api --log
  c add-static static.example.com /var/www/site --www
  c update
  c set example.com --port 4000 --no-log
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
    echo "3. 删除站点"
    echo "4. 启用站点"
    echo "5. 禁用站点"
    echo "6. 查看站点列表"
    echo "7. 编辑站点"
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
    echo "7. 设置 systemctl 超时"
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
            3) require_command caddy; with_global_lock run_mutation rm cmd_rm ;;
            4) require_command caddy; with_global_lock run_mutation enable cmd_enable ;;
            5) require_command caddy; with_global_lock run_mutation disable cmd_disable ;;
            6) cmd_list ;;
            7) require_command caddy; with_global_lock run_mutation set cmd_set ;;
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

