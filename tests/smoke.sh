#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$repo_root/caddy-lib.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

CADDYFILE="$tmpdir/Caddyfile"
SITES_DIR="$tmpdir/sites.d"
GLOBALS_DIR="$tmpdir/globals.d"
# shellcheck disable=SC2034 # consumed by sourced state helpers
STATE_FILE="$tmpdir/caddyctl.conf"
BACKUP_DIR="$tmpdir/backup"
SNAPSHOT_DIR="$BACKUP_DIR/snapshots"
# shellcheck disable=SC2034 # consumed by sourced directory helpers
ACCESS_LOG_DIR="$tmpdir/log"
LOCK_FILE="$tmpdir/caddyctl.lock"
LOCK_FILE_CANDIDATES=("$LOCK_FILE")

fail_test() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_file_missing() {
    local path="$1"
    [[ ! -e "$path" ]] || fail_test "expected file to be absent: $path"
}

assert_file_equals() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(cat "$path")"
    [[ "$actual" == "$expected" ]] || fail_test "unexpected file content: $path"
}

apply_config() {
    return "${APPLY_CONFIG_STATUS:-1}"
}

test_add_emby_propagates_apply_failure() {
    local file="$SITES_DIR/emby_example_com.conf"

    if cmd_add_emby emby.example.com https://upstream.example.com:443 --skip-dns-check >/dev/null 2>&1; then
        fail_test "cmd_add_emby succeeded despite apply_config failure"
    fi

    assert_file_missing "$file"
}

test_add_gateway_propagates_apply_failure() {
    local file="$SITES_DIR/gate_example_com.conf"

    if cmd_add_gateway gate.example.com --allow upstream.example.com:443 --skip-dns-check >/dev/null 2>&1; then
        fail_test "cmd_add_gateway succeeded despite apply_config failure"
    fi

    assert_file_missing "$file"
}

test_set_emby_restores_previous_file_on_apply_failure() {
    local file="$SITES_DIR/emby_example_com.conf"
    local original

    ensure_dirs
    original="$(build_emby_site_block "emby.example.com" "https://old.example.com:443" "https")"
    printf '%s\n' "$original" > "$file"

    if cmd_set_emby_file "$file" "Emby反代" "" "emby.example.com" "https://new.example.com:443" "" >/dev/null 2>&1; then
        fail_test "cmd_set_emby_file succeeded despite apply_config failure"
    fi

    assert_file_equals "$file" "$original"
}

test_cmd_set_routes_emby_sites_to_file_updater() {
    local file="$SITES_DIR/emby_example_com.conf"
    local original

    ensure_dirs
    original="$(build_emby_site_block "emby.example.com" "https://old.example.com:443" "https")"
    printf '%s\n' "$original" > "$file"

    if cmd_set emby.example.com --target https://new.example.com:443 >/dev/null 2>&1; then
        fail_test "cmd_set succeeded despite apply_config failure"
    fi

    assert_file_equals "$file" "$original"
}

test_add_static_supports_http_mode() {
    local file
    local expected_prefix="http://static.example.com {"

    APPLY_CONFIG_STATUS=0 cmd_add_static static.example.com /srv/www --http --skip-dns-check >/dev/null 2>&1

    file="$(site_path_for_label static.example.com)"
    IFS= read -r first_line < "$file"
    [[ "$first_line" == "$expected_prefix" ]] || fail_test "static site did not use HTTP site label"
    ! grep -q 'tls {' "$file" || fail_test "static HTTP site unexpectedly emitted TLS block"
    APPLY_CONFIG_STATUS=1
}

test_reverse_proxy_builders_support_http_mode() {
    local config

    config="$(build_reverse_proxy_site_block app.example.com 3000 http)"
    grep -Fq 'http://app.example.com {' <<<"$config" || fail_test "reverse proxy HTTP site did not use http:// label"
    ! grep -q 'tls {' <<<"$config" || fail_test "reverse proxy HTTP site unexpectedly emitted TLS block"

    config="$(build_reverse_proxy_site_block "app.example.com, api.example.com" 3000 http)"
    grep -Fq 'http://app.example.com, http://api.example.com {' <<<"$config" || fail_test "reverse proxy HTTP site did not prefix every label"

    config="$(build_path_proxy_site_block app.example.com 3000 /api http)"
    grep -Fq 'http://app.example.com {' <<<"$config" || fail_test "path proxy HTTP site did not use http:// label"
    ! grep -q 'tls {' <<<"$config" || fail_test "path proxy HTTP site unexpectedly emitted TLS block"

    config="$(build_static_site_block "static.example.com, cdn.example.com" /srv/www off http)"
    grep -Fq 'http://static.example.com, http://cdn.example.com {' <<<"$config" || fail_test "static HTTP site did not prefix every label"
}

