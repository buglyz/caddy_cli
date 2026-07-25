# caddyctl library module: 40-lock-snapshot.sh
# shellcheck shell=bash
resolve_lock_file() {
    local candidate dir
    for candidate in "${LOCK_FILE_CANDIDATES[@]}"; do
        dir="$(dirname "$candidate")"
        prepare_lock_dir "$dir" || continue
        prepare_lock_file "$candidate" || continue
        LOCK_FILE="$candidate"
        return 0
    done
    fail "没有可用的安全锁路径"
    return 1
}

path_owned_by_effective_user() {
    local owner expected_owner
    owner="$(stat -c '%u' -- "$1" 2>/dev/null)" || return 1
    expected_owner="${EUID:-$(id -u)}"
    [[ "$owner" == "$expected_owner" ]]
}

prepare_lock_dir() {
    local dir="$1"
    local mode

    [[ ! -L "$dir" ]] || return 1
    if [[ ! -e "$dir" ]]; then
        (umask 077; mkdir -p -- "$dir") 2>/dev/null || return 1
    fi
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    path_owned_by_effective_user "$dir" || return 1
    mode="$(stat -c '%a' -- "$dir" 2>/dev/null)" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode="${mode: -3}"
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ -w "$dir" ]] || return 1
}

prepare_lock_file() {
    local path="$1"

    [[ ! -L "$path" ]] || return 1
    if [[ -e "$path" && ! -f "$path" ]]; then
        return 1
    fi
    if [[ ! -e "$path" ]]; then
        (umask 077; set -o noclobber; : >"$path") 2>/dev/null || true
    fi
    [[ -f "$path" && ! -L "$path" ]] || return 1
    path_owned_by_effective_user "$path" || return 1
    chmod 600 -- "$path" 2>/dev/null || return 1
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

    resolve_lock_file || return 1
    if ! { exec {fd}<>"$LOCK_FILE"; } 2>/dev/null; then
        fail "无法创建锁文件: $LOCK_FILE"
        return 1
    fi
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
    local snapshot_id snapshot_path staging created
    local state_present=0 caddyfile_present=0

    mkdir -p "$SNAPSHOT_DIR" || return 1
    snapshot_id="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    snapshot_path="$SNAPSHOT_DIR/$snapshot_id"
    staging="$(mktemp -d "$SNAPSHOT_DIR/.partial.XXXXXX")" || return 1
    mkdir -p "$staging/sites" "$staging/globals" || {
        cleanup_paths "$staging"
        return 1
    }

    if [[ -d "$SITES_DIR" ]] && ! cp -a "$SITES_DIR"/. "$staging/sites"/; then
        cleanup_paths "$staging"
        return 1
    fi
    if [[ -d "$GLOBALS_DIR" ]] && ! cp -a "$GLOBALS_DIR"/. "$staging/globals"/; then
        cleanup_paths "$staging"
        return 1
    fi
    if [[ -e "$STATE_FILE" ]]; then
        cp -a "$STATE_FILE" "$staging/state.conf" || {
            cleanup_paths "$staging"
            return 1
        }
        state_present=1
    fi
    if [[ -e "$CADDYFILE" ]]; then
        cp -a "$CADDYFILE" "$staging/Caddyfile" || {
            cleanup_paths "$staging"
            return 1
        }
        caddyfile_present=1
    fi

    created="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    if ! cat > "$staging/meta" <<EOF
ACTION=$action
CREATED_AT=$created
EOF
    then
        cleanup_paths "$staging"
        return 1
    fi
    if ! cat > "$staging/manifest" <<EOF
FORMAT=1
STATE_PRESENT=$state_present
CADDYFILE_PRESENT=$caddyfile_present
EOF
    then
        cleanup_paths "$staging"
        return 1
    fi

    if ! validate_snapshot "$staging"; then
        cleanup_paths "$staging"
        return 1
    fi

    if ! mv -- "$staging" "$snapshot_path"; then
        cleanup_paths "$staging"
        return 1
    fi

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
    local sites_stage globals_stage state_stage="" state_present
    local sites_old globals_old state_old
    local sites_swapped=0 globals_swapped=0 state_saved=0 commit_ok=1

    validate_snapshot "$snapshot_path" || return 1
    ensure_dirs
    sites_stage="$(mktemp -d "$(dirname "$SITES_DIR")/.caddyctl-sites.XXXXXX")" || return 1
    globals_stage="$(mktemp -d "$(dirname "$GLOBALS_DIR")/.caddyctl-globals.XXXXXX")" || {
        cleanup_paths "$sites_stage"
        return 1
    }
    state_present="$(snapshot_manifest_value "$snapshot_path" STATE_PRESENT)" || {
        cleanup_paths "$sites_stage" "$globals_stage"
        return 1
    }
    if ! cp -a "$snapshot_path/sites"/. "$sites_stage"/ \
        || ! cp -a "$snapshot_path/globals"/. "$globals_stage"/; then
        cleanup_paths "$sites_stage" "$globals_stage"
        return 1
    fi
    if [[ "$state_present" == "1" ]]; then
        state_stage="$(mktemp "$(dirname "$STATE_FILE")/.caddyctl-state.XXXXXX")" || {
            cleanup_paths "$sites_stage" "$globals_stage"
            return 1
        }
        if ! cp -a "$snapshot_path/state.conf" "$state_stage"; then
            cleanup_paths "$sites_stage" "$globals_stage" "$state_stage"
            return 1
        fi
    fi

    sites_old="${SITES_DIR}.restore-old.$$.$RANDOM"
    globals_old="${GLOBALS_DIR}.restore-old.$$.$RANDOM"
    state_old="${STATE_FILE}.restore-old.$$.$RANDOM"

    if mv -- "$SITES_DIR" "$sites_old" && mv -- "$sites_stage" "$SITES_DIR"; then
        sites_swapped=1
    else
        if [[ -d "$sites_old" && ! -e "$SITES_DIR" ]]; then
            mv -- "$sites_old" "$SITES_DIR" 2>/dev/null || true
        fi
        cleanup_paths "$sites_stage" "$globals_stage" "$state_stage"
        return 1
    fi
    if mv -- "$GLOBALS_DIR" "$globals_old" && mv -- "$globals_stage" "$GLOBALS_DIR"; then
        globals_swapped=1
    else
        commit_ok=0
        if [[ -d "$globals_old" && ! -e "$GLOBALS_DIR" ]]; then
            mv -- "$globals_old" "$GLOBALS_DIR" 2>/dev/null || true
        fi
    fi
    if (( commit_ok )) && mv -- "$STATE_FILE" "$state_old"; then
        state_saved=1
        if [[ "$state_present" == "0" ]] || mv -- "$state_stage" "$STATE_FILE"; then
            :
        else
            commit_ok=0
        fi
    else
        commit_ok=0
    fi

    if (( ! commit_ok )); then
        if (( state_saved )); then
            cleanup_paths "$STATE_FILE"
            mv -- "$state_old" "$STATE_FILE" 2>/dev/null || true
        fi
        if (( globals_swapped )); then
            cleanup_paths "$GLOBALS_DIR"
            mv -- "$globals_old" "$GLOBALS_DIR" 2>/dev/null || true
        fi
        if (( sites_swapped )); then
            cleanup_paths "$SITES_DIR"
            mv -- "$sites_old" "$SITES_DIR" 2>/dev/null || true
        fi
        cleanup_paths "$sites_stage" "$globals_stage" "$state_stage"
        return 1
    fi

    cleanup_paths "$sites_old" "$globals_old" "$state_old" "$state_stage"

    load_state
    fix_permissions
}

