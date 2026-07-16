# caddyctl library module: 40-lock-snapshot.sh
# shellcheck shell=bash
resolve_lock_file() {
    local candidate dir probe
    for candidate in "${LOCK_FILE_CANDIDATES[@]}"; do
        dir="$(dirname "$candidate")"
        if mkdir -p "$dir" 2>/dev/null; then
            probe="$dir/.caddyctl-lock-write-test.$$"
            if ( : >"$probe" ) 2>/dev/null; then
                rm -f "$probe" 2>/dev/null || true
                LOCK_FILE="$candidate"
                return 0
            fi
        fi
    done
    LOCK_FILE="/tmp/caddyctl.lock"
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
}

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

    resolve_lock_file
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
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

cmd_snapshots() {
    local limit="${1:-20}"
    local snapshot meta action created total shown
    local -a snapshots=()

    if [[ "$limit" == "all" ]]; then
        limit="0"
    elif [[ ! "$limit" =~ ^[0-9]+$ ]]; then
        fail "快照数量必须是整数或 all"
        return 1
    fi

    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        say "暂无回滚快照"
        return 0
    fi

    mapfile -t snapshots < <(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
    total="${#snapshots[@]}"
    if (( total == 0 )); then
        say "暂无回滚快照"
        return 0
    fi

    printf '%-34s  %-18s  %s\n' "快照ID" "操作" "创建时间"
    printf '%-34s  %-18s  %s\n' "----------------------------------" "------------------" "-------------------"

    shown=0
    for snapshot in "${snapshots[@]}"; do
        if (( limit > 0 && shown >= limit )); then
            break
        fi

        action="unknown"
        created="unknown"
        meta="$snapshot/meta"
        if [[ -f "$meta" ]]; then
            action="$(awk -F= '$1 == "ACTION" { print substr($0, index($0, "=") + 1); exit }' "$meta")"
            created="$(awk -F= '$1 == "CREATED_AT" { print substr($0, index($0, "=") + 1); exit }' "$meta")"
            action="${action:-unknown}"
            created="${created:-unknown}"
        fi

        printf '%-34s  %-18s  %s\n' "$(basename "$snapshot")" "$action" "$created"
        shown=$((shown + 1))
    done

    if (( limit > 0 && total > shown )); then
        say "... 还有 $((total - shown)) 个快照未显示，使用: c snapshots all"
    fi
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