test_http_multi_label_matching_is_scheme_aware() {
    local label="multi.example.com, api.example.com"
    local file found repeat_path

    APPLY_CONFIG_STATUS=0 cmd_add "$label" 3000 --http --skip-dns-check >/dev/null 2>&1

    file="$SITES_DIR/multi.example.com__api.example.com.conf"
    [[ -s "$file" ]] || fail_test "HTTP multi-label site file was not created"
    grep -Fq 'http://multi.example.com, http://api.example.com {' "$file" || fail_test "HTTP multi-label site did not prefix every label"

    found="$(find_site_file "multi.example.com,api.example.com")"
    [[ "$found" == "$file" ]] || fail_test "scheme-aware lookup did not find HTTP multi-label site"

    repeat_path="$(site_path_for_label "$label")"
    [[ "$repeat_path" == "$file" ]] || fail_test "site_path_for_label would create duplicate HTTP multi-label file"

    APPLY_CONFIG_STATUS=1
}

test_gateway_uses_full_url_proxy_paths() {
    local config

    config="$(build_gateway_site_block gate.example.com https "x" "emby.example.com:443")"

    grep -Fq 'https://gate.example.com/https://<上游主机:端口>/路径' <<<"$config" || fail_test "gateway help did not use full URL format"
    # shellcheck disable=SC2016 # match literal Caddy placeholder rewrite output
    grep -Fq 'header_down Location ^https://([^/]+)(/.*)$ https://gate.example.com/https://$1$2' <<<"$config" || fail_test "gateway Location rewrite did not use full HTTPS URL format"
    grep -Fq '@httpsProxy0 path_regexp up_https_0 ^/https:/*emby\.example\.com:443(/.*)' <<<"$config" || fail_test "gateway allowed route did not match /https://source"
    ! grep -Fq 'https://gate.example.com/https/emby.example.com' <<<"$config" || fail_test "gateway emitted legacy /https/source path"
}


test_emby_and_gateway_emit_tls_hook_on_https() {
    # Mimic caddy-cloudflare: only emit dns tls when FORCE_DNS_TLS=1
    # shellcheck disable=SC2317 # hook is invoked indirectly by site builders
    _hook_render_site_tls() {
        if [[ "${FORCE_DNS_TLS:-0}" == "1" ]]; then
            cat <<'EOF'
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
EOF
        fi
    }

    local config
    # default: no dns tls
    config="$(build_emby_site_block emby.example.com https://upstream.example.com:443 https)"
    ! grep -Fq 'dns cloudflare' <<<"$config" || fail_test "emby HTTPS default unexpectedly forced DNS-01"
    ! grep -Fq 'encode zstd gzip' <<<"$config" || fail_test "emby site unexpectedly emitted encode"

    config="$(with_dns_tls_flag 1 build_emby_site_block emby.example.com https://upstream.example.com:443 https)"
    grep -Fq 'dns cloudflare' <<<"$config" || fail_test "emby HTTPS --dns-only missing cloudflare tls"

    config="$(build_emby_site_block emby.example.com http://upstream.example.com:8096 http)"
    ! grep -Fq 'tls {' <<<"$config" || fail_test "emby HTTP site unexpectedly emitted TLS hook"

    config="$(with_dns_tls_flag 1 build_gateway_site_block gate.example.com https "x" "emby.example.com:443")"
    grep -Fq 'dns cloudflare' <<<"$config" || fail_test "gateway HTTPS --dns-only missing TLS hook"
    grep -Fq 'request_body' <<<"$config" || fail_test "gateway HTTPS site missing request_body"

    config="$(build_gateway_site_block gate.example.com http "x" "emby.example.com:443")"
    ! grep -Fq 'tls {' <<<"$config" || fail_test "gateway HTTP site unexpectedly emitted TLS hook"

    config="$(with_dns_tls_flag 1 build_reverse_proxy_site_block app.example.com 3000 https)"
    grep -Fq 'dns cloudflare' <<<"$config" || fail_test "reverse proxy --dns-only missing tls"
    config="$(with_dns_tls_flag 1 build_static_site_block static.example.com /srv/www off https)"
    grep -Fq 'dns cloudflare' <<<"$config" || fail_test "static --dns-only missing tls"

    # shellcheck disable=SC2317 # hook is invoked indirectly by site builders
    _hook_render_site_tls() { :; }
}