snapshot_manifest_value() {
    local snapshot_path="$1"
    local key="$2"
    local value

    if [[ ! -f "$snapshot_path/manifest" ]]; then
        case "$key" in
            STATE_PRESENT) printf '%s' '1' ;;
            CADDYFILE_PRESENT) [[ -f "$snapshot_path/Caddyfile" ]] && printf '%s' '1' || printf '%s' '0' ;;
            *) return 1 ;;
        esac
        return 0
    fi

    value="$(awk -F= -v key="$key" '$1 == key { print $2; exit }' "$snapshot_path/manifest" 2>/dev/null)"
    [[ "$value" == "0" || "$value" == "1" ]] || return 1
    printf '%s' "$value"
}

validate_snapshot() {
    local snapshot_path="$1"
    local state_present caddyfile_present

    [[ -d "$snapshot_path" && ! -L "$snapshot_path" ]] || return 1
    [[ "$snapshot_path" == "$SNAPSHOT_DIR/"* ]] || return 1
    [[ -d "$snapshot_path/sites" && ! -L "$snapshot_path/sites" ]] || return 1
    [[ -d "$snapshot_path/globals" && ! -L "$snapshot_path/globals" ]] || return 1
    [[ -f "$snapshot_path/meta" && ! -L "$snapshot_path/meta" ]] || return 1
    if [[ -e "$snapshot_path/manifest" ]]; then
        [[ -f "$snapshot_path/manifest" && ! -L "$snapshot_path/manifest" ]] || return 1
        grep -Fxq 'FORMAT=1' "$snapshot_path/manifest" || return 1
    else
        # Legacy snapshots always contain state.conf because ensure_dirs runs before mutations.
        [[ -f "$snapshot_path/state.conf" && ! -L "$snapshot_path/state.conf" ]] || return 1
    fi
    state_present="$(snapshot_manifest_value "$snapshot_path" STATE_PRESENT)" || return 1
    caddyfile_present="$(snapshot_manifest_value "$snapshot_path" CADDYFILE_PRESENT)" || return 1
    [[ "$state_present" == "0" || ( -f "$snapshot_path/state.conf" && ! -L "$snapshot_path/state.conf" ) ]] || return 1
    [[ "$caddyfile_present" == "0" || ( -f "$snapshot_path/Caddyfile" && ! -L "$snapshot_path/Caddyfile" ) ]] || return 1
}

run_mutation() {
    local action="$1"
    local snapshot_path rc
    shift

    case "$action" in
        import|import-merge) ;;
        *) assert_live_config_owned || return 1 ;;
    esac

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
