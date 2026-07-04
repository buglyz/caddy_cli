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
    return 1
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

test_add_emby_propagates_apply_failure
test_add_gateway_propagates_apply_failure
test_set_emby_restores_previous_file_on_apply_failure
test_cmd_set_routes_emby_sites_to_file_updater

printf 'ok - smoke tests passed\n'
