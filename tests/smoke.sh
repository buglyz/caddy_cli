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
STATE_FILE="$tmpdir/caddyctl.conf"
BACKUP_DIR="$tmpdir/backup"
SNAPSHOT_DIR="$BACKUP_DIR/snapshots"
ACCESS_LOG_DIR="$tmpdir/log"
LOCK_FILE="$tmpdir/caddyctl.lock"

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

test_gateway_uses_full_url_proxy_paths() {
    local config

    config="$(build_gateway_site_block gate.example.com https "x" "emby.example.com:443")"

    grep -Fq 'https://gate.example.com/https://<上游主机:端口>/路径' <<<"$config" || fail_test "gateway help did not use full URL format"
    # shellcheck disable=SC2016 # match literal Caddy placeholder rewrite output
    grep -Fq 'header_down Location ^https://([^/]+)(/.*)$ https://gate.example.com/https://$1$2' <<<"$config" || fail_test "gateway Location rewrite did not use full HTTPS URL format"
    grep -Fq '@httpsProxy0 path_regexp up_https_0 ^/https:/*emby\.example\.com:443(/.*)' <<<"$config" || fail_test "gateway allowed route did not match /https://source"
    ! grep -Fq 'https://gate.example.com/https/emby.example.com' <<<"$config" || fail_test "gateway emitted legacy /https/source path"
}

test_add_emby_propagates_apply_failure
test_add_gateway_propagates_apply_failure
test_set_emby_restores_previous_file_on_apply_failure
test_cmd_set_routes_emby_sites_to_file_updater
test_add_static_supports_http_mode
test_gateway_uses_full_url_proxy_paths

printf 'ok - smoke tests passed\n'
