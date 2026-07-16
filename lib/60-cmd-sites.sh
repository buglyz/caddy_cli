# caddyctl library module: 60-cmd-sites.sh
# shellcheck shell=bash
cmd_add_emby() {
    local label=""
    local target_domain=""
    local scheme="https"
    local scheme_explicit=0
    local prompted=0
    local skip_dns_check=0
    local force_dns_tls=0
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --http|--no-ssl) scheme="http"; scheme_explicit=1 ;;
            --https) scheme="https"; scheme_explicit=1 ;;
            --dns-only) force_dns_tls=1 ;;
            --skip-dns-check) skip_dns_check=1 ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 add-emby 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    label="${positional[0]:-}"
    target_domain="${positional[1]:-}"

    if [[ -z "$label" ]]; then
        read -rp "请输入你的域名: " label
        prompted=1
    fi
    label="$(trim "$label")"
    if ! validate_domain "$label"; then
        fail "域名不合法"
        return 1
    fi

    if [[ -z "$target_domain" ]]; then
        read -rp "请输入目标 Emby 服务器地址（如 https://emby.example.com:443）: " target_domain
        prompted=1
    fi
    target_domain="$(trim "$target_domain")"
    if [[ -z "$target_domain" ]]; then
        fail "目标地址不能为空"
        return 1
    fi

    # Auto-add https:// if missing
    if [[ "$target_domain" != http://* ]] && [[ "$target_domain" != https://* ]]; then
        target_domain="https://${target_domain}"
    fi
    if ! validate_proxy_target "$target_domain"; then
        fail "目标地址不合法"
        return 1
    fi

    if (( scheme_explicit == 0 && prompted == 1 )); then
        scheme="$(prompt_tls_scheme)"
    fi

    local sanitized old_file new_file file site_block
    sanitized="$(sanitize_name "$label")"
    new_file="${SITES_DIR}/${sanitized}.conf"
    old_file="${SITES_DIR}/${sanitized}.conf.disabled"

    for file in "$new_file" "$old_file"; do
        if [[ -s "$file" ]]; then
            fail "配置已存在: $file"
            say "如需修改请使用 c set $label --target <新地址>"
            return 1
        fi
    done

    if (( skip_dns_check == 0 )); then
        if ! check_site_dns_points_to_local "$label"; then
            return 1
        fi
    fi

    local dns_flag
    dns_flag="$(resolve_dns_tls_flag "$force_dns_tls" "$scheme" "")"
    site_block="$(with_dns_tls_flag "$dns_flag" build_emby_site_block "$label" "$target_domain" "$scheme")"
    ensure_dirs
    if ! write_site_file "$new_file" "$label" "$site_block"; then
        return 1
    fi
    fix_permissions
    if [[ "$scheme" == "http" ]]; then
        say "已添加 Emby 反代站点（HTTP，不申请证书）: $label -> $target_domain"
    else
        say "已添加 Emby 反代站点: $label -> $target_domain"
    fi
    say "注意: Emby 反代不启用 gzip 压缩（避免影响流媒体传输）"
}

cmd_add_gateway() {
    local label=""
    local scheme="https"
    local scheme_explicit=0
    local prompted=0
    local allow_spec=""
    local allow_regex=""
    local unsafe_open_proxy=0
    local skip_dns_check=0
    local force_dns_tls=0
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-ssl|--http) scheme="http"; scheme_explicit=1 ;;
            --https) scheme="https"; scheme_explicit=1 ;;
            --dns-only) force_dns_tls=1 ;;
            --skip-dns-check) skip_dns_check=1 ;;
            --allow)
                shift
                [[ $# -gt 0 ]] || { fail "--allow 需要 host:port 列表"; return 1; }
                allow_spec="$1"
                ;;
            --unsafe-open-proxy) unsafe_open_proxy=1 ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 add-gateway 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    label="${positional[0]:-}"

    if [[ -z "$label" ]]; then
        read -rp "请输入网关域名: " label
        prompted=1
    fi
    label="$(trim "$label")"
    if ! validate_domain "$label"; then
        fail "域名不合法"
        return 1
    fi

    if [[ -z "$allow_spec" && "$unsafe_open_proxy" -ne 1 ]]; then
        read -rp "允许的上游 host:port 列表（多个用逗号分隔；留空则需确认开放代理）: " allow_spec || true
        prompted=1
        allow_spec="$(trim "$allow_spec")"
    fi

    if [[ -n "$allow_spec" && "$unsafe_open_proxy" -eq 1 ]]; then
        fail "--allow 与 --unsafe-open-proxy 不能同时使用"
        return 1
    fi
    if [[ -z "$allow_spec" && "$unsafe_open_proxy" -ne 1 ]]; then
        if prompt_yes_no "未配置 allow-list 会创建开放动态代理，确认继续"; then
            unsafe_open_proxy=1
        else
            fail "add-gateway 默认需要 --allow <host:port,...>，避免创建公网开放代理。确需开放任意上游时使用 --unsafe-open-proxy。"
            return 1
        fi
    fi
    if [[ -n "$allow_spec" ]]; then
        allow_regex="$(gateway_allow_regex "$allow_spec")" || return 1
    fi
    if (( scheme_explicit == 0 && prompted == 1 )); then
        scheme="$(prompt_tls_scheme)"
    fi

    local sanitized old_file new_file file site_block
    sanitized="$(sanitize_name "$label")"
    new_file="${SITES_DIR}/${sanitized}.conf"
    old_file="${SITES_DIR}/${sanitized}.conf.disabled"

    for file in "$new_file" "$old_file"; do
        if [[ -s "$file" ]]; then
            fail "配置已存在: $file"
            say "如需修改请先 c rm $label 后再创建"
            return 1
        fi
    done

    if (( skip_dns_check == 0 )); then
        if ! check_site_dns_points_to_local "$label"; then
            return 1
        fi
    fi

    local dns_flag
    dns_flag="$(resolve_dns_tls_flag "$force_dns_tls" "$scheme" "")"
    site_block="$(with_dns_tls_flag "$dns_flag" build_gateway_site_block "$label" "$scheme" "$allow_regex" "$allow_spec")"
    ensure_dirs
    if ! write_site_file "$new_file" "$label" "$site_block"; then
        return 1
    fi
    fix_permissions
    if [[ "$scheme" == "http" ]]; then
        say "已添加通用反代网关（HTTP，不申请证书）: $label"
    else
        say "已添加通用反代网关: $label（自动申请 Let's Encrypt 证书）"
    fi
    if [[ -n "$allow_spec" ]]; then
        say "允许上游: $allow_spec"
    else
        say "警告: 已创建开放动态代理网关，请确保外部已有认证或网络隔离。"
    fi
    say "用法: ${scheme}://${label}/https://<上游主机:端口>/路径"
}