test_set_preserves_dns_tls_from_existing_file() {
    # shellcheck disable=SC2317 # hook is invoked indirectly by site builders
    _hook_render_site_tls() {
        if [[ "${FORCE_DNS_TLS:-0}" == "1" ]]; then
            cat <<'EOF'
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
EOF
        fi
    }

    local file="$SITES_DIR/a.example.com.conf"
    ensure_dirs
    cat > "$file" <<'EOF'
a.example.com {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000
}
EOF

    APPLY_CONFIG_STATUS=0
    cmd_set a.example.com --port 4000 >/dev/null 2>&1 || fail_test "cmd_set failed"
    APPLY_CONFIG_STATUS=1

    grep -Fq 'reverse_proxy 127.0.0.1:4000' "$file" || fail_test "cmd_set did not update port"
    grep -Fq 'dns cloudflare' "$file" || fail_test "cmd_set dropped existing DNS-01 tls block"

    # HTTP mode should drop dns tls
    APPLY_CONFIG_STATUS=0
    cmd_set a.example.com --http >/dev/null 2>&1 || fail_test "cmd_set --http failed"
    APPLY_CONFIG_STATUS=1
    ! grep -Fq 'dns cloudflare' "$file" || fail_test "cmd_set --http kept DNS-01 tls"

    # explicit --dns-only re-adds
    APPLY_CONFIG_STATUS=0
    cmd_set a.example.com --https --dns-only >/dev/null 2>&1 || fail_test "cmd_set --dns-only failed"
    APPLY_CONFIG_STATUS=1
    grep -Fq 'dns cloudflare' "$file" || fail_test "cmd_set --dns-only did not inject tls"

    _hook_render_site_tls() { :; }
}

test_resolve_dns_tls_flag_logic() {
    local f="$SITES_DIR/dnsflag.example.com.conf"
    ensure_dirs
    printf '%s
' 'x.example.com { reverse_proxy 127.0.0.1:1 }' > "$f"
    [[ "$(resolve_dns_tls_flag 0 https "$f")" == "0" ]] || fail_test "expected 0 without existing dns"
    printf '%s
' 'x.example.com { tls { dns cloudflare {env.CLOUDFLARE_API_TOKEN} } }' > "$f"
    [[ "$(resolve_dns_tls_flag 0 https "$f")" == "1" ]] || fail_test "expected preserve existing dns"
    [[ "$(resolve_dns_tls_flag 1 http "$f")" == "0" ]] || fail_test "http should force 0"
    [[ "$(resolve_dns_tls_flag 1 https "")" == "1" ]] || fail_test "explicit force should be 1"
}


test_resolve_lock_file_prefers_writable_dir() {
    local old_candidates=("${LOCK_FILE_CANDIDATES[@]}")
    local old_lock="$LOCK_FILE"
    local base="$tmpdir/locks"
    mkdir -p "$base/ok"
    # A regular file cannot host a lock subdirectory — mkdir -p should fail.
    : >"$base/notdir"
    LOCK_FILE_CANDIDATES=("$base/notdir/caddyctl.lock" "$base/ok/caddyctl.lock")
    resolve_lock_file
    [[ "$LOCK_FILE" == "$base/ok/caddyctl.lock" ]] \
        || fail_test "resolve_lock_file did not pick writable path: $LOCK_FILE"
    LOCK_FILE_CANDIDATES=("${old_candidates[@]}")
    LOCK_FILE="$old_lock"
}

test_inline_only_live_config_blocks_mutation() {
    local managed="$SITES_DIR/managed.example.com.conf"
    local before snapshot_count

    ensure_dirs
    mkdir -p "$SNAPSHOT_DIR"
    clear_managed_dir "$SITES_DIR"
    clear_managed_dir "$GLOBALS_DIR"
    printf '%s\n' 'managed.example.com {' '    reverse_proxy 127.0.0.1:8080' '}' >"$managed"
    render_caddyfile_to "$CADDYFILE"
    run_mutation managed-layout true >/dev/null 2>&1 \
        || fail_test "normal managed layout was rejected"
    printf '%s\n' 'inline-only.example.com {' '    reverse_proxy 127.0.0.1:9090' '}' >>"$CADDYFILE"
    run_mutation import true >/dev/null 2>&1 \
        || fail_test "explicit import migration was rejected"
    before="$(cat "$CADDYFILE")"
    snapshot_count="$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"

    if run_mutation add true >/dev/null 2>&1; then
        fail_test "inline-only live config did not block mutation"
    fi
    assert_file_equals "$CADDYFILE" "$before"
    [[ "$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)" == "$snapshot_count" ]] \
        || fail_test "blocked mutation created a snapshot"
}

test_symlink_lock_does_not_truncate_target() {
    local old_candidates=("${LOCK_FILE_CANDIDATES[@]}")
    local old_lock="$LOCK_FILE"
    local lock_dir="$tmpdir/symlink-lock" target="$tmpdir/lock-target"

    mkdir -p "$lock_dir"
    printf '%s' 'keep-this-content' >"$target"
    ln -s "$target" "$lock_dir/caddyctl.lock"
    LOCK_FILE_CANDIDATES=("$lock_dir/caddyctl.lock")
    if with_global_lock true >/dev/null 2>&1; then
        fail_test "symlink lock path was accepted"
    fi
    assert_file_equals "$target" 'keep-this-content'
    LOCK_FILE_CANDIDATES=("${old_candidates[@]}")
    LOCK_FILE="$old_lock"
}

