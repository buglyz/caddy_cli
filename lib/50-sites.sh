# caddyctl library module: 50-sites.sh
# shellcheck shell=bash
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

report_tcp_port_listener() {
    local port="$1"
    local lines=""

    if command_exists ss; then
        lines="$(ss -H -ltnp "sport = :$port" 2>/dev/null || true)"
    elif command_exists netstat; then
        lines="$(netstat -ltnp 2>/dev/null | awk -v port="$port" '$4 ~ "[:.]" port "$" {print}' || true)"
    else
        echo "[WARN] 无法检查 TCP :$port（缺少 ss/netstat）"
        return 0
    fi

    if [[ -z "$lines" ]]; then
        echo "[WARN] TCP :$port 未监听"
        return 0
    fi

    echo "[OK] TCP :$port 正在监听"
    printf '%s\n' "$lines" | awk 'NR <= 5 { print "  " $0 } NR == 6 { print "  ..."; exit }'
}

extract_reverse_proxy_targets() {
    local config_path="$1"
    [[ -f "$config_path" ]] || return 0

    awk '
        function brace_delta(s, tmp, opens, closes) {
            tmp = s
            opens = gsub(/\{/, "{", tmp)
            tmp = s
            closes = gsub(/\}/, "}", tmp)
            return opens - closes
        }
        function clean_line(s) {
            sub(/\r$/, "", s)
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+#.*$/, "", s)
            return s
        }
        {
            line = clean_line($0)
            if (line == "" || line ~ /^#/) {
                next
            }

            n = split(line, fields, /[[:space:]]+/)
            if (fields[1] == "reverse_proxy") {
                for (i = 2; i <= n; i++) {
                    if (fields[i] == "{" || fields[i] ~ /^\{/) {
                        break
                    }
                    if (fields[i] ~ /^@/) {
                        continue
                    }
                    print fields[i]
                }
                if (line ~ /\{/) {
                    in_proxy = 1
                    depth = brace_delta(line)
                    if (depth <= 0) {
                        in_proxy = 0
                    }
                }
                next
            }

            if (in_proxy && fields[1] == "to") {
                for (i = 2; i <= n; i++) {
                    if (fields[i] == "{" || fields[i] ~ /^\{/) {
                        break
                    }
                    print fields[i]
                }
            }

            if (in_proxy) {
                depth += brace_delta(line)
                if (depth <= 0) {
                    in_proxy = 0
                }
            }
        }
    ' "$config_path"
}

normalize_site_name() {
    local value="$1"
    local host port wildcard_base

    value="$(trim "$value")"
    value="${value%,}"
    value="${value#http://}"
    value="${value#https://}"
    value="${value%%/*}"
    value="${value%.}"
    value="${value,,}"

    [[ -n "$value" ]] || return 1
    [[ "$value" != "_" ]] || return 1
    [[ "$value" != "localhost" ]] || return 1
    [[ "$value" != \[*\] ]] || return 1
    [[ "$value" != \[*\]:* ]] || return 1

    if [[ "$value" == *:* ]]; then
        host="${value%:*}"
        port="${value##*:}"
        if validate_port "$port"; then
            value="$host"
        else
            return 1
        fi
    fi

    if [[ "$value" == \*.* ]]; then
        wildcard_base="${value#*.}"
        validate_domain "$wildcard_base" || return 1
        printf '%s\n' "$value"
        return 0
    fi

    validate_domain "$value" || return 1
    printf '%s\n' "$value"
}

extract_caddy_site_labels() {
    local config_path="$1"
    [[ -f "$config_path" ]] || return 0

    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ /^[[:space:]]/) {
                next
            }
            sub(/[[:space:]]+#.*$/, "", line)
            if (line !~ /\{/) {
                next
            }
            sub(/\{.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") {
                next
            }
            n = split(line, labels, ",")
            for (i = 1; i <= n; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", labels[i])
                if (labels[i] != "") {
                    print labels[i]
                }
            }
        }
    ' "$config_path"
}

extract_nginx_server_names() {
    local nginx_dir="$1"
    local -a files=()

    [[ -d "$nginx_dir" ]] || return 0
    shopt -s nullglob
    files=("$nginx_dir"/*.conf)
    shopt -u nullglob
    (( ${#files[@]} > 0 )) || return 0

    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            if (line !~ /^[[:space:]]*server_name[[:space:]]+/) {
                next
            }
            sub(/^[[:space:]]*server_name[[:space:]]+/, "", line)
            sub(/;.*/, "", line)
            gsub(/[[:space:]]+/, "\n", line)
            print line
        }
    ' "${files[@]}"
}

print_limited_items() {
    local max="$1"
    shift
    local total="$#"
    local index=0
    local item

    for item in "$@"; do
        index=$((index + 1))
        if (( index <= max )); then
            echo "  - $item"
        fi
    done
    if (( total > max )); then
        echo "  ... 还有 $((total - max)) 项"
    fi
}

report_nginx_migration_coverage() {
    local nginx_dir="$1"
    local config_path="$2"
    local raw normalized
    local -A nginx_domains=()
    local -A caddy_domains=()
    local -a missing_domains=()
    local -a extra_domains=()
    local -a missing_sorted=()
    local -a extra_sorted=()

    if [[ ! -d "$nginx_dir" ]]; then
        echo "[INFO] 未发现 $nginx_dir，跳过 nginx 迁移覆盖检查"
        return 0
    fi
    if [[ ! -f "$config_path" ]]; then
        echo "[WARN] 未找到 $config_path，无法检查 nginx 迁移覆盖"
        return 0
    fi

    while IFS= read -r raw; do
        normalized="$(normalize_site_name "$raw" 2>/dev/null || true)"
        [[ -n "$normalized" ]] || continue
        nginx_domains["$normalized"]=1
    done < <(extract_nginx_server_names "$nginx_dir")

    while IFS= read -r raw; do
        normalized="$(normalize_site_name "$raw" 2>/dev/null || true)"
        [[ -n "$normalized" ]] || continue
        caddy_domains["$normalized"]=1
    done < <(extract_caddy_site_labels "$config_path")

    if (( ${#nginx_domains[@]} == 0 )); then
        echo "[INFO] nginx 配置中未发现可比较的 server_name"
        return 0
    fi

    for normalized in "${!nginx_domains[@]}"; do
        if [[ -z "${caddy_domains[$normalized]:-}" ]]; then
            missing_domains+=("$normalized")
        fi
    done
    for normalized in "${!caddy_domains[@]}"; do
        if [[ -z "${nginx_domains[$normalized]:-}" ]]; then
            extra_domains+=("$normalized")
        fi
    done

    if (( ${#missing_domains[@]} == 0 )); then
        echo "[OK] nginx server_name 已全部出现在 Caddyfile（${#nginx_domains[@]} 个）"
    else
        mapfile -t missing_sorted < <(printf '%s\n' "${missing_domains[@]}" | sort)
        echo "[WARN] nginx 中有 ${#missing_domains[@]}/${#nginx_domains[@]} 个域名未出现在 Caddyfile:"
        print_limited_items 20 "${missing_sorted[@]}"
    fi

    if (( ${#extra_domains[@]} > 0 )); then
        mapfile -t extra_sorted < <(printf '%s\n' "${extra_domains[@]}" | sort)
        echo "[INFO] Caddyfile 中另有 ${#extra_domains[@]} 个 nginx 未声明的域名:"
        print_limited_items 20 "${extra_sorted[@]}"
    fi
}

extract_tls_file_pairs() {
    local config_path="$1"
    [[ -f "$config_path" ]] || return 0

    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+#.*$/, "", line)
            if (line !~ /^tls([[:space:]]|$)/) {
                next
            }
            n = split(line, fields, /[[:space:]]+/)
            if (n >= 3 && fields[2] != "{" && fields[2] != "internal") {
                print fields[2] "\t" fields[3]
            }
        }
    ' "$config_path"
}

report_tls_file_references() {
    local config_path="$1"
    local cert key end_date
    local found=0

    if [[ ! -f "$config_path" ]]; then
        echo "[WARN] 未找到 $config_path，跳过 TLS 文件引用检查"
        return 0
    fi

    while IFS=$'\t' read -r cert key; do
        found=1
        cert="$(strip_wrapping_quotes "$cert")"
        key="$(strip_wrapping_quotes "$key")"

        if [[ -r "$cert" ]]; then
            echo "[OK] TLS 证书可读: $cert"
            if command_exists openssl; then
                if openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then
                    end_date="$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | sed 's/^notAfter=//' || true)"
                    if openssl x509 -checkend 2592000 -noout -in "$cert" >/dev/null 2>&1; then
                        echo "[OK] TLS 证书未过期: ${end_date:-unknown}"
                    else
                        echo "[WARN] TLS 证书将在 30 天内过期: ${end_date:-unknown}"
                    fi
                else
                    echo "[WARN] TLS 证书已过期或无法解析: $cert"
                fi
            else
                echo "[INFO] 缺少 openssl，跳过证书有效期检查"
            fi
        else
            echo "[WARN] TLS 证书不可读: $cert"
        fi

        if [[ -r "$key" ]]; then
            echo "[OK] TLS 私钥可读: $key"
        else
            echo "[WARN] TLS 私钥不可读: $key"
        fi
    done < <(extract_tls_file_pairs "$config_path")

    if (( found == 0 )); then
        echo "[INFO] 未发现手动 tls cert/key 文件引用"
    fi
}

site_file_matches_label() {
    local file="$1"
    local query="$2"
    local raw normalized part
    local found=0
    local -A file_labels=()
    local -a query_parts=()

    [[ -f "$file" ]] || return 1

    while IFS= read -r raw; do
        normalized="$(normalize_site_name "$raw" 2>/dev/null || true)"
        [[ -n "$normalized" ]] || continue
        file_labels["$normalized"]=1
    done < <(extract_caddy_site_labels "$file")

    IFS=',' read -ra query_parts <<< "$query"
    for part in "${query_parts[@]}"; do
        part="$(trim "$part")"
        [[ -n "$part" ]] || continue
        normalized="$(normalize_site_name "$part" 2>/dev/null || true)"
        [[ -n "$normalized" ]] || return 1
        [[ -n "${file_labels[$normalized]:-}" ]] || return 1
        found=1
    done

    (( found == 1 ))
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
    done < <(extract_reverse_proxy_targets "$config_path")

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
        if site_file_matches_label "$path" "$label"; then
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

format_site_label_for_scheme() {
    local label="$1"
    local scheme="$2"
    local part out=""
    local -a parts=()

    if [[ "$scheme" != "http" ]]; then
        printf '%s' "$label"
        return 0
    fi

    IFS=',' read -ra parts <<< "$label"
    for part in "${parts[@]}"; do
        part="$(trim "$part")"
        [[ -n "$part" ]] || continue
        out="${out:+$out, }http://${part}"
    done

    printf '%s' "$out"
}


# ---- DNS-01 force helpers (Cloudflare variant reads FORCE_DNS_TLS via hook) ----
site_file_wants_dns_tls() {
    local file="$1"
    [[ -n "$file" && -f "$file" ]] || return 1
    # Match either multi-line tls { dns cloudflare } or a single-line dns cloudflare directive.
    grep -Eq 'dns[[:space:]]+cloudflare' "$file" 2>/dev/null
}

with_dns_tls_flag() {
    # with_dns_tls_flag <0|1> <command> [args...]
    local flag="$1"
    shift
    local prev="${FORCE_DNS_TLS:-0}"
    FORCE_DNS_TLS="$flag"
    local rc=0
    "$@" || rc=$?
    FORCE_DNS_TLS="$prev"
    return "$rc"
}

resolve_dns_tls_flag() {
    # resolve_dns_tls_flag <explicit_force 0|1> <scheme> [existing_file]
    # Prints 0 or 1. HTTP scheme always 0. explicit 1 wins. Else preserve existing file.
    local explicit="${1:-0}"
    local scheme="${2:-https}"
    local file="${3:-}"
    if [[ "$scheme" == "http" ]]; then
        printf '0'
        return 0
    fi
    if [[ "$explicit" == "1" ]]; then
        printf '1'
        return 0
    fi
    if [[ -n "$file" ]] && site_file_wants_dns_tls "$file"; then
        printf '1'
        return 0
    fi
    printf '0'
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
    local site_label
    site_label="$(format_site_label_for_scheme "$label" "$scheme")"

    cat <<EOF
${site_label} {
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
    local primary matcher_name site_label
    primary="$(get_primary_label "$label")"
    matcher_name="@path_$(sanitize_name "$primary")_$(sanitize_name "$path_prefix")"
    site_label="$(format_site_label_for_scheme "$label" "$scheme")"

    cat <<EOF
${site_label} {
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
    local scheme="${4:-https}"
    local site_label
    site_label="$(format_site_label_for_scheme "$label" "$scheme")"

    cat <<EOF
${site_label} {
EOF
    if [[ "$scheme" == "http" ]]; then
        emit_site_common_blocks no
    else
        emit_site_common_blocks
    fi
    cat <<EOF
    root * $(caddyfile_quote "$site_dir")
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
EMBYEOF
    # Keep Emby free of encode/gzip, but still honor CF DNS-01 TLS hook on HTTPS.
    if [[ "$scheme" != "http" ]]; then
        _hook_render_site_tls
    fi
    cat <<EMBYEOF
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
    local allow_regex="${3:-}"
    local allow_display="${4:-}"
    local access_note="任意上游（高风险，仅限受控网络或已加外部认证）"
    local -a allowed_items=()

    if [[ -n "$allow_regex" ]]; then
        access_note="仅允许: ${allow_display}"
        IFS=',' read -ra allowed_items <<< "$allow_display"
    fi

    gateway_emit_redirect() {
        local matcher="$1"
        local regexp_name="$2"
        local pattern="$3"
        local target="$4"

        cat <<BLOCK
    @$matcher path_regexp $regexp_name $pattern
    redir @$matcher $target 308

BLOCK
    }

    gateway_emit_proxy_handle() {
        local matcher="$1"
        local rest_placeholder="$2"
        local upstream="$3"
        local upstream_scheme="$4"
        local host_header="$5"
        local location_prefix="$6"

        cat <<BLOCK
    handle @$matcher {
        rewrite * $rest_placeholder
        reverse_proxy {
            to $upstream
BLOCK
        if [[ "$upstream_scheme" == "http" ]]; then
            cat <<'BLOCK'
            transport http
BLOCK
        else
            cat <<'BLOCK'
            transport http {
                tls
            }
BLOCK
        fi
        cat <<BLOCK
            header_up Host $host_header
            header_up X-Real-IP {remote_host}
            header_down Location ^http://([^/]+)(/.*)\$ ${scheme}://${label}/http://\$1\$2
            header_down Location ^https://([^/]+)(/.*)\$ ${scheme}://${label}/https://\$1\$2
            header_down Location ^/(.*)\$ ${location_prefix}/\$1
            header_down Location ^([^/:][^:]*)\$ ${location_prefix}/\$1
            flush_interval -1
        }
    }

BLOCK
    }

    gateway_emit_proxy_route() {
        local matcher="$1"
        local regexp_name="$2"
        local pattern="$3"
        local rest_placeholder="$4"
        local upstream="$5"
        local upstream_scheme="$6"
        local host_header="$7"
        local location_prefix="$8"

        cat <<BLOCK
    @$matcher path_regexp $regexp_name $pattern
BLOCK
        gateway_emit_proxy_handle "$matcher" "$rest_placeholder" "$upstream" "$upstream_scheme" "$host_header" "$location_prefix"
    }

    gateway_emit_unsafe_routes() {
        cat <<BLOCK
    @noSlashHttp path_regexp redir_http ^/http:/*([A-Za-z0-9.\\-_:]+)\$
    redir @noSlashHttp /http://{re.redir_http.1}/ 308

    @noSlashHttps path_regexp redir_https ^/https:/*([A-Za-z0-9.\\-_:]+)\$
    redir @noSlashHttps /https://{re.redir_https.1}/ 308

BLOCK
        gateway_emit_proxy_route "httpProxyWithPort" "up_http_port" "^/http:/*([A-Za-z0-9.\\-_]+):([0-9]+)(/.*)" "{re.up_http_port.3}" "{re.up_http_port.1}:{re.up_http_port.2}" "http" "{re.up_http_port.1}:{re.up_http_port.2}" "${scheme}://${label}/http://{re.up_http_port.1}:{re.up_http_port.2}"
        gateway_emit_proxy_route "httpProxyNoPort" "up_http_host" "^/http:/*([A-Za-z0-9.\\-_]+)(/.*)" "{re.up_http_host.2}" "{re.up_http_host.1}:80" "http" "{re.up_http_host.1}" "${scheme}://${label}/http://{re.up_http_host.1}"
        gateway_emit_proxy_route "httpsProxyWithPort" "up_https_port" "^/https:/*([A-Za-z0-9.\\-_]+):([0-9]+)(/.*)" "{re.up_https_port.3}" "{re.up_https_port.1}:{re.up_https_port.2}" "https" "{re.up_https_port.1}:{re.up_https_port.2}" "${scheme}://${label}/https://{re.up_https_port.1}:{re.up_https_port.2}"
        gateway_emit_proxy_route "httpsProxyNoPort" "up_https_host" "^/https:/*([A-Za-z0-9.\\-_]+)(/.*)" "{re.up_https_host.2}" "{re.up_https_host.1}:443" "https" "{re.up_https_host.1}" "${scheme}://${label}/https://{re.up_https_host.1}"
    }

    gateway_emit_allowed_routes() {
        local item target target_re host port host_re idx=0

        for item in "${allowed_items[@]}"; do
            target="$(trim "$item")"
            [[ -n "$target" ]] || continue
            host="${target%:*}"
            port="${target##*:}"
            target_re="$(regex_escape "$target")"
            host_re="$(regex_escape "$host")"

            gateway_emit_redirect "noSlashHttp${idx}" "redir_http_${idx}" "^/http:/*${target_re}\$" "/http://${target}/"
            gateway_emit_redirect "noSlashHttps${idx}" "redir_https_${idx}" "^/https:/*${target_re}\$" "/https://${target}/"

            gateway_emit_proxy_route "httpProxy${idx}" "up_http_${idx}" "^/http:/*${target_re}(/.*)" "{re.up_http_${idx}.1}" "$target" "http" "$target" "${scheme}://${label}/http://${target}"
            gateway_emit_proxy_route "httpsProxy${idx}" "up_https_${idx}" "^/https:/*${target_re}(/.*)" "{re.up_https_${idx}.1}" "$target" "https" "$target" "${scheme}://${label}/https://${target}"

            if [[ "$port" == "80" ]]; then
                gateway_emit_redirect "noSlashHttpDefaultPort${idx}" "redir_http_default_port_${idx}" "^/http:/*${host_re}\$" "/http://${host}/"
                gateway_emit_proxy_route "httpProxyDefaultPort${idx}" "up_http_default_port_${idx}" "^/http:/*${host_re}(/.*)" "{re.up_http_default_port_${idx}.1}" "${host}:80" "http" "$host" "${scheme}://${label}/http://${host}"
            fi

            if [[ "$port" == "443" ]]; then
                gateway_emit_redirect "noSlashHttpsDefaultPort${idx}" "redir_https_default_port_${idx}" "^/https:/*${host_re}\$" "/https://${host}/"
                gateway_emit_proxy_route "httpsProxyDefaultPort${idx}" "up_https_default_port_${idx}" "^/https:/*${host_re}(/.*)" "{re.up_https_default_port_${idx}.1}" "${host}:443" "https" "$host" "${scheme}://${label}/https://${host}"
            fi

            idx=$((idx + 1))
        done

        cat <<'BLOCK'
    handle {
        respond "upstream is not allowed" 403
    }
BLOCK
    }

    cat <<BLOCK
# Emby 通用反代网关 — $label
# 用法: ${scheme}://${label}/https://<上游主机:端口>/路径
# 上游限制: ${access_note}
# 生成: $(date '+%F %T')

${scheme}://${label} {
BLOCK
    if [[ "$scheme" != "http" ]]; then
        _hook_render_site_tls
    fi
    cat <<BLOCK
    request_body {
        max_size 500MB
    }

    handle / {
        respond <<INFO
OK

通用反代网关 — Emby Proxy Toolbox (Caddy)

使用方式：
  ${scheme}://${label}/http://<上游主机:端口>/路径
  ${scheme}://${label}/https://<上游主机:端口>/路径

上游限制: ${access_note}
回源协议由路径中的 http:// 或 https:// 决定。
INFO 200
    }

BLOCK
    if [[ -n "$allow_regex" ]]; then
        gateway_emit_allowed_routes
    else
        gateway_emit_unsafe_routes
    fi
    cat <<'BLOCK'
}
BLOCK
}