cmd_add() {
    local label=""
    local port=""
    local scheme="https"
    local scheme_explicit=0
    local prompted=0
    local path_prefix=""
    local force_dns_tls=0
    local skip_dns_check=0
    local -a positional=()

    while (( $# > 0 )); do
        case "$1" in
            --http|--no-ssl) scheme="http"; scheme_explicit=1 ;;
            --https) scheme="https"; scheme_explicit=1 ;;
            --dns-only) force_dns_tls=1 ;;
            --skip-dns-check) skip_dns_check=1 ;;
            --path)
                shift
                [[ $# -gt 0 ]] || { fail "--path 需要一个前缀"; return 1; }
                path_prefix="$1"
                ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 add 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    label="${positional[0]:-}"
    port="${positional[1]:-}"

    if [[ -z "$label" ]]; then
        read -rp "站点地址（如 example.com 或 example.com, api.example.com）: " label
        prompted=1
    fi
    if [[ -z "$port" ]]; then
        read -rp "本地端口: " port
        prompted=1
    fi

    label="$(trim "$label")"
    path_prefix="$(trim "$path_prefix")"
    if (( scheme_explicit == 0 && prompted == 1 )); then
        scheme="$(prompt_tls_scheme)"
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

    local file oldbak="" disabled
    file="$(site_path_for_label "$label")"
    disabled="$(disabled_site_path_for "$file")"

    if [[ -s "$file" || -s "$disabled" ]]; then
        fail "配置已存在: ${file}${disabled:+ 或 $disabled}"
        say "如需修改请使用: c set $label ..."
        return 1
    fi

    if (( skip_dns_check == 0 )); then
        if ! check_site_dns_points_to_local "$label"; then
            return 1
        fi
    fi
    oldbak="$(backup_file_if_exists "$file")"

    local dns_flag
    dns_flag="$(resolve_dns_tls_flag "$force_dns_tls" "$scheme" "$file")"

    if [[ -n "$path_prefix" ]]; then
        with_dns_tls_flag "$dns_flag" build_path_proxy_site_block "$label" "$port" "$path_prefix" "$scheme" > "$file"
    else
        with_dns_tls_flag "$dns_flag" build_reverse_proxy_site_block "$label" "$port" "$scheme" > "$file"
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
    local label=""
    local site_dir=""
    local scheme="https"
    local scheme_explicit=0
    local prompted=0
    local spa_mode="off"
    local skip_dns_check=0
    local force_dns_tls=0
    local -a positional=()

    while (( $# > 0 )); do
        case "$1" in
            --spa) spa_mode="on" ;;
            --http|--no-ssl) scheme="http"; scheme_explicit=1 ;;
            --https) scheme="https"; scheme_explicit=1 ;;
            --dns-only) force_dns_tls=1 ;;
            --skip-dns-check) skip_dns_check=1 ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 add-static 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    label="${positional[0]:-}"
    site_dir="${positional[1]:-}"

    if [[ -z "$label" ]]; then
        read -rp "站点地址（如 static.example.com）: " label
        prompted=1
    fi
    if [[ -z "$site_dir" ]]; then
        read -rp "静态目录路径: " site_dir
        prompted=1
    fi

    label="$(trim "$label")"
    site_dir="$(trim "$site_dir")"
    if (( scheme_explicit == 0 && prompted == 1 )); then
        scheme="$(prompt_tls_scheme)"
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

    local file oldbak="" disabled
    file="$(site_path_for_label "$label")"
    disabled="$(disabled_site_path_for "$file")"

    if [[ -s "$file" || -s "$disabled" ]]; then
        fail "配置已存在: ${file}${disabled:+ 或 $disabled}"
        say "如需修改请先 c rm $label 后再创建，或直接编辑后 c apply"
        return 1
    fi

    if (( skip_dns_check == 0 )); then
        if ! check_site_dns_points_to_local "$label"; then
            return 1
        fi
    fi

    oldbak="$(backup_file_if_exists "$file")"

    local dns_flag
    dns_flag="$(resolve_dns_tls_flag "$force_dns_tls" "$scheme" "$file")"
    with_dns_tls_flag "$dns_flag" build_static_site_block "$label" "$site_dir" "$spa_mode" "$scheme" > "$file"

    if ! write_site_file_with_rollback "$file" "$oldbak"; then
        fail "已回滚站点修改"
        return 1
    fi

    if [[ "$scheme" == "http" ]]; then
        say "已添加静态站点（HTTP，不申请证书）: $label -> $site_dir"
    else
        say "已添加静态站点: $label -> $site_dir"
    fi
    if [[ ! -d "$site_dir" ]]; then
        say "注意: 当前目录不存在，后续创建后即可由 Caddy 提供访问。"
    fi
}

