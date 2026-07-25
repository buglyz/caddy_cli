# caddyctl library module: 20-config.sh
# shellcheck shell=bash
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

assert_live_config_owned() {
    local rendered

    [[ -s "$CADDYFILE" ]] || return 0
    rendered="$(mktemp)" || {
        fail "无法创建配置所有权检查临时文件"
        return 1
    }
    if ! render_caddyfile_to "$rendered"; then
        cleanup_paths "$rendered"
        fail "无法渲染 managed 配置，已拒绝覆盖 live Caddyfile"
        return 1
    fi
    if cmp -s "$CADDYFILE" "$rendered"; then
        cleanup_paths "$rendered"
        return 0
    fi

    cleanup_paths "$rendered"
    fail "live Caddyfile 与 sites.d/globals.d 的 managed 渲染不一致，已拒绝覆盖。"
    fail "可能存在 inline-only/未知站点或配置漂移；请先执行 c import --merge $CADDYFILE 完成显式迁移。"
    return 1
}

# Source Cloudflare (or other) env files so CLI validate sees the same vars as systemd EnvironmentFile.
# Safe no-op when files are missing. Prefer explicit hook path, then CADDYCTL_CLOUDFLARE_ENV, then default.
source_caddy_validate_env_files() {
    # Priority (first match wins): CADDYCTL_CLOUDFLARE_ENV → CLOUDFLARE_ENV_FILE (CF frontend) → default path.
    # Only one file is sourced so production /etc does not clobber explicit test/override paths.
    local f
    local -a candidates=()
    if [[ -n "${CADDYCTL_CLOUDFLARE_ENV:-}" ]]; then
        candidates+=("$CADDYCTL_CLOUDFLARE_ENV")
    fi
    if [[ -n "${CLOUDFLARE_ENV_FILE:-}" ]]; then
        candidates+=("$CLOUDFLARE_ENV_FILE")
    fi
    candidates+=("/etc/caddy/cloudflare.env")
    for f in "${candidates[@]}"; do
        [[ -n "$f" && -f "$f" && -r "$f" ]] || continue
        set -a
        # shellcheck disable=SC1090 # runtime env path
        source "$f" 2>/dev/null || true
        set +a
        return 0
    done
    return 0
}

validate_config_file() {
    local config_path="$1"
    local caddy_bin
    caddy_bin="$(caddy_binary)" || return 127
    if [[ -n "${LAST_VALIDATE_LOG:-}" ]]; then
        cleanup_paths "$LAST_VALIDATE_LOG"
    fi
    LAST_VALIDATE_LOG="$(mktemp /tmp/caddyctl-validate.XXXXXX)"
    local _validate_extra_args
    _validate_extra_args="$(_hook_validate_args)"
    # Always source env first: systemd EnvironmentFile is invisible to bare `caddy validate`.
    # Covers DNS-01 sites with {env.CLOUDFLARE_API_TOKEN} even when --envfile is unsupported/unused.
    source_caddy_validate_env_files
    # Caddy < 2.7 doesn't support --envfile; strip hook flag after sourcing above.
    local _caddy_ver
    _caddy_ver="$("$caddy_bin" version 2>/dev/null | sed -n 's/^v\?\([0-9]\{1,\}\)\.\([0-9]\{1,\}\).*/\1.\2/p' | head -1 || true)"
    if [[ -n "$_caddy_ver" ]] && caddy_supports_envfile "$_caddy_ver"; then
        :
    else
        if [[ "$_validate_extra_args" == *--envfile* ]]; then
            _validate_extra_args=""
        fi
    fi
    # shellcheck disable=SC2086
    "$caddy_bin" validate $_validate_extra_args --config "$config_path" --adapter caddyfile >"$LAST_VALIDATE_LOG" 2>&1
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
