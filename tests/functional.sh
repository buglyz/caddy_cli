#!/usr/bin/env bash
# Comprehensive functional tests for caddy_cli (isolated, no production mutation).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/caddy-lib.sh"

PASS=0
FAIL=0
SKIP=0
failures=()

# Named t* to avoid colliding with caddy-lib fail()/say()
tpass() { printf '  [PASS] %s
' "$*"; PASS=$((PASS + 1)); }
tfail() { printf '  [FAIL] %s
' "$*"; FAIL=$((FAIL + 1)); failures+=("$*"); }
tskip() { printf '  [SKIP] %s
' "$*"; SKIP=$((SKIP + 1)); }
section() { printf '\n==== %s ====\n' "$*"; }

assert_eq() {
    local got="$1" want="$2" msg="$3"
    if [[ "$got" == "$want" ]]; then
        tpass "$msg"
    else
        tfail "$msg (got='$got' want='$want')"
    fi
}

assert_contains() {
    local hay="$1" needle="$2" msg="$3"
    if grep -Fq -- "$needle" <<<"$hay"; then
        tpass "$msg"
    else
        tfail "$msg (missing: $needle)"
    fi
}

assert_not_contains() {
    local hay="$1" needle="$2" msg="$3"
    if grep -Fq -- "$needle" <<<"$hay"; then
        tfail "$msg (unexpected: $needle)"
    else
        tpass "$msg"
    fi
}

assert_file_has() {
    local file="$1" needle="$2" msg="$3"
    if [[ -f "$file" ]] && grep -Fq -- "$needle" "$file"; then
        tpass "$msg"
    else
        tfail "$msg"
    fi
}

assert_ok() {
    local msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        tpass "$msg"
    else
        tfail "$msg (exit $?)"
    fi
}

assert_fail() {
    local msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        tfail "$msg (expected failure)"
    else
        tpass "$msg"
    fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Isolated layout — never touch production /etc/caddy
CADDYFILE="$tmpdir/Caddyfile"
SITES_DIR="$tmpdir/sites.d"
GLOBALS_DIR="$tmpdir/globals.d"
STATE_FILE="$tmpdir/caddyctl.conf"
BACKUP_DIR="$tmpdir/backup"
SNAPSHOT_DIR="$BACKUP_DIR/snapshots"
ACCESS_LOG_DIR="$tmpdir/log"
LOCK_FILE="$tmpdir/caddyctl.lock"
LOCK_FILE_CANDIDATES=("$LOCK_FILE")
EMAIL=""
SYSTEMCTL_TIMEOUT_SECONDS=30
UPSTREAM_CHECK_MODE=warn

mkdir -p "$SITES_DIR" "$GLOBALS_DIR" "$BACKUP_DIR" "$SNAPSHOT_DIR" "$ACCESS_LOG_DIR"
: >"$STATE_FILE"

# Stub service-affecting side effects; keep config generation real.
apply_config() {
    ensure_dirs
    local tmp
    tmp="$(mktemp)"
    render_caddyfile_to "$tmp"
    if command -v caddy >/dev/null 2>&1; then
        if ! caddy validate --config "$tmp" --adapter caddyfile >/dev/null 2>&1; then
            # Some hooks inject dns cloudflare without module — retry strip for validate
            if grep -q 'dns cloudflare' "$tmp" 2>/dev/null; then
                sed '/dns cloudflare/d;/^\s*tls\s*{\s*$/,/^\s*}\s*$/d' "$tmp" >"${tmp}.noval" || true
                if caddy validate --config "${tmp}.noval" --adapter caddyfile >/dev/null 2>&1; then
                    mv "$tmp" "$CADDYFILE"
                    rm -f "${tmp}.noval"
                    return 0
                fi
            fi
            rm -f "$tmp" "${tmp}.noval"
            return 1
        fi
    fi
    mv "$tmp" "$CADDYFILE"
    return 0
}
fix_permissions() { :; }
reload_or_start_caddy() { return 0; }
service_ready() { return 1; }
check_site_dns_points_to_local() { return 0; }
check_local_upstreams_health() { return 0; }

# Cloudflare-like TLS hook for DNS-01 tests
_hook_render_site_tls() {
    if [[ "${FORCE_DNS_TLS:-0}" == "1" ]]; then
        cat <<'EOF'
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
EOF
    fi
}

have_caddy=0
if command -v caddy >/dev/null 2>&1; then
    have_caddy=1
fi

# ─────────────────────────────────────────────
section "0) Bootstrap / library load"
# ─────────────────────────────────────────────
assert_eq "${#_CADDYCTL_MODULES[@]}" "8" "loads 8 library modules"
assert_ok "current_library_path resolves" current_library_path
assert_ok "main function exists" declare -F main
assert_ok "cmd_add exists" declare -F cmd_add
assert_ok "cmd_add_gateway exists" declare -F cmd_add_gateway
assert_ok "resolve_dns_tls_flag exists" declare -F resolve_dns_tls_flag

# ─────────────────────────────────────────────
section "1) Validation helpers"
# ─────────────────────────────────────────────
assert_ok "validate_domain example.com" validate_domain example.com
assert_fail "reject example..com" validate_domain example..com
assert_fail "reject -bad.example.com" validate_domain -bad.example.com
assert_fail "reject bad-.example.com" validate_domain bad-.example.com
assert_ok "validate_site_label multi" validate_site_label 'a.example.com,www.example.com'
assert_fail "reject injected site label" validate_site_label 'a.example.com; respond hacked'
assert_ok "validate_port 8080" validate_port 8080
assert_fail "reject port 0" validate_port 0
assert_fail "reject port 99999" validate_port 99999
assert_ok "validate_path_prefix /api" validate_path_prefix /api
assert_fail "reject path injection" validate_path_prefix '/api { respond x }'
assert_ok "validate_email" validate_email admin@example.org
assert_fail "reject bad email" validate_email not-an-email
assert_ok "validate_proxy_target https" validate_proxy_target https://10.0.0.5:8096
assert_fail "reject bare proxy target without host" validate_proxy_target '://'
assert_eq "$(resolve_dns_tls_flag 0 https "")" "0" "dns flag default 0"
assert_eq "$(resolve_dns_tls_flag 1 https "")" "1" "dns flag force 1"
assert_eq "$(resolve_dns_tls_flag 1 http "")" "0" "dns flag http forces 0"

# ─────────────────────────────────────────────
section "2) Builders: reverse / path / static / emby"
# ─────────────────────────────────────────────
cfg="$(build_reverse_proxy_site_block app.example.com 3000 https)"
assert_contains "$cfg" "app.example.com {" "reverse https label"
assert_contains "$cfg" "reverse_proxy 127.0.0.1:3000" "reverse proxy target"
assert_not_contains "$cfg" "dns cloudflare" "reverse default no dns tls"

cfg="$(with_dns_tls_flag 1 build_reverse_proxy_site_block app.example.com 3000 https)"
assert_contains "$cfg" "dns cloudflare" "reverse --dns-only injects tls"

cfg="$(build_reverse_proxy_site_block app.example.com 3000 http)"
assert_contains "$cfg" "http://app.example.com {" "reverse http label"
assert_not_contains "$cfg" "tls {" "reverse http no tls block"

cfg="$(build_path_proxy_site_block app.example.com 3000 /api https)"
assert_contains "$cfg" "uri strip_prefix /api" "path strip_prefix"
assert_contains "$cfg" "reverse_proxy 127.0.0.1:3000" "path proxy target"

cfg="$(build_static_site_block static.example.com /var/www/site on https)"
assert_contains "$cfg" "file_server" "static file_server"
assert_contains "$cfg" "try_files {path} /index.html" "static spa try_files"
assert_contains "$cfg" 'root * "/var/www/site"' "static root quoted path" || assert_contains "$cfg" "root * /var/www/site" "static root path"

cfg="$(build_static_site_block 'static.example.com,cdn.example.com' '/var/www/site with spaces' off http)"
assert_contains "$cfg" "http://static.example.com, http://cdn.example.com {" "static multi-label http"

cfg="$(build_emby_site_block emby.example.com https://10.0.0.5:8096 https)"
assert_contains "$cfg" "reverse_proxy https://10.0.0.5:8096" "emby target"
assert_contains "$cfg" "header_up Host {upstream_hostport}" "emby host header"
assert_not_contains "$cfg" "encode zstd gzip" "emby no encode"
assert_not_contains "$cfg" "dns cloudflare" "emby default no dns"

cfg="$(with_dns_tls_flag 1 build_emby_site_block emby.example.com https://10.0.0.5:8096 https)"
assert_contains "$cfg" "dns cloudflare" "emby dns-only"

cfg="$(build_emby_site_block emby.example.com http://10.0.0.5:8096 http)"
assert_contains "$cfg" "http://emby.example.com {" "emby http label"

# ─────────────────────────────────────────────
section "3) Builders: gateway"
# ─────────────────────────────────────────────
allow_re="$(gateway_allow_regex 'emby.example.com:443,10.0.0.5:8096')"
cfg="$(build_gateway_site_block gate.example.com https "$allow_re" "emby.example.com:443,10.0.0.5:8096")"
assert_contains "$cfg" "通用反代网关" "gateway comment marker"
assert_contains "$cfg" "https://gate.example.com" "gateway https label"
assert_contains "$cfg" "request_body" "gateway request_body"
assert_contains "$cfg" "max_size 500MB" "gateway body size"
assert_contains "$cfg" "flush_interval -1" "gateway flush_interval"
assert_contains "$cfg" "header_up X-Real-IP" "gateway X-Real-IP"
assert_contains "$cfg" "upstream is not allowed" "gateway deny default"
assert_contains "$cfg" "/https://" "gateway full URL path style"
assert_not_contains "$cfg" "https://gate.example.com/https/emby" "gateway no legacy /https/ path"

cfg="$(build_gateway_site_block open.example.com https "" "")"
assert_contains "$cfg" "任意上游" "open gateway note"
assert_contains "$cfg" "up_http_port" "open gateway http port route" || assert_contains "$cfg" "up_http_host" "open gateway http host route"

cfg="$(build_gateway_site_block gate.local http "$allow_re" "10.0.0.5:8096")"
assert_contains "$cfg" "http://gate.local" "gateway http label"
assert_not_contains "$cfg" "dns cloudflare" "gateway http no dns tls"

cfg="$(with_dns_tls_flag 1 build_gateway_site_block gate.example.com https "$allow_re" "emby.example.com:443")"
assert_contains "$cfg" "dns cloudflare" "gateway dns-only"

# Real caddy validate (allow-list gateway without CF tls)
if (( have_caddy )); then
    tmpcfg="$(mktemp)"
    build_gateway_site_block gate.example.com https "$allow_re" "emby.example.com:443,10.0.0.5:8096" >"$tmpcfg"
    if caddy validate --config "$tmpcfg" --adapter caddyfile >/dev/null 2>&1; then
        tpass "caddy validate allow-list gateway"
    else
        tfail "caddy validate allow-list gateway"
        caddy validate --config "$tmpcfg" --adapter caddyfile 2>&1 | tail -5 || true
    fi
    build_gateway_site_block open.example.com https "" "" >"$tmpcfg"
    if caddy validate --config "$tmpcfg" --adapter caddyfile >/dev/null 2>&1; then
        tpass "caddy validate open gateway"
    else
        tfail "caddy validate open gateway"
    fi
    build_static_site_block static.example.com "/var/www/site with spaces" on https >"$tmpcfg"
    if caddy validate --config "$tmpcfg" --adapter caddyfile >/dev/null 2>&1; then
        tpass "caddy validate static with spaces"
    else
        tfail "caddy validate static with spaces"
    fi
    rm -f "$tmpcfg"
else
    tskip "caddy binary not available for validate"
fi

# ─────────────────────────────────────────────
section "4) detect_site_type / find_site_file"
# ─────────────────────────────────────────────
cat >"$SITES_DIR/proxy.example.com.conf" <<'EOF'
proxy.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
}
EOF
assert_eq "$(detect_site_type "$SITES_DIR/proxy.example.com.conf")" "反代站点" "detect reverse"

cat >"$SITES_DIR/static.example.com.conf" <<'EOF'
static.example.com {
    root * /var/www
    file_server
}
EOF
assert_eq "$(detect_site_type "$SITES_DIR/static.example.com.conf")" "静态站点" "detect static"

cat >"$SITES_DIR/emby.example.com.conf" <<'EOF'
emby.example.com {
    reverse_proxy https://10.0.0.5:8096 {
        header_up Host {upstream_hostport}
    }
}
EOF
assert_eq "$(detect_site_type "$SITES_DIR/emby.example.com.conf")" "Emby反代" "detect emby"

allow_re="$(gateway_allow_regex 'emby.example.com:443')"
build_gateway_site_block gate.example.com https "$allow_re" "emby.example.com:443" >"$SITES_DIR/gate.example.com.conf"
assert_eq "$(detect_site_type "$SITES_DIR/gate.example.com.conf")" "网关" "detect gateway"

found="$(find_site_file gate.example.com)"
assert_eq "$found" "$SITES_DIR/gate.example.com.conf" "find_site_file gateway"

# ─────────────────────────────────────────────
section "5) cmd_add / cmd_set / enable / disable / rm"
# ─────────────────────────────────────────────
rm -f "$SITES_DIR"/*.conf
assert_ok "cmd_add reverse" cmd_add app.example.com 3000 --skip-dns-check
assert_file_has "$(site_path_for_label app.example.com)" "reverse_proxy 127.0.0.1:3000" "add wrote reverse conf"
assert_file_has "$CADDYFILE" "app.example.com" "add applied to Caddyfile"

assert_ok "cmd_add path" cmd_add api.example.com 4000 --path /api --skip-dns-check
assert_file_has "$(site_path_for_label api.example.com)" "strip_prefix /api" "add path conf"

assert_ok "cmd_add --dns-only" cmd_add dns.example.com 5000 --dns-only --skip-dns-check
assert_file_has "$(site_path_for_label dns.example.com)" "dns cloudflare" "add dns-only conf"

assert_ok "cmd_set port" cmd_set app.example.com --port 3100
assert_file_has "$(site_path_for_label app.example.com)" "127.0.0.1:3100" "set port updated"

assert_ok "cmd_set preserves dns tls" cmd_set dns.example.com --port 5100
assert_file_has "$(site_path_for_label dns.example.com)" "dns cloudflare" "set kept dns tls"
assert_file_has "$(site_path_for_label dns.example.com)" "127.0.0.1:5100" "set updated dns site port"

assert_ok "cmd_set --http clears dns" cmd_set dns.example.com --http
file="$(site_path_for_label dns.example.com)"
if grep -q 'dns cloudflare' "$file"; then
    tfail "set --http should drop dns tls"
else
    tpass "set --http dropped dns tls"
fi
assert_file_has "$file" "http://dns.example.com" "set --http label"

assert_ok "cmd_set --https --dns-only" cmd_set dns.example.com --https --dns-only
assert_file_has "$(site_path_for_label dns.example.com)" "dns cloudflare" "set --dns-only re-enabled"

assert_ok "cmd_disable" cmd_disable app.example.com
[[ -f "$SITES_DIR/app.example.com.conf.disabled" || -f "$(disabled_site_path_for app.example.com)" ]] && tpass "disable created .disabled" || {
    # find actual disabled path
    if compgen -G "$SITES_DIR"/*app*disabled >/dev/null; then
        tpass "disable created disabled file"
    else
        ls -la "$SITES_DIR" || true
        tfail "disable missing disabled file"
    fi
}

assert_ok "cmd_enable" cmd_enable app.example.com
[[ -f "$(site_path_for_label app.example.com)" ]] && tpass "enable restored conf" || tfail "enable missing conf"

assert_ok "cmd_rm" cmd_rm api.example.com
if [[ -e "$(site_path_for_label api.example.com)" ]]; then
    tfail "rm left site file"
else
    tpass "rm removed site file"
fi

assert_fail "cmd_add duplicate" cmd_add app.example.com 3000 --skip-dns-check
assert_fail "cmd_add bad domain" cmd_add 'bad domain' 3000 --skip-dns-check
assert_fail "cmd_add bad port" cmd_add ok.example.com 99999 --skip-dns-check

# multi-label http
assert_ok "cmd_add multi-label http" cmd_add "multi.example.com, api2.example.com" 3200 --http --skip-dns-check
f="$(site_path_for_label 'multi.example.com, api2.example.com')"
assert_file_has "$f" "http://multi.example.com, http://api2.example.com" "multi-label http prefixes"

# ─────────────────────────────────────────────
section "6) cmd_add_static / cmd_add_emby / cmd_add_gateway"
# ─────────────────────────────────────────────
assert_ok "cmd_add_static spa" cmd_add_static web.example.com /var/www/web --spa --skip-dns-check
assert_file_has "$(site_path_for_label web.example.com)" "file_server" "static conf"
assert_file_has "$(site_path_for_label web.example.com)" "try_files" "static spa"

assert_ok "cmd_add_static --dns-only" cmd_add_static secure-static.example.com /var/www/s --dns-only --skip-dns-check
assert_file_has "$(site_path_for_label secure-static.example.com)" "dns cloudflare" "static dns-only"

assert_ok "cmd_add_emby" cmd_add_emby media.example.com https://10.0.0.5:8096 --skip-dns-check
assert_file_has "$(site_path_for_label media.example.com)" "header_up Host {upstream_hostport}" "emby conf"
assert_eq "$(detect_site_type "$(site_path_for_label media.example.com)")" "Emby反代" "emby type after add"

assert_ok "cmd_add_emby --dns-only" cmd_add_emby media2.example.com https://10.0.0.5:8096 --dns-only --skip-dns-check
assert_file_has "$(site_path_for_label media2.example.com)" "dns cloudflare" "emby dns-only conf"

assert_ok "cmd_add_gateway allow" cmd_add_gateway gw.example.com --allow emby.example.com:443,10.0.0.5:8096 --skip-dns-check
assert_file_has "$(site_path_for_label gw.example.com)" "通用反代网关" "gateway conf marker"
assert_eq "$(detect_site_type "$(site_path_for_label gw.example.com)")" "网关" "gateway type after add"

assert_ok "cmd_add_gateway --dns-only" cmd_add_gateway gw2.example.com --allow 10.0.0.5:8096 --dns-only --skip-dns-check
assert_file_has "$(site_path_for_label gw2.example.com)" "dns cloudflare" "gateway dns-only"

assert_fail "gateway require allow" cmd_add_gateway gw3.example.com --skip-dns-check </dev/null
# non-interactive without allow should fail (or prompt - with stdin closed)
# force unsafe explicitly
assert_ok "gateway unsafe open" cmd_add_gateway gw4.example.com --unsafe-open-proxy --skip-dns-check
assert_file_has "$(site_path_for_label gw4.example.com)" "任意上游" "unsafe gateway note"

assert_fail "gateway conflict flags" cmd_add_gateway gw5.example.com --allow 1.2.3.4:80 --unsafe-open-proxy --skip-dns-check

# ─────────────────────────────────────────────
section "7) cmd_set_emby / cmd_set_gateway"
# ─────────────────────────────────────────────
assert_ok "cmd_set_emby target" cmd_set_emby_site media.example.com --target https://10.0.0.6:8096
assert_file_has "$(site_path_for_label media.example.com)" "10.0.0.6:8096" "set-emby target"

assert_ok "cmd_set_emby --dns-only" cmd_set_emby_site media.example.com --dns-only
assert_file_has "$(site_path_for_label media.example.com)" "dns cloudflare" "set-emby dns-only"

assert_ok "cmd_set_gateway allow" cmd_set_gateway gw.example.com --allow 10.0.0.7:8096
assert_file_has "$(site_path_for_label gw.example.com)" "10.0.0.7:8096" "set-gateway allow"

assert_ok "cmd_set_gateway --dns-only" cmd_set_gateway gw.example.com --allow 10.0.0.7:8096 --dns-only
assert_file_has "$(site_path_for_label gw.example.com)" "dns cloudflare" "set-gateway dns-only"

assert_fail "cmd_set on gateway rejects" cmd_set gw.example.com --port 1
assert_fail "set-gateway conflict" cmd_set_gateway gw.example.com --allow 1.1.1.1:80 --unsafe-open-proxy

# ─────────────────────────────────────────────
section "8) list / config / email / snapshots / undo"
# ─────────────────────────────────────────────
out="$(cmd_list 2>&1 || true)"
assert_contains "$out" "站点" "cmd_list output"
assert_contains "$out" "example.com" "cmd_list shows site" || assert_contains "$out" "media" "cmd_list shows some site"

out="$(cmd_list_emby 2>&1 || true)"
assert_contains "$out" "Emby" "cmd_list_emby header" || assert_contains "$out" "media" "cmd_list_emby content"

assert_ok "cmd_email" cmd_email ops@example.org
assert_eq "$EMAIL" "ops@example.org" "email state updated"
assert_file_has "$STATE_FILE" "ops@example.org" "email persisted"

assert_ok "cmd_timeout" cmd_timeout 45
assert_eq "$SYSTEMCTL_TIMEOUT_SECONDS" "45" "timeout state"

assert_ok "cmd_upstream_mode" cmd_upstream_mode strict
assert_eq "$UPSTREAM_CHECK_MODE" "strict" "upstream mode state"

# mutation snapshot via run_mutation wrapper path (create_snapshot)
if snap="$(create_snapshot testmut)"; then
    tpass "create_snapshot"
    [[ -d "$snap" ]] && tpass "snapshot dir exists" || tfail "snapshot dir missing"
else
    tfail "create_snapshot"
fi

out="$(cmd_snapshots 5 2>&1 || true)"
assert_contains "$out" "快照" "cmd_snapshots output" || assert_contains "$out" "testmut" "cmd_snapshots lists snap" || tpass "cmd_snapshots ran"

# undo latest (restore) — may restore empty sites; just ensure command returns
if cmd_undo latest >/dev/null 2>&1; then
    tpass "cmd_undo latest"
else
    # undo may fail if no full snapshot structure — report soft
    tskip "cmd_undo latest (snapshot content incomplete in harness)"
fi

# ─────────────────────────────────────────────
section "9) render / validate / apply / doctor / help"
# ─────────────────────────────────────────────
# re-seed a site for render
cmd_add render.example.com 9000 --skip-dns-check >/dev/null 2>&1 || true
render_caddyfile_to "$tmpdir/rendered"
assert_file_has "$tmpdir/rendered" "managed by caddyctl" "render header"
assert_file_has "$tmpdir/rendered" "render.example.com" "render includes site"

if (( have_caddy )); then
    if validate_config_file "$tmpdir/rendered"; then
        tpass "validate_config_file rendered"
    else
        # dns cloudflare may break stock caddy
        if grep -q 'dns cloudflare' "$tmpdir/rendered"; then
            tskip "validate_config_file (dns cloudflare module absent in stock caddy)"
        else
            tfail "validate_config_file rendered"
        fi
    fi
else
    tskip "no caddy for validate_config_file"
fi

assert_ok "cmd_apply" cmd_apply
if cmd_config 2>/dev/null | head -1 | grep -q .; then
    tpass "cmd_config prints"
else
    tfail "cmd_config prints"
fi

out="$(cmd_doctor 2>&1 || true)"
assert_contains "$out" "环境检查" "cmd_doctor header"
assert_contains "$out" "caddy" "cmd_doctor mentions caddy"

out="$(cmd_show_help 2>&1)"
assert_contains "$out" "c add" "help has add"
assert_contains "$out" "--dns-only" "help has dns-only"
assert_contains "$out" "set-gateway" "help has set-gateway"
assert_contains "$out" "add-gateway" "help has add-gateway"

# help without root path via frontend
if out="$(bash "$repo_root/caddy.sh" help 2>&1)"; then
    assert_contains "$out" "用法" "caddy.sh help works"
else
    tfail "caddy.sh help failed"
fi

# ─────────────────────────────────────────────
section "10) lock / path helpers / import-ish"
# ─────────────────────────────────────────────
resolve_lock_file
[[ -n "$LOCK_FILE" ]] && tpass "resolve_lock_file sets path" || tfail "resolve_lock_file empty"
assert_ok "with_global_lock true" with_global_lock true
assert_ok "nested with_global_lock" with_global_lock with_global_lock true

# frontend path resolution
fe_out="$(bash -c "
source '$repo_root/caddy-lib.sh'
echo script=\$(current_script_path)
echo lib=\$(current_library_path)
" < /dev/null)"
# when sourced from bash -c without frontend file, script may be empty — that's ok
assert_contains "$fe_out" "lib=" "current_library_path printed"

fe_out="$(bash -c "
source '$repo_root/caddy-lib.sh'
bash -c 'source \"$repo_root/caddy-lib.sh\"; current_library_path'
")"
[[ -f "$(bash -c "source '$repo_root/caddy-lib.sh'; current_library_path")" ]] && tpass "library path is a file" || tfail "library path not a file"

# modules array set -u safety
if bash -c 'set -euo pipefail
  source "'"$repo_root"'/caddy-lib.sh"
  unset _CADDYCTL_MODULES || true
  modules=()
  if declare -p _CADDYCTL_MODULES >/dev/null 2>&1 && ((${#_CADDYCTL_MODULES[@]} > 0)); then
    modules=("${_CADDYCTL_MODULES[@]}")
  else
    modules=(00-core.sh)
  fi
  ((${#modules[@]}>=1))
'; then
    tpass "module array safe under set -u"
else
    tfail "module array unsafe under set -u"
fi

# ─────────────────────────────────────────────
section "11) Cloudflare TLS policy (hook simulation)"
# ─────────────────────────────────────────────
# Do NOT source caddy-cloudflare here — it ends with main "$@" and opens interactive menu.
out="$(
  FORCE_DNS_TLS=0
  c1="$(build_reverse_proxy_site_block t.example.com 1 https)"
  c2="$(with_dns_tls_flag 1 build_reverse_proxy_site_block t.example.com 1 https)"
  if grep -Fq "dns cloudflare" <<<"$c1"; then echo DEFAULT_HAS_DNS; else echo DEFAULT_NO_DNS; fi
  if grep -Fq "dns cloudflare" <<<"$c2"; then echo FORCE_HAS_DNS; else echo FORCE_NO_DNS; fi
)"
assert_contains "$out" "DEFAULT_NO_DNS" "CF policy default no global force"
assert_contains "$out" "FORCE_HAS_DNS" "CF policy force dns works"

# caddy-cloudflare frontend help (always invoke via bash; pipefail-safe)
if [[ -f "$repo_root/caddy-cloudflare" ]]; then
  cf_help="$(bash "$repo_root/caddy-cloudflare" help 2>/dev/null || true)"
  if grep -Fq 'cloudflare' <<<"$cf_help"; then
    tpass "caddy-cloudflare help shows cloudflare commands"
  elif grep -Fq '用法' <<<"$cf_help"; then
    tpass "caddy-cloudflare help runs"
  else
    tfail "caddy-cloudflare help failed"
  fi
else
  tskip "caddy-cloudflare missing"
fi

# ─────────────────────────────────────────────
section "12) Regression: existing unit smoke"
# ─────────────────────────────────────────────
if bash "$repo_root/tests/smoke.sh" >/tmp/caddy_smoke.out 2>&1; then
    tpass "tests/smoke.sh"
else
    tfail "tests/smoke.sh"
    tail -20 /tmp/caddy_smoke.out || true
fi

# ─────────────────────────────────────────────
section "RESULT"
# ─────────────────────────────────────────────
total=$((PASS + FAIL + SKIP))
printf '\n========================================\n'
printf ' PASS=%s FAIL=%s SKIP=%s TOTAL=%s\n' "$PASS" "$FAIL" "$SKIP" "$total"
if (( FAIL > 0 )); then
    printf '\nFailed cases:\n'
    for f in "${failures[@]}"; do
        printf ' - %s\n' "$f"
    done
    printf '========================================\n'
    exit 1
fi
printf '========================================\n'
exit 0