cmd_set_emby_file() {
    local file="$1"
    local site_type="$2"
    local label="$3"
    local query="$4"
    local override_emby_target="$5"
    local override_scheme="$6"

    # Extract current target from file
    local current_target scheme label_from_file
    current_target="$(extract_reverse_proxy_target "$file")"
    current_target="$(trim "$current_target")"

    if [[ -z "$current_target" ]]; then
        fail "无法解析 Emby 反代目标: $file"
        return 1
    fi

    # Detect scheme from site label: domain only = https, http://domain = http
    label_from_file="$(sed -n '1s/^[[:space:]]\{0,\}\(.\{1,\}\)[[:space:]]\{0,\}{/\1/p' "$file")"
    label_from_file="$(trim "$label_from_file")"
    if [[ "$label_from_file" == http://* ]]; then
        scheme="http"
        label="${label_from_file#http://}"
    else
        scheme="https"
        label="$label_from_file"
    fi

    if [[ -z "$label" ]]; then
        fail "无法解析站点标签: $file"
        return 1
    fi
    if [[ -n "$override_scheme" ]]; then
        scheme="$override_scheme"
    fi

    say "当前 Emby 反代: ${label} → ${current_target}"

    local new_target=""
    if [[ -n "$override_emby_target" ]]; then
        new_target="$override_emby_target"
        say "使用指定目标: $new_target"
    elif [[ -n "$override_scheme" || "${CADDYCTL_FORCE_DNS_TLS:-0}" == "1" ]]; then
        # scheme-only or --dns-only updates should keep the current upstream.
        new_target="$current_target"
        say "保持当前目标: $new_target"
    else
        read -rp "输入新的 Emby 目标地址 (格式 example.com 或 1.2.3.4:8096): " new_target
        new_target="$(trim "$new_target")"
    fi

    if [[ -z "$new_target" ]]; then
        say "未提供新目标，已取消。"
        return 0
    fi

    # 构建完整 URL：自动补 http/https 和默认端口 8096
    if [[ "$new_target" != *://* ]]; then
        # 纯 IP:port 或 domain:port
        if [[ "$new_target" == *:* ]]; then
            new_target="${scheme}://${new_target}"
        else
            new_target="${scheme}://${new_target}:8096"
        fi
    fi
    if ! validate_proxy_target "$new_target"; then
        fail "目标地址不合法"
        return 1
    fi

    say "新目标: ${label} → ${new_target}"
    say "当前协议: ${scheme}，如需切换请在 cmd_set 调用时使用 --http / --https"

    local site_block dns_flag
    dns_flag="$(resolve_dns_tls_flag "${CADDYCTL_FORCE_DNS_TLS:-0}" "$scheme" "$file")"
    site_block="$(with_dns_tls_flag "$dns_flag" build_emby_site_block "$label" "$new_target" "$scheme")"

    local oldbak=""
    oldbak="$(backup_file_if_exists "$file")"
    if ! write_site_file "$file" "$label" "$site_block" "$oldbak"; then
        return 1
    fi
    fix_permissions
}

cmd_set() {
    local query=""
    local override_port=""
    local override_path="__keep__"
    local override_scheme=""
    local override_emby_target=""
    local force_dns_tls=0
    local -a positional=()

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
            --target)
                shift
                [[ $# -gt 0 ]] || { fail "--target 需要目标地址参数"; return 1; }
                override_emby_target="$1"
                ;;
            --dns-only) force_dns_tls=1 ;;
            --http) override_scheme="http" ;;
            --https) override_scheme="https" ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 set 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    query="${positional[0]:-}"

    if [[ -z "$query" ]]; then
        read -rp "输入要编辑的站点地址: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点地址不能为空"
        return 1
    fi

    local file site_type label target path_prefix scheme
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi

    site_type="$(detect_site_type "$file")"
    if [[ "$site_type" == "静态站点" ]]; then
        fail "当前仅支持编辑反代站点与路径反代站点，静态站点请使用 add-static 重新配置。"
        return 1
    fi

    if [[ "$site_type" == "Emby反代" ]]; then
        CADDYCTL_FORCE_DNS_TLS="$force_dns_tls" cmd_set_emby_file "$file" "$site_type" "${label:-}" "$query" "$override_emby_target" "$override_scheme"
        return $?
    fi
    if [[ "$site_type" == "网关" ]]; then
        fail "该配置是通用反代网关，请使用: c set-gateway $query [--allow <host:port,...>|--unsafe-open-proxy] [--http|--https]"
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

    local oldbak tmp dns_flag
    oldbak="$(backup_file_if_exists "$file")"
    tmp="$(mktemp)"
    dns_flag="$(resolve_dns_tls_flag "$force_dns_tls" "$scheme" "$file")"

    if [[ -n "$path_prefix" ]]; then
        with_dns_tls_flag "$dns_flag" build_path_proxy_site_block "$label" "$TARGET_PORT" "$path_prefix" "$scheme" > "$tmp"
    else
        with_dns_tls_flag "$dns_flag" build_reverse_proxy_site_block "$label" "$TARGET_PORT" "$scheme" > "$tmp"
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

cmd_set_emby_site() {
    local query="${1:-}"
    local -a args=("$@")
    if [[ -z "$query" ]]; then
        read -rp "输入要修改的 Emby 反代域名: " query
        args=("$query")
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "Emby 反代域名不能为空"
        return 1
    fi
    args[0]="$query"

    local file site_type
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该 Emby 反代"
        return 1
    fi
    site_type="$(detect_site_type "$file")"
    if [[ "$site_type" != "Emby反代" ]]; then
        fail "该配置不是 Emby 固定反代: $query（当前类型: $site_type）"
        return 1
    fi

    cmd_set "${args[@]}"
}

cmd_set_gateway() {
    local query=""
    local scheme=""
    local allow_spec="__keep__"
    local allow_regex=""
    local unsafe_open_proxy=0
    local allow_seen=0
    local unsafe_seen=0
    local scheme_seen=0
    local force_dns_tls=0
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --http|--no-ssl) scheme="http"; scheme_seen=1 ;;
            --https) scheme="https"; scheme_seen=1 ;;
            --dns-only) force_dns_tls=1 ;;
            --allow)
                shift
                [[ $# -gt 0 ]] || { fail "--allow 需要 host:port 列表"; return 1; }
                if (( unsafe_seen )); then
                    fail "--allow 与 --unsafe-open-proxy 不能同时使用"
                    return 1
                fi
                allow_seen=1
                allow_spec="$1"
                ;;
            --unsafe-open-proxy)
                if (( allow_seen )); then
                    fail "--allow 与 --unsafe-open-proxy 不能同时使用"
                    return 1
                fi
                unsafe_seen=1
                unsafe_open_proxy=1
                allow_spec=""
                ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 set-gateway 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    query="${positional[0]:-}"

    if [[ -z "$query" ]]; then
        read -rp "输入要修改的网关域名: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "网关域名不能为空"
        return 1
    fi

    local file site_type label current_allow current_scheme site_block oldbak
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该网关配置"
        return 1
    fi
    site_type="$(detect_site_type "$file")"
    if [[ "$site_type" != "网关" ]]; then
        fail "该配置不是通用反代网关: $query（当前类型: $site_type）"
        return 1
    fi
    if ! label="$(extract_primary_site_label_from_file "$file")"; then
        fail "无法解析网关域名"
        return 1
    fi
    label="${label#http://}"
    label="${label#https://}"

    current_scheme="$(extract_gateway_scheme "$file")"
    [[ -n "$scheme" ]] || scheme="$current_scheme"

    current_allow="$(extract_gateway_allow_spec "$file")"
    if (( allow_seen == 0 && unsafe_seen == 0 && scheme_seen == 0 )) && [[ -t 0 ]]; then
        if ! prompt_gateway_edit_values "$label" "$current_allow" "$current_scheme" allow_spec unsafe_open_proxy scheme; then
            return 1
        fi
    fi
    if [[ "$allow_spec" == "__keep__" ]]; then
        allow_spec="$current_allow"
        if [[ -z "$allow_spec" ]]; then
            unsafe_open_proxy=1
        fi
    fi
    allow_spec="$(trim "$allow_spec")"

    if [[ -n "$allow_spec" && "$unsafe_open_proxy" -eq 1 ]]; then
        fail "--allow 与 --unsafe-open-proxy 不能同时使用"
        return 1
    fi
    if [[ -z "$allow_spec" && "$unsafe_open_proxy" -ne 1 ]]; then
        if prompt_yes_no "未配置 allow-list 会创建开放动态代理，确认继续"; then
            unsafe_open_proxy=1
        else
            fail "set-gateway 默认需要 --allow <host:port,...>。确需开放任意上游时使用 --unsafe-open-proxy。"
            return 1
        fi
    fi
    if [[ -n "$allow_spec" ]]; then
        allow_regex="$(gateway_allow_regex "$allow_spec")" || return 1
    fi

    local dns_flag
    dns_flag="$(resolve_dns_tls_flag "$force_dns_tls" "$scheme" "$file")"
    site_block="$(with_dns_tls_flag "$dns_flag" build_gateway_site_block "$label" "$scheme" "$allow_regex" "$allow_spec")"
    oldbak="$(backup_file_if_exists "$file")"
    printf '%s\n' "$site_block" > "$file"

    if is_site_enabled "$file"; then
        if ! write_site_file_with_rollback "$file" "$oldbak"; then
            fail "已回滚网关修改"
            return 1
        fi
        say "已更新通用反代网关: $label"
    else
        chmod 644 "$file"
        chown root:caddy "$file" 2>/dev/null || true
        cleanup_paths "$oldbak"
        say "已更新禁用网关（未生效）: $label"
    fi
    if [[ -n "$allow_spec" ]]; then
        say "允许上游: $allow_spec"
    else
        say "警告: 当前网关为开放动态代理，请确保外部已有认证或网络隔离。"
    fi
}