test_incomplete_snapshot_preserves_live_config() {
    local incomplete="$SNAPSHOT_DIR/incomplete"
    local live_site="$SITES_DIR/live.example.com.conf"

    ensure_dirs
    clear_managed_dir "$SITES_DIR"
    printf '%s\n' 'live.example.com {' '    reverse_proxy 127.0.0.1:7070' '}' >"$live_site"
    mkdir -p "$incomplete/sites" "$incomplete/globals"
    printf '%s\n' 'ACTION=broken' >"$incomplete/meta"

    if restore_snapshot_contents "$incomplete" >/dev/null 2>&1; then
        fail_test "incomplete snapshot was accepted"
    fi
    assert_file_equals "$live_site" $'live.example.com {\n    reverse_proxy 127.0.0.1:7070\n}'
}

test_snapshot_copy_failure_preserves_live_config() {
    local live_site="$SITES_DIR/copy-failure.example.com.conf"
    local snapshot

    ensure_dirs
    clear_managed_dir "$SITES_DIR"
    clear_managed_dir "$GLOBALS_DIR"
    printf '%s\n' 'copy-failure.example.com {' '    respond "snapshot"' '}' >"$live_site"
    render_caddyfile_to "$CADDYFILE"
    snapshot="$(create_snapshot copy-failure)" || fail_test "could not create copy-failure snapshot"
    printf '%s\n' 'copy-failure.example.com {' '    respond "live"' '}' >"$live_site"

    # shellcheck disable=SC2317 # cp is invoked indirectly by restore_snapshot_contents
    if (cp() { return 1; }; restore_snapshot_contents "$snapshot") >/dev/null 2>&1; then
        fail_test "snapshot restore ignored copy failure"
    fi
    assert_file_equals "$live_site" $'copy-failure.example.com {\n    respond "live"\n}'
}

test_legacy_snapshot_remains_restorable() {
    local legacy="$SNAPSHOT_DIR/legacy"
    local live_site="$SITES_DIR/legacy.example.com.conf"

    ensure_dirs
    clear_managed_dir "$SITES_DIR"
    clear_managed_dir "$GLOBALS_DIR"
    mkdir -p "$legacy/sites" "$legacy/globals"
    printf '%s\n' 'ACTION=legacy' 'CREATED_AT=unknown' >"$legacy/meta"
    cp -a "$STATE_FILE" "$legacy/state.conf"
    printf '%s\n' 'legacy.example.com {' '    respond "snapshot"' '}' >"$legacy/sites/legacy.example.com.conf"
    printf '%s\n' 'legacy.example.com {' '    respond "live"' '}' >"$live_site"

    restore_snapshot_contents "$legacy" >/dev/null 2>&1 \
        || fail_test "valid legacy snapshot was rejected"
    assert_file_equals "$live_site" $'legacy.example.com {\n    respond "snapshot"\n}'
}


test_modules_array_safe_under_set_u() {
    # cmd_update must not crash when _CADDYCTL_MODULES is unset under set -u
    bash -c 'set -euo pipefail
      source "'"$repo_root"'/caddy-lib.sh"
      unset _CADDYCTL_MODULES || true
      # replicate selection logic
      modules=()
      if declare -p _CADDYCTL_MODULES >/dev/null 2>&1 && ((${#_CADDYCTL_MODULES[@]} > 0)); then
        modules=("${_CADDYCTL_MODULES[@]}")
      else
        modules=(00-core.sh 10-validate.sh)
      fi
      ((${#modules[@]} >= 2)) || exit 2
    ' || fail_test "module array selection is unsafe under set -u"
}

test_add_emby_propagates_apply_failure
test_add_gateway_propagates_apply_failure
test_set_emby_restores_previous_file_on_apply_failure
test_cmd_set_routes_emby_sites_to_file_updater
test_add_static_supports_http_mode
test_reverse_proxy_builders_support_http_mode
test_http_multi_label_matching_is_scheme_aware
test_gateway_uses_full_url_proxy_paths
test_emby_and_gateway_emit_tls_hook_on_https
test_set_preserves_dns_tls_from_existing_file
test_resolve_dns_tls_flag_logic
test_resolve_lock_file_prefers_writable_dir
test_inline_only_live_config_blocks_mutation
test_symlink_lock_does_not_truncate_target
test_incomplete_snapshot_preserves_live_config
test_snapshot_copy_failure_preserves_live_config
test_legacy_snapshot_remains_restorable
test_modules_array_safe_under_set_u

printf 'ok - smoke tests passed\n'
