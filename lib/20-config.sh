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
    # Caddy < 2.7 doesn't support --envfile; source env inline
    local _caddy_ver
    _caddy_ver="$("$caddy_bin" version 2>/dev/null | sed -n 's/^v\?\([0-9]\{1,\}\)\.\([0-9]\{1,\}\).*/\1.\2/p' | head -1 || true)"
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