prompt_gateway_edit_values() {
    local label="$1"
    local current_allow="$2"
    local current_scheme="$3"
    local allow_var="$4"
    local unsafe_var="$5"
    local scheme_var="$6"
    local input selected_allow selected_scheme unsafe_selected=0

    say "当前网关: $label"
    say "当前协议: ${current_scheme:-https}"
    if [[ -n "$current_allow" ]]; then
        say "当前允许上游: $current_allow"
    else
        say "当前允许上游: 任意上游（开放动态代理）"
    fi

    read -rp "新的 allow-list（host:port,多个用逗号；回车保留；输入 open 改为开放代理）: " input || return 1
    input="$(trim "$input")"
    case "${input,,}" in
        "") selected_allow="__keep__" ;;
        open|unsafe|any|all)
            selected_allow=""
            unsafe_selected=1
            ;;
        *) selected_allow="$input" ;;
    esac

    read -rp "协议 [https/http，回车保留 ${current_scheme:-https}]: " selected_scheme || return 1
    selected_scheme="$(trim "$selected_scheme")"
    case "${selected_scheme,,}" in
        "") selected_scheme="${current_scheme:-https}" ;;
        http|https) selected_scheme="${selected_scheme,,}" ;;
        *)
            fail "协议只能是 http 或 https"
            return 1
            ;;
    esac

    printf -v "$allow_var" '%s' "$selected_allow"
    printf -v "$unsafe_var" '%s' "$unsafe_selected"
    printf -v "$scheme_var" '%s' "$selected_scheme"
}

cmd_set_emby() {
    local query="${1:-}"
    shift || true
    local -a args=("$@")

    if [[ -z "$query" ]]; then
        read -rp "输入要修改的 Emby 配置域名: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "Emby 配置域名不能为空"
        return 1
    fi

    local file site_type
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该 Emby 配置"
        return 1
    fi
    site_type="$(detect_site_type "$file")"

    case "$site_type" in
        "Emby反代")
            cmd_set_emby_site "$query" "${args[@]}"
            ;;
        "网关")
            cmd_set_gateway "$query" "${args[@]}"
            ;;
        *)
            fail "该配置不是 Emby 配置: $query（当前类型: $site_type）"
            return 1
            ;;
    esac
}

cmd_toggle_site() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        read -rp "输入要切换状态的站点域名: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点域名不能为空"
        return 1
    fi

    local file
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi

    if is_site_enabled "$file"; then
        say "站点当前已启用，正在禁用..."
        cmd_disable "$query"
    else
        say "站点当前已禁用，正在启用..."
        cmd_enable "$query"
    fi
}

cmd_validate_and_apply() {
    say "正在校验配置..."
    if cmd_validate; then
        say "配置校验通过，正在应用..."
        cmd_apply
    else
        fail "配置校验失败，未应用"
        return 1
    fi
}

cmd_settings_menu() {
    local choice=""
    while true; do
        clear
        echo "====== 配置设置 ======"
        echo "1. 设置邮箱"
        echo "2. 设置服务超时"
        echo "3. 设置上游检查模式"
        echo "0. 返回上一级"
        echo "======================"
        read -rp "选择: " choice
        case "$choice" in
            1) require_command caddy; with_global_lock run_mutation email cmd_email ;;
            2) with_global_lock run_mutation timeout cmd_timeout ;;
            3) with_global_lock run_mutation upstream-mode cmd_upstream_mode ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

cmd_rm_emby() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        read -rp "输入要删除的 Emby 配置域名: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "Emby 配置域名不能为空"
        return 1
    fi

    local file site_type
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该 Emby 配置"
        return 1
    fi
    site_type="$(detect_site_type "$file")"
    case "$site_type" in
        "Emby反代"|"网关") ;;
        *)
            fail "该配置不是 Emby 配置: $query（当前类型: $site_type）"
            return 1
            ;;
    esac

    cmd_rm "$query"
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
        if site_file_matches_label "$f" "$query"; then
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
    if grep -q '通用反代网关' "$file" 2>/dev/null; then
        echo "网关"
    elif grep -Eq '^[[:space:]]*file_server([[:space:]]|$)' "$file"; then
        echo "静态站点"
    elif grep -Eq '^[[:space:]]*@path_.* path ' "$file" && grep -Eq '^[[:space:]]*uri strip_prefix ' "$file"; then
        echo "路径反代"
    elif grep -Eq '^[[:space:]]*header_up Host \{upstream_hostport\}' "$file"; then
        echo "Emby反代"
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
        "Emby反代")
            target="$(sed -n 's/^[[:space:]]*reverse_proxy //p' "$file" | head -n 1)"
            echo "Emby服务器: ${target:-unknown}"
            ;;
        "网关")
            echo "通用反代网关（动态上游，无需指定目标）"
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

print_site_entry() {
    local file="$1"
    echo "---- $(basename "$file") [$(detect_site_type "$file") / $(site_file_status "$file")] ----"
    site_summary "$file"
    sed -n '1,80p' "$file"
    echo
}

extract_primary_site_label_from_file() {
    local file="$1"
    local -a headers=()
    local header="" part out=""
    local -a parts=() cleaned=()

    mapfile -t headers < <(sed -n 's/^\([^[:space:]].*\)[[:space:]]*{[[:space:]]*$/\1/p' "$file")
    for header in "${headers[@]}"; do
        header="$(trim "$header")"
        [[ -n "$header" ]] || continue
        # Prefer non-www headers when present.
        if [[ "$header" == www.* ]]; then
            continue
        fi
        break
    done
    if [[ -z "$header" && ${#headers[@]} -gt 0 ]]; then
        header="$(trim "${headers[0]}")"
    fi
    [[ -n "$header" ]] || return 1

    # Strip scheme prefixes so callers can pass label back into builders safely.
    IFS=',' read -ra parts <<< "$header"
    for part in "${parts[@]}"; do
        part="$(trim "$part")"
        [[ -n "$part" ]] || continue
        part="${part#http://}"
        part="${part#https://}"
        part="$(trim "$part")"
        [[ -n "$part" ]] || continue
        cleaned+=("$part")
    done
    ((${#cleaned[@]} > 0)) || return 1

    out=""
    for part in "${cleaned[@]}"; do
        out="${out:+$out, }$part"
    done
    printf '%s' "$out"
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
            print_site_entry "$f"
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
            print_site_entry "$f"
        done
    fi
    shopt -u nullglob
}

cmd_list_emby() {
    local file type found=0

    echo "===== Emby 配置 ====="
    shopt -s nullglob
    local files=("$SITES_DIR"/*.conf "$SITES_DIR"/*.conf.disabled)
    for file in "${files[@]}"; do
        [[ -s "$file" ]] || continue
        type="$(detect_site_type "$file")"
        case "$type" in
            "Emby反代"|"网关")
                print_site_entry "$file"
                found=1
                ;;
        esac
    done
    shopt -u nullglob

    if (( found == 0 )); then
        echo "暂无"
    fi
}
