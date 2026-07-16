# caddyctl library module: 70-cmd-ops.sh
# shellcheck shell=bash
cmd_email() {
    local new_email="${1:-}"
    if [[ -z "$new_email" ]]; then
        read -rp "请输入邮箱（回车清空）: " new_email
    fi

    if ! validate_email "$new_email"; then
        fail "邮箱格式不合法"
        return 1
    fi

    local old_email="${EMAIL:-}"
    EMAIL="$new_email"
    save_state

    if ! apply_config; then
        EMAIL="$old_email"
        save_state
        fix_permissions
        fail "已回滚邮箱设置"
        return 1
    fi

    say "已更新邮箱"
}

cmd_timeout() {
    local new_timeout="${1:-}"
    local effective_timeout
    effective_timeout="$(get_systemctl_timeout_seconds)"

    if [[ -z "$new_timeout" ]]; then
        say "当前服务超时: ${effective_timeout}s（持久配置: ${SYSTEMCTL_TIMEOUT_SECONDS}s）"
        if [[ -n "${CADDYCTL_SYSTEMCTL_TIMEOUT:-}" ]]; then
            say "当前会话由环境变量 CADDYCTL_SYSTEMCTL_TIMEOUT 覆盖。"
        fi
        return 0
    fi

    if [[ "$new_timeout" == "default" ]]; then
        new_timeout="$DEFAULT_SYSTEMCTL_TIMEOUT"
    fi

    if ! validate_timeout_seconds "$new_timeout"; then
        fail "超时必须是 ${MIN_SYSTEMCTL_TIMEOUT}-${MAX_SYSTEMCTL_TIMEOUT} 秒内的整数"
        return 1
    fi

    SYSTEMCTL_TIMEOUT_SECONDS="$new_timeout"
    save_state
    say "已设置服务超时: ${SYSTEMCTL_TIMEOUT_SECONDS}s"
}

cmd_upstream_mode() {
    local new_mode="${1:-}"
    local effective_mode
    effective_mode="$(get_upstream_check_mode)"

    if [[ -z "$new_mode" ]]; then
        say "当前上游健康检查模式: ${effective_mode}（持久配置: ${UPSTREAM_CHECK_MODE}）"
        if [[ -n "${CADDYCTL_UPSTREAM_CHECK_MODE:-}" ]]; then
            say "当前会话由环境变量 CADDYCTL_UPSTREAM_CHECK_MODE 覆盖。"
        fi
        return 0
    fi

    if ! validate_upstream_check_mode "$new_mode"; then
        fail "模式仅支持 warn 或 strict"
        return 1
    fi

    UPSTREAM_CHECK_MODE="$new_mode"
    save_state
    say "已设置上游健康检查模式: $UPSTREAM_CHECK_MODE"
}

cmd_validate() {
    local tmp
    tmp="$(mktemp)"
    render_caddyfile_to "$tmp"

    if validate_config_file "$tmp"; then
        say "配置校验通过"
        cleanup_paths "$tmp"
        cleanup_paths "${LAST_VALIDATE_LOG:-}"
        LAST_VALIDATE_LOG=""
    else
        fail "配置校验失败，日志: ${LAST_VALIDATE_LOG:-unknown}"
        [[ -n "${LAST_VALIDATE_LOG:-}" ]] && cat "$LAST_VALIDATE_LOG"
        cleanup_paths "$tmp"
        return 1
    fi
}

cmd_apply() {
    if ! has_any_config; then
        say "没有可应用的配置"
        return 0
    fi
    apply_config
}

cmd_config() {
    if [[ -f "$CADDYFILE" ]]; then
        cat "$CADDYFILE"
    else
        fail "未找到 $CADDYFILE"
    fi
}

cmd_status() {
    service_ready || { fail "未检测到 service manager"; return 1; }
    svc_status_show
}

cmd_logs() {
    if command_exists journalctl && journalctl -u caddy -n 1 --no-pager >/dev/null 2>&1; then
        journalctl -u caddy -n 120 --no-pager
    elif [[ -f /var/log/caddy.log ]]; then
        tail -n 120 /var/log/caddy.log
    elif [[ -f /var/log/caddy/caddy.log ]]; then
        tail -n 120 /var/log/caddy/caddy.log
    else
        fail "未检测到 Caddy 日志（无 journalctl，/var/log/caddy.log 不存在）"
        return 1
    fi
}

cmd_start() {
    service_ready || { fail "未检测到 service manager"; return 1; }
    svc_start
}

cmd_restart() {
    service_ready || { fail "未检测到 service manager"; return 1; }
    svc_restart
}

cmd_stop() {
    service_ready || { fail "未检测到 service manager"; return 1; }
    svc_stop
}

cmd_disable() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        read -rp "输入要禁用的站点地址: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点地址不能为空"
        return 1
    fi

    local file target
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi
    if ! is_site_enabled "$file"; then
        fail "该站点已经是禁用状态"
        return 1
    fi

    target="$(disabled_site_path_for "$file")"
    if [[ -e "$target" ]]; then
        fail "禁用失败，目标文件已存在: $target"
        return 1
    fi

    mv "$file" "$target"

    if ! apply_config; then
        mv "$target" "$file"
        fix_permissions
        fail "已回滚禁用操作"
        return 1
    fi

    say "已禁用: $query"
}

cmd_enable() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        read -rp "输入要启用的站点地址: " query
    fi
    query="$(trim "$query")"
    if [[ -z "$query" ]]; then
        fail "站点地址不能为空"
        return 1
    fi

    local file target
    if ! file="$(find_site_file "$query")"; then
        fail "未找到该站点"
        return 1
    fi
    if is_site_enabled "$file"; then
        fail "该站点已经是启用状态"
        return 1
    fi

    target="${file%.disabled}"
    if [[ -e "$target" ]]; then
        fail "启用失败，目标文件已存在: $target"
        return 1
    fi

    mv "$file" "$target"

    if ! apply_config; then
        mv "$target" "$file"
        fix_permissions
        fail "已回滚启用操作"
        return 1
    fi

    say "已启用: $query"
}

cmd_undo() {
    local requested="${1:-latest}"
    local snapshot_path guard_snapshot

    if [[ "$requested" == "latest" || -z "$requested" ]]; then
        if ! snapshot_path="$(latest_snapshot_path)"; then
            fail "没有可回滚的快照"
            return 1
        fi
    else
        if [[ "$requested" == */* ]]; then
            fail "快照ID格式不合法"
            return 1
        fi
        snapshot_path="$SNAPSHOT_DIR/$requested"
        if [[ ! -d "$snapshot_path" ]]; then
            fail "快照不存在: $requested"
            return 1
        fi
    fi

    guard_snapshot="$(create_snapshot "undo-guard")" || {
        fail "创建回滚保护快照失败"
        return 1
    }

    if ! restore_snapshot_contents "$snapshot_path"; then
        fail "恢复快照内容失败"
        safe_remove_snapshot_dir "$guard_snapshot"
        return 1
    fi

    if ! apply_config; then
        fail "回滚后应用失败，正在恢复回滚前状态。"
        restore_snapshot_contents "$guard_snapshot" || true
        apply_config || true
        safe_remove_snapshot_dir "$guard_snapshot"
        return 1
    fi

    safe_remove_snapshot_dir "$snapshot_path"
    safe_remove_snapshot_dir "$guard_snapshot"
    say "已回滚到快照: $(basename "$snapshot_path")"
}

cmd_cert_check() {
    local domain="${1:-}"
    local http_code https_code matched_file=""

    if [[ -z "$domain" ]]; then
        read -rp "输入要诊断的域名: " domain
    fi
    domain="$(trim "$domain")"
    if ! validate_domain "$domain"; then
        fail "域名格式不合法"
        return 1
    fi

    echo "===== 证书诊断: $domain ====="

    if command_exists dig; then
        local a_records aaaa_records
        a_records="$(dig +short A "$domain" | tr '\n' ' ')"
        aaaa_records="$(dig +short AAAA "$domain" | tr '\n' ' ')"
        a_records="$(trim "$a_records")"
        aaaa_records="$(trim "$aaaa_records")"
        if [[ -n "$a_records" || -n "$aaaa_records" ]]; then
            echo "[OK] DNS 解析:"
            [[ -n "$a_records" ]] && echo "  A: $a_records"
            [[ -n "$aaaa_records" ]] && echo "  AAAA: $aaaa_records"
        else
            echo "[WARN] DNS 未解析到 A/AAAA 记录"
        fi
    elif command_exists getent; then
        local hosts
        hosts="$(getent hosts "$domain" | awk '{print $1}' | tr '\n' ' ')"
        hosts="$(trim "$hosts")"
        if [[ -n "$hosts" ]]; then
            echo "[OK] DNS 解析: $hosts"
        else
            echo "[WARN] DNS 未解析到记录"
        fi
    else
        echo "[WARN] 缺少 dig/getent，跳过 DNS 检查"
    fi

    local f
    shopt -s nullglob
    for f in "$SITES_DIR"/*.conf "$SITES_DIR"/*.conf.disabled; do
        [[ -s "$f" ]] || continue
        if grep -Fq "$domain" "$f"; then
            matched_file="$f"
            break
        fi
    done
    shopt -u nullglob
    if [[ -n "$matched_file" ]]; then
        echo "[OK] 站点配置存在: $(basename "$matched_file")"
    else
        echo "[WARN] 未在站点配置中发现该域名"
    fi

    if command_exists curl; then
        http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "http://$domain/" || echo 000)"
        https_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "https://$domain/" || echo 000)"
        if [[ "$http_code" == "000" ]]; then
            echo "[WARN] HTTP 不可达"
        else
            echo "[OK] HTTP 可达，状态码: $http_code"
        fi
        if [[ "$https_code" == "000" ]]; then
            echo "[WARN] HTTPS 不可达"
        else
            echo "[OK] HTTPS 可达，状态码: $https_code"
        fi
    else
        echo "[WARN] 缺少 curl，跳过连通性检查"
    fi

    if command_exists journalctl; then
        echo
        echo "===== 最近证书相关日志（最多20行） ====="
        journalctl -u caddy -n 300 --no-pager 2>/dev/null | grep -Ei 'acme|certificate|tls|challenge|issuer' | tail -n 20 || true
    elif [[ -f /var/log/caddy/caddy.log ]]; then
        echo
        echo "===== 最近证书相关日志（最多20行） ====="
        grep -Ei 'acme|certificate|tls|challenge|issuer' /var/log/caddy/caddy.log 2>/dev/null | tail -n 20 || true
    else
        echo "[WARN] 缺少 journalctl 和日志文件，跳过日志诊断"
    fi
}

cmd_doctor() {
    local caddy_bin=""

    echo "===== 环境检查 ====="

    if caddy_bin="$(caddy_binary 2>/dev/null)"; then
        echo "[OK] 已安装 caddy: $caddy_bin ($(caddy_version_text))"
    else
        echo "[NO] 未安装 caddy"
    fi

    if command_exists python3; then
        echo "[OK] 已安装 python3"
    else
        echo "[WARN] 未安装 python3，import 功能不可用"
    fi

    if service_ready; then
        echo "[OK] 检测到 service manager: $(svc_backend_name)"
        if svc_unit_exists; then
            echo "[OK] 检测到 caddy 服务单元"
        else
            echo "[WARN] 未检测到 caddy 服务单元"
        fi

        report_service_state caddy "Caddy"
        report_conflicting_service_state nginx "nginx"
    else
        echo "[WARN] 未检测到 service manager（systemd/OpenRC）"
    fi
    echo "[INFO] 操作锁等待: $(get_lock_wait_seconds)s（可用环境变量 CADDYCTL_LOCK_WAIT_SECONDS 覆盖）"
    echo "[INFO] 上游健康检查模式: $(get_upstream_check_mode)"
    _hook_cmd_doctor

    echo
    echo "===== 目录检查 ====="
    for path in /etc/caddy "$SITES_DIR" "$GLOBALS_DIR" "$BACKUP_DIR" "$STATE_FILE" "$ACCESS_LOG_DIR"; do
        if [[ -e "$path" ]]; then
            echo "[OK] $path"
        else
            echo "[WARN] $path 不存在"
        fi
    done

    echo
    echo "===== Caddyfile 校验 ====="
    if [[ -f "$CADDYFILE" ]]; then
        echo "[OK] 找到 $CADDYFILE"
        if [[ -n "$caddy_bin" ]]; then
            if validate_config_file "$CADDYFILE"; then
                echo "[OK] Caddyfile 校验通过"
                cleanup_paths "${LAST_VALIDATE_LOG:-}"
                LAST_VALIDATE_LOG=""
            else
                echo "[WARN] Caddyfile 校验失败"
                if [[ -n "${LAST_VALIDATE_LOG:-}" && -f "$LAST_VALIDATE_LOG" ]]; then
                    sed -n '1,80p' "$LAST_VALIDATE_LOG"
                    cleanup_paths "$LAST_VALIDATE_LOG"
                    LAST_VALIDATE_LOG=""
                fi
            fi
        else
            echo "[WARN] 未安装 caddy，跳过 Caddyfile 校验"
        fi
    else
        echo "[WARN] 未找到 $CADDYFILE"
    fi

    echo
    echo "===== 端口监听 ====="
    report_tcp_port_listener 80
    report_tcp_port_listener 443

    echo
    echo "===== 本地上游 ====="
    if [[ -f "$CADDYFILE" ]]; then
        if ! check_local_upstreams_health "$CADDYFILE"; then
            echo "[WARN] 本地上游检查未通过"
        fi
    else
        echo "[WARN] 未找到 $CADDYFILE，跳过本地上游检查"
    fi

    echo
    echo "===== TLS 文件引用 ====="
    report_tls_file_references "$CADDYFILE"

    echo
    echo "===== nginx 迁移覆盖 ====="
    report_nginx_migration_coverage /etc/nginx/conf.d "$CADDYFILE"
}

cmd_install_self() {
    local src lib_src target_bin target_alias lib_bin lib_mod_dir mod
    src="$(current_script_path)" || {
        fail "无法定位当前脚本路径，不能自动安装命令"
        return 1
    }
    lib_src="$(current_library_path)" || {
        fail "无法定位 caddy-lib.sh，不能自动安装命令"
        return 1
    }

    target_bin="/usr/local/bin/caddyctl"
    target_alias="/usr/local/bin/c"
    lib_bin="/usr/local/bin/caddy-lib.sh"
    lib_mod_dir="/usr/local/lib/caddyctl"

    install -d -m 0755 "$(dirname "$target_bin")"
    install -d -m 0755 "$lib_mod_dir"
    install -m 0755 "$src" "$target_bin"
    install -m 0644 "$lib_src" "$lib_bin"

    # Install modular library files next to entrypoint resolution path
    local mod_count=0
    if [[ -d "${_CADDYCTL_LIBDIR:-}" ]]; then
        for mod in "$_CADDYCTL_LIBDIR"/*.sh; do
            [[ -f "$mod" ]] || continue
            install -m 0644 "$mod" "$lib_mod_dir/$(basename "$mod")"
            mod_count=$((mod_count + 1))
        done
    else
        local repo_lib
        repo_lib="$(dirname "$lib_src")/lib"
        if [[ -d "$repo_lib" ]]; then
            for mod in "$repo_lib"/*.sh; do
                [[ -f "$mod" ]] || continue
                install -m 0644 "$mod" "$lib_mod_dir/$(basename "$mod")"
                mod_count=$((mod_count + 1))
            done
        fi
    fi
    if (( mod_count == 0 )) || [[ ! -f "$lib_mod_dir/00-core.sh" ]]; then
        fail "库模块安装不完整（期望 $_CADDYCTL_LIBDIR 或 $(dirname "$lib_src")/lib 中含 00-core.sh）。请从完整仓库安装。"
        return 1
    fi

    ln -sf "$target_bin" "$target_alias"

    say "已安装脚本命令:"
    say "  $target_bin"
    say "  $target_alias -> $target_bin"
    say "  $lib_bin"
    say "  $lib_mod_dir/*.sh"
    say "现在可以直接运行: c"
}

cmd_update() {
    require_command curl
    require_command bash

    local update_binary=0
    local -a update_positional=()
    while (( $# > 0 )); do
        case "$1" in
            --binary|--with-binary) update_binary=1 ;;
            --) shift; while (( $# > 0 )); do update_positional+=("$1"); shift; done; break ;;
            --*) fail "未知 update 参数: $1"; return 1 ;;
            *) update_positional+=("$1") ;;
        esac
        shift
    done

    local url lib_url checksums_url base_url tmp tmp_lib target_bin target_alias lib_bin lib_mod_dir
    local -a modules=()
    # Under 'set -u', ${#_CADDYCTL_MODULES[@]} aborts if the array is unset.
    if declare -p _CADDYCTL_MODULES >/dev/null 2>&1 && ((${#_CADDYCTL_MODULES[@]} > 0)); then
        modules=("${_CADDYCTL_MODULES[@]}")
    else
        modules=(
            00-core.sh
            10-validate.sh
            20-config.sh
            30-service.sh
            40-lock-snapshot.sh
            50-sites.sh
            60-cmd-sites.sh
            70-cmd-ops.sh
        )
    fi
    local -a tmp_mods=()
    local mod tmp_mod

    url="${CADDYCTL_UPDATE_URL:-$DEFAULT_UPDATE_URL}"
    base_url="${url%/*}"
    lib_url="${base_url}/caddy-lib.sh"
    checksums_url="${CADDYCTL_CHECKSUMS_URL:-${base_url}/checksums.txt}"

    target_bin="/usr/local/bin/caddyctl"
    target_alias="/usr/local/bin/c"
    lib_bin="/usr/local/bin/caddy-lib.sh"
    lib_mod_dir="/usr/local/lib/caddyctl"

    tmp=""
    tmp_lib=""
    cleanup_update_temps() {
        cleanup_paths "${tmp:-}" "${tmp_lib:-}" "${tmp_mods[@]}"
    }
    # Ensure temps are removed even if update aborts unexpectedly.
    trap 'cleanup_update_temps' RETURN

    # 1) 下载并校验前端脚本
    tmp="$(mktemp)"
    say "正在下载: $url"
    if ! curl -fsSL --retry 3 --retry-delay 1 "$url" -o "$tmp"; then
        cleanup_update_temps
        fail "下载失败，请检查网络或 URL。"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        cleanup_update_temps
        fail "下载结果为空，已中止更新。"
        return 1
    fi
    if ! bash -n "$tmp"; then
        cleanup_update_temps
        fail "下载脚本语法校验失败，已中止更新。"
        return 1
    fi
    if ! verify_download_checksum "$tmp" "$(basename "$url")" "$checksums_url"; then
        cleanup_update_temps
        return 1
    fi

    # 2) 下载并校验共享库入口
    tmp_lib="$(mktemp)"
    say "正在下载: $lib_url"
    if ! curl -fsSL --retry 3 --retry-delay 1 "$lib_url" -o "$tmp_lib"; then
        cleanup_update_temps
        fail "共享库下载失败，已中止更新。"
        return 1
    fi
    if [[ ! -s "$tmp_lib" ]]; then
        cleanup_update_temps
        fail "共享库下载为空，已中止。"
        return 1
    fi
    if ! bash -n "$tmp_lib"; then
        cleanup_update_temps
        fail "共享库语法校验失败，已中止。"
        return 1
    fi
    if ! verify_download_checksum "$tmp_lib" "caddy-lib.sh" "$checksums_url"; then
        cleanup_update_temps
        return 1
    fi

    # 3) 下载并校验模块
    for mod in "${modules[@]}"; do
        tmp_mod="$(mktemp)"
        tmp_mods+=("$tmp_mod")
        say "正在下载: ${base_url}/lib/${mod}"
        if ! curl -fsSL --retry 3 --retry-delay 1 "${base_url}/lib/${mod}" -o "$tmp_mod"; then
            cleanup_update_temps
            fail "模块下载失败: $mod"
            return 1
        fi
        if [[ ! -s "$tmp_mod" ]]; then
            cleanup_update_temps
            fail "模块下载为空: $mod"
            return 1
        fi
        if ! bash -n "$tmp_mod"; then
            cleanup_update_temps
            fail "模块语法校验失败: $mod"
            return 1
        fi
        if ! verify_download_checksum "$tmp_mod" "lib/${mod}" "$checksums_url"; then
            cleanup_update_temps
            return 1
        fi
    done

    # 4) 全部通过后再安装
    install -d -m 0755 "$(dirname "$target_bin")"
    install -d -m 0755 "$lib_mod_dir"
    install -m 0755 "$tmp" "$target_bin"
    ln -sf "$target_bin" "$target_alias"
    install -m 0644 "$tmp_lib" "$lib_bin"

    local i=0
    for mod in "${modules[@]}"; do
        install -m 0644 "${tmp_mods[$i]}" "$lib_mod_dir/$mod"
        i=$((i + 1))
    done
    if [[ ! -f "$lib_mod_dir/00-core.sh" ]]; then
        cleanup_update_temps
        trap - RETURN
        fail "更新后缺少 $lib_mod_dir/00-core.sh，已中止（未清理旧入口，请重试）。"
        return 1
    fi
    cleanup_update_temps
    trap - RETURN

    say "更新完成:"
    say "  $target_bin"
    say "  $target_alias -> $target_bin"
    say "  $lib_bin"
    say "  $lib_mod_dir/*.sh"

    if (( update_binary == 1 )); then
        if ! update_caddy_binary_from_release; then
            fail "脚本已更新，但 Caddy 二进制更新失败。可稍后重试: c update --binary"
            return 1
        fi
    fi
}

# Download prebuilt caddy from GitHub Releases (checksums.txt entry: caddy).
update_caddy_binary_from_release() {
    require_command curl
    require_command sha256sum

    local ref tag asset_url checksums_url tmp expected actual target
    ref="${CADDY_CLI_REF:-${DEFAULT_REF:-main}}"
    tag="$ref"
    # Prefer explicit override, else GitHub release asset for this tag.
    asset_url="${CADDYCTL_BINARY_URL:-https://github.com/buglyz/caddy_cli/releases/download/${tag}/caddy}"
    checksums_url="${CADDYCTL_CHECKSUMS_URL:-${DEFAULT_BASE_URL:-https://raw.githubusercontent.com/buglyz/caddy_cli/${tag}}/checksums.txt}"
    # If DEFAULT_BASE_URL is a full file URL, strip filename
    if [[ "$checksums_url" == */caddy.sh ]]; then
        checksums_url="${checksums_url%/*}/checksums.txt"
    elif [[ "$checksums_url" != *checksums.txt ]]; then
        checksums_url="${checksums_url%/}/checksums.txt"
    fi

    target="$(command -v caddy 2>/dev/null || true)"
    if [[ -z "$target" ]]; then
        target="/usr/bin/caddy"
    fi

    tmp="$(mktemp)"
    say "正在下载 Caddy 二进制: $asset_url"
    if ! curl -fsSL --retry 3 --retry-delay 1 -L "$asset_url" -o "$tmp"; then
        cleanup_paths "$tmp"
        fail "下载 Caddy 二进制失败: $asset_url"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        cleanup_paths "$tmp"
        fail "Caddy 二进制下载为空"
        return 1
    fi

    if [[ "${CADDYCTL_SKIP_CHECKSUM:-0}" != "1" ]]; then
        if ! verify_download_checksum "$tmp" "caddy" "$checksums_url"; then
            cleanup_paths "$tmp"
            return 1
        fi
    else
        say "(Warning) 跳过 Caddy 二进制 SHA256 校验"
    fi

    chmod 755 "$tmp"
    # basic sanity: ELF or executable
    if ! head -c 4 "$tmp" | grep -q $'ELF' 2>/dev/null; then
        # still allow if file is large enough (cross-platform)
        if [[ "$(wc -c < "$tmp")" -lt 1000000 ]]; then
            cleanup_paths "$tmp"
            fail "下载内容不像有效的 caddy 二进制"
            return 1
        fi
    fi

    install -d -m 0755 "$(dirname "$target")"
    install -m 0755 "$tmp" "$target"
    cleanup_paths "$tmp"
    say "Caddy 二进制已更新: $target"
    if command_exists "$target"; then
        "$target" version 2>/dev/null | head -n 1 || true
    fi
    return 0
}

install_caddy_via_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
}

install_caddy_via_dnf() {
    if dnf install -y dnf5-plugins >/dev/null 2>&1; then
        :
    else
        dnf install -y dnf-plugins-core
    fi
    dnf -y copr enable @caddy/caddy
    dnf install -y caddy
}

install_caddy_via_pacman() {
    pacman -Sy --noconfirm caddy
}

install_caddy_via_apk() {
    if ! grep -q '^[^#]*community' /etc/apk/repositories 2>/dev/null; then
        local ver
        ver=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "3.21")
        say "启用 Alpine community 仓库..."
        echo "https://dl-cdn.alpinelinux.org/alpine/v${ver}/community" >> /etc/apk/repositories
    fi
    apk update
    apk add caddy
}


cmd_install() {
    local caddy_bin=""

    if caddy_bin="$(caddy_binary 2>/dev/null)"; then
        say "检测到 caddy 已安装: $caddy_bin ($(caddy_version_text))"
    elif command_exists apt-get; then
        say "检测到 apt-get，按 Caddy 官方文档安装稳定版。"
        install_caddy_via_apt
    elif command_exists dnf; then
        say "检测到 dnf，按 Caddy 官方文档安装稳定版。"
        install_caddy_via_dnf
    elif command_exists pacman; then
        say "检测到 pacman，按发行版仓库安装 Caddy。"
        install_caddy_via_pacman
    elif command_exists apk; then
        say "检测到 apk（Alpine），安装 Caddy..."
        install_caddy_via_apk
    else
        fail "当前系统未适配自动安装，请按 https://caddyserver.com/docs/install 手动安装"
        return 1
    fi

    ensure_dirs
    fix_permissions

    if current_script_path >/dev/null 2>&1; then
        cmd_install_self
    else
        say "未能自动安装脚本命令，请手动把脚本放到 /usr/local/bin/c 并赋予执行权限。"
    fi

    if service_ready; then
        svc_enable
        if has_any_config; then
            apply_config
        else
            svc_start || true
        fi
    fi

    say "安装完成"
}

cmd_show_help() {
    cat <<'EOF'
用法:
  c <命令> [参数]

────────────────────────────────
1) 站点（反代 / 静态）
────────────────────────────────
  c list
  c add <域名> <端口> [--http|--https] [--path <前缀>] [--dns-only] [--skip-dns-check]
  c add-static <域名> <目录> [--http|--https] [--spa] [--dns-only] [--skip-dns-check]
  c set <域名> [--port|--path|--root|--spa|--no-spa|--http|--https|--dns-only|--target]
  c set-static <域名> [--root <目录>] [--spa|--no-spa] [--http|--https] [--dns-only]
  c enable <域名>
  c disable <域名>
  c rm <域名>

  # set 会重建模板，并尽量保留自定义 header/basicauth/log；
  # 网关与 Emby 仅保留上述白名单指令。

────────────────────────────────
2) Emby / 通用网关
────────────────────────────────
  c list-emby
  c add-emby <域名> <目标> [--http|--https] [--dns-only] [--skip-dns-check]
  c set-emby <域名> [--target <地址>] [--http|--https] [--dns-only]
  c add-gateway <域名> --allow <host:port[,...]> [--http|--https] [--dns-only] [--skip-dns-check]
  c add-gateway <域名> --unsafe-open-proxy [...]
  c set-gateway <域名> [--allow ...|--unsafe-open-proxy] [--http|--https] [--dns-only]
  c rm-emby <域名或网关域名>

────────────────────────────────
3) 配置与导入
────────────────────────────────
  c config
  c validate
  c apply
  c email [邮箱]
  c timeout [秒|default]
  c upstream-mode [warn|strict]
  c import [--merge] [--force] [Caddyfile路径]
  # 默认替换 sites.d；--merge 合并保留现有站点；
  # 非交互覆盖需 --force 或 CADDYCTL_IMPORT_FORCE=1

────────────────────────────────
4) 服务控制
────────────────────────────────
  c start
  c restart
  c stop
  c status

────────────────────────────────
5) 诊断与备份
────────────────────────────────
  c doctor
  c logs
  c cert-check <域名>
  c snapshots [数量|all]
  c undo [快照ID]

────────────────────────────────
6) 安装与更新
────────────────────────────────
  c install
  c install-self
  c update [--binary]    # --binary 同时更新 Release 中的 caddy 可执行文件
  c menu                 # 交互菜单

说明:
  · 添加域名反代时会检查 A/AAAA 是否指向本机；内网/测试/橙云可加 --skip-dns-check
    或设置 CADDYCTL_SKIP_DNS_CHECK=1
  · 需要 DNS-01（泛域名 / 80 不可达）时加 --dns-only（CF 版）
  · 别名: ls=list, rm=del=delete, check=validate, reload=apply
           emby=add-emby, gateway=add-gateway
EOF
    _hook_help_extra
    cat <<'EOF'

────────────────────────────────
示例
────────────────────────────────
  # 普通站点
  c add app.example.com 3000
  c add app.example.com 3000 --path /api --dns-only
  c add-static www.example.com /var/www/site --spa
  c set app.example.com --port 4000
  c set-static www.example.com --root /var/www/new --https
  c disable app.example.com && c enable app.example.com

  # Emby / 网关
  c add-emby emby.example.com https://10.0.0.5:8096
  c set-emby emby.example.com --target https://10.0.0.6:8096
  c add-gateway gate.example.com --allow 10.0.0.5:8096,emby.example.com:443
  c set-gateway gate.example.com --allow 10.0.0.7:8096

  # 导入 / 更新
  c import --merge /etc/caddy/Caddyfile.bak
  c import --force /path/to/Caddyfile
  c update
  c update --binary

  # 诊断
  c doctor
  c cert-check app.example.com
  c snapshots 20
  c undo
EOF
}

restore_import_snapshot() {
    local sites_bak="$1"
    local globals_bak="$2"
    local state_bak="$3"
    local old_email="$4"

    clear_managed_dir "$SITES_DIR"
    clear_managed_dir "$GLOBALS_DIR"
    cp -a "$sites_bak"/. "$SITES_DIR"/ 2>/dev/null || true
    cp -a "$globals_bak"/. "$GLOBALS_DIR"/ 2>/dev/null || true
    cp -a "$state_bak" "$STATE_FILE" 2>/dev/null || true
    load_state
    fix_permissions
}

cmd_import() {
    require_command python3

    local merge_mode=0
    local force_mode=0
    local -a positional=()
    while (( $# > 0 )); do
        case "$1" in
            --merge) merge_mode=1 ;;
            --force) force_mode=1; CADDYCTL_IMPORT_FORCE=1 ;;
            --) shift; while (( $# > 0 )); do positional+=("$1"); shift; done; break ;;
            --*) fail "未知 import 参数: $1"; return 1 ;;
            *) positional+=("$1") ;;
        esac
        shift
    done
    local src="${positional[0]:-$CADDYFILE}"
    if [[ ! -f "$src" ]]; then
        fail "找不到源文件: $src"
        return 1
    fi

    # Replace mode clears managed dirs. Merge mode keeps existing files and only
    # adds/overwrites imported site confs + globals snippet.
    local existing_count=0
    shopt -s nullglob
    local _existing=("$SITES_DIR"/*.conf "$SITES_DIR"/*.conf.disabled "$GLOBALS_DIR"/*.inc)
    existing_count=${#_existing[@]}
    shopt -u nullglob
    if (( existing_count > 0 && merge_mode == 0 )); then
        say "警告: import 会清空并替换现有站点/全局片段（当前约 ${existing_count} 个文件）。"
        say "提示: 使用 --merge 可在保留现有站点的前提下合并导入。"
        if [[ "${CADDYCTL_IMPORT_FORCE:-0}" != "1" ]]; then
            if [[ -t 0 ]]; then
                if ! prompt_yes_no "确认继续导入并覆盖现有配置"; then
                    say "已取消导入"
                    return 1
                fi
            else
                fail "非交互环境检测到已有站点配置。覆盖请加 --force（或 CADDYCTL_IMPORT_FORCE=1），合并请加 --merge。"
                return 1
            fi
        else
            say "强制覆盖模式：跳过确认，继续导入。"
        fi
    fi
    if (( merge_mode == 1 )); then
        say "import --merge：保留现有站点，合并导入源中的站点块。"
    fi

    local sites_bak globals_bak state_bak old_email tmp_src meta fmt_bin
    local import_sites_dir import_globals_dir
    tmp_src="$(mktemp)"
    if ! cp -a "$src" "$tmp_src"; then
        cleanup_paths "$tmp_src"
        fail "无法复制导入源: $src"
        return 1
    fi
    if fmt_bin="$(caddy_binary 2>/dev/null)"; then
        "$fmt_bin" fmt --overwrite "$tmp_src" >/dev/null 2>&1 || true
    fi

    sites_bak="$(mktemp -d "$BACKUP_DIR/sites.XXXXXX")"
    globals_bak="$(mktemp -d "$BACKUP_DIR/globals.XXXXXX")"
    state_bak="$(mktemp "$BACKUP_DIR/state.XXXXXX")"
    old_email="${EMAIL:-}"

    cp -a "$SITES_DIR"/. "$sites_bak"/ 2>/dev/null || true
    cp -a "$GLOBALS_DIR"/. "$globals_bak"/ 2>/dev/null || true
    cp -a "$STATE_FILE" "$state_bak" 2>/dev/null || true

    import_sites_dir="$SITES_DIR"
    import_globals_dir="$GLOBALS_DIR"
    if (( merge_mode == 1 )); then
        import_sites_dir="$(mktemp -d "$BACKUP_DIR/import-sites.XXXXXX")"
        import_globals_dir="$(mktemp -d "$BACKUP_DIR/import-globals.XXXXXX")"
    else
        clear_managed_dir "$SITES_DIR"
        clear_managed_dir "$GLOBALS_DIR"
    fi

    meta="$(python3 - "$tmp_src" "$import_globals_dir" "$import_sites_dir" <<'PY'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])
globals_dir = Path(sys.argv[2])
sites_dir = Path(sys.argv[3])

text = src.read_text(encoding="utf-8", errors="ignore")
lines = text.splitlines()

def strip_comments(s: str) -> str:
    out = []
    in_sq = False
    in_dq = False
    esc = False
    for ch in s:
        if ch == "#" and not in_sq and not in_dq:
            break
        out.append(ch)
        if ch == '"' and not in_sq and not esc:
            in_dq = not in_dq
        elif ch == "'" and not in_dq and not esc:
            in_sq = not in_sq
        esc = (ch == "\\" and not esc)
        if ch != "\\":
            esc = False
    return "".join(out)

def brace_countable(s: str) -> str:
    out = []
    in_sq = False
    in_dq = False
    esc = False
    for ch in s:
        if ch == "#" and not in_sq and not in_dq:
            break
        if (in_sq or in_dq) and ch in "{}":
            out.append(" ")
        else:
            out.append(ch)
        if ch == '"' and not in_sq and not esc:
            in_dq = not in_dq
        elif ch == "'" and not in_dq and not esc:
            in_sq = not in_sq
        esc = (ch == "\\" and not esc)
        if ch != "\\":
            esc = False
    return "".join(out)

blocks = []
buf = []
depth = 0
started = False

for line in lines:
    clean = strip_comments(line)
    counted = brace_countable(line)
    if not started and clean.strip() == "":
        continue
    if not started:
        started = True
    buf.append(line)
    depth += counted.count("{") - counted.count("}")
    if started and depth == 0 and buf:
        blocks.append(buf)
        buf = []
        started = False

if buf:
    blocks.append(buf)

global_lines = []
site_blocks = []
found_email = ""
email_re = re.compile(r"^\s*email\s+(\S+)\s*$")

for block in blocks:
    first = next((strip_comments(x).strip() for x in block if strip_comments(x).strip()), "")
    if not first:
        continue

    if first.startswith("{"):
        inner = block[1:-1] if len(block) >= 2 else []
        for ln in inner:
            raw = ln.rstrip()
            if not raw.strip():
                global_lines.append("")
                continue
            uncommented = strip_comments(raw).strip()
            match = email_re.match(uncommented)
            if match and not found_email:
                found_email = match.group(1).strip()
                continue
            if re.match(r"^email(\s|$)", uncommented):
                print(f"Invalid global email directive: {raw.strip()}", file=sys.stderr)
                sys.exit(1)
            global_lines.append(raw)
    else:
        site_blocks.append(block)

(globals_dir / "00-imported.inc").write_text(
    "\n".join(global_lines).rstrip() + ("\n" if global_lines else ""),
    encoding="utf-8",
)

def slugify(label: str) -> str:
    label = strip_comments(label).strip()
    label = label.split("{", 1)[0].strip()
    label = label.replace(",", "_")
    label = re.sub(r"[^A-Za-z0-9._-]+", "_", label)
    label = re.sub(r"_+", "_", label).strip("_")
    return label or "site"

for block in site_blocks:
    header = next((x for x in block if strip_comments(x).strip()), "")
    name = slugify(header)
    path = sites_dir / f"{name}.conf"
    if path.exists():
        existing = path.read_text(encoding="utf-8", errors="ignore").strip()
        new_content = "\n".join(block).strip()
        if existing != new_content:
            n = 1
            while True:
                alt = sites_dir / f"{name}-{n}.conf"
                if not alt.exists():
                    path = alt
                    break
                n += 1
    path.write_text("\n".join(block).rstrip() + "\n", encoding="utf-8")

print(f"EMAIL={found_email}")
PY
    )" || {
        fail "导入失败，正在回滚目录。"
        restore_import_snapshot "$sites_bak" "$globals_bak" "$state_bak" "$old_email"
        cleanup_paths "$sites_bak" "$globals_bak" "$tmp_src" "$state_bak" "${import_sites_dir:-}" "${import_globals_dir:-}"
        return 1
    }

    if (( merge_mode == 1 )); then
        # Copy imported site files into live dir (overwrite same basename).
        local f base
        shopt -s nullglob
        for f in "$import_sites_dir"/*.conf; do
            base="$(basename "$f")"
            cp -a "$f" "$SITES_DIR/$base"
            say "合并站点: $base"
        done
        # Merge globals: append imported global snippet as 00-imported.inc (overwrite that name only)
        if [[ -f "$import_globals_dir/00-imported.inc" ]]; then
            cp -a "$import_globals_dir/00-imported.inc" "$GLOBALS_DIR/00-imported.inc"
            say "合并全局片段: 00-imported.inc"
        fi
        shopt -u nullglob
        cleanup_paths "$import_sites_dir" "$import_globals_dir"
    fi

    if [[ "$meta" =~ ^EMAIL=(.*)$ ]]; then
        EMAIL="${BASH_REMATCH[1]}"
        if ! validate_email "$EMAIL"; then
            fail "导入的全局 email 不合法: $EMAIL"
            restore_import_snapshot "$sites_bak" "$globals_bak" "$state_bak" "$old_email"
            cleanup_paths "$sites_bak" "$globals_bak" "$tmp_src" "$state_bak"
            return 1
        fi
        save_state
    else
        fail "导入元数据缺少 EMAIL 字段"
        restore_import_snapshot "$sites_bak" "$globals_bak" "$state_bak" "$old_email"
        cleanup_paths "$sites_bak" "$globals_bak" "$tmp_src" "$state_bak"
        return 1
    fi

    if ! apply_config; then
        fail "导入后应用失败，正在回滚目录。"
        restore_import_snapshot "$sites_bak" "$globals_bak" "$state_bak" "$old_email"
        cleanup_paths "$sites_bak" "$globals_bak" "$tmp_src" "$state_bak"
        return 1
    fi

    cleanup_paths "$sites_bak" "$globals_bak" "$tmp_src" "$state_bak"
    say "导入完成"
}


pause_menu() {
    echo
    read -rp "按回车继续..." _
}

show_menu_header() {
    local title="$1"
    clear
    echo "====== $title ======"
}

menu_main() {
    show_menu_header "Caddy CLI 管理面板"
    echo ""
    echo "【站点】"
    echo "1. 站点管理（反代 / 静态）"
    echo "2. Emby / 网关"
    echo "3. 查看所有站点"
    echo ""
    echo "【运维】"
    echo "4. 服务状态"
    echo "5. 实时日志"
    echo "6. 服务与配置"
    echo "7. 诊断与备份"
    echo ""
    echo "【系统】"
    echo "8. 安装与更新"
    echo ""
    echo "0. 退出"
    echo "============================"
}

menu_sites() {
    show_menu_header "站点管理 · 反代 / 静态"
    echo ""
    echo "【查看】"
    echo "1. 查看所有站点"
    echo ""
    echo "【添加】"
    echo "2. 添加反向代理"
    echo "3. 添加静态网站"
    echo ""
    echo "【修改】"
    echo "4. 修改站点（set / set-static）"
    echo "5. 启用 / 禁用站点"
    echo "6. 删除站点"
    echo ""
    echo "0. 返回上一级"
    echo "======================"
}

menu_emby() {
    show_menu_header "Emby / 通用网关"
    echo ""
    echo "【查看】"
    echo "1. 查看 Emby 与网关"
    echo ""
    echo "【添加】"
    echo "2. 添加 Emby 固定反代"
    echo "3. 添加通用反代网关"
    echo ""
    echo "【修改】"
    echo "4. 修改 Emby / 网关"
    echo "5. 删除 Emby / 网关"
    echo ""
    echo "0. 返回上一级"
    echo "======================"
}

menu_config() {
    show_menu_header "服务与配置"
    echo ""
    echo "【服务】"
    echo "1. 启动 Caddy"
    echo "2. 重启 Caddy"
    echo "3. 停止 Caddy"
    echo "4. 查看服务状态"
    echo ""
    echo "【配置】"
    echo "5. 查看当前 Caddyfile"
    echo "6. 校验并应用配置"
    echo "7. 全局设置（邮箱 / 超时 / 上游）"
    echo ""
    echo "【导入】"
    echo "8. 导入配置（替换 sites.d）"
    echo "9. 合并导入（--merge）"
    echo ""
    _hook_menu_config_items
    echo "0. 返回上一级"
    echo "======================"
}

menu_diagnostics() {
    show_menu_header "诊断与备份"
    echo ""
    echo "【诊断】"
    echo "1. 环境检查（doctor）"
    echo "2. 查看 Caddy 日志"
    echo "3. 证书诊断"
    echo ""
    echo "【备份回滚】"
    echo "4. 查看回滚快照"
    echo "5. 回滚到上一步 / 指定快照"
    echo ""
    echo "0. 返回上一级"
    echo "======================"
}

menu_install() {
    show_menu_header "安装与更新"
    echo ""
    echo "1. 安装 / 初始化 Caddy"
    echo "2. 安装本机 CLI 命令（install-self）"
    echo "3. 更新 CLI 脚本与模块"
    echo "4. 更新 CLI + Caddy 二进制（--binary）"
    echo ""
    echo "0. 返回上一级"
    echo "======================"
}

interactive_sites_menu() {
    local choice=""
    while true; do
        menu_sites
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_list ;;
            2) require_command caddy; with_global_lock run_mutation add cmd_add ;;
            3) require_command caddy; with_global_lock run_mutation add-static cmd_add_static ;;
            4) require_command caddy; with_global_lock run_mutation set cmd_set ;;
            5) require_command caddy; with_global_lock run_mutation toggle cmd_toggle_site ;;
            6) require_command caddy; with_global_lock run_mutation rm cmd_rm ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_emby_menu() {
    local choice=""
    while true; do
        menu_emby
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_list_emby ;;
            2) require_command caddy; with_global_lock run_mutation add-emby cmd_add_emby ;;
            3) require_command caddy; with_global_lock run_mutation add-gateway cmd_add_gateway ;;
            4) require_command caddy; with_global_lock run_mutation set-emby cmd_set_emby ;;
            5) require_command caddy; with_global_lock run_mutation rm-emby cmd_rm_emby ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_config_menu() {
    local choice=""
    while true; do
        menu_config
        read -rp "选择: " choice
        case "$choice" in
            1) with_global_lock cmd_start ;;
            2) with_global_lock cmd_restart ;;
            3) with_global_lock cmd_stop ;;
            4) cmd_status ;;
            5) cmd_config ;;
            6) require_command caddy; with_global_lock run_mutation validate-apply cmd_validate_and_apply ;;
            7) cmd_settings_menu ;;
            8) require_command caddy; with_global_lock run_mutation import cmd_import ;;
            9) require_command caddy; with_global_lock run_mutation import-merge cmd_import --merge ;;
            0) return 0 ;;
            *)
                if _hook_menu_config_handler "$choice"; then
                    :
                else
                    fail "无效输入"
                fi
                ;;
        esac
        pause_menu
    done
}

interactive_diagnostics_menu() {
    local choice=""
    while true; do
        menu_diagnostics
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_doctor ;;
            2) cmd_logs ;;
            3) cmd_cert_check ;;
            4) cmd_snapshots ;;
            5) require_command caddy; with_global_lock cmd_undo ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_install_menu() {
    local choice=""
    while true; do
        menu_install
        read -rp "选择: " choice
        case "$choice" in
            1) with_global_lock cmd_install ;;
            2) with_global_lock cmd_install_self ;;
            3) with_global_lock cmd_update ;;
            4) with_global_lock cmd_update --binary ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_menu() {
    local choice=""
    while true; do
        menu_main
        read -rp "选择: " choice
        case "$choice" in
            1) interactive_sites_menu ;;
            2) interactive_emby_menu ;;
            3) cmd_list; pause_menu ;;
            4) cmd_status; pause_menu ;;
            5) cmd_logs; pause_menu ;;
            6) interactive_config_menu ;;
            7) interactive_diagnostics_menu ;;
            8) interactive_install_menu ;;
            0) exit 0 ;;
            *) fail "无效输入"; pause_menu ;;
        esac
    done
}


main() {
    show_menu_header "Caddy CLI 管理面板"
    echo ""
    echo "【快速操作】"
    echo "1. 查看所有站点状态"
    echo "2. 重启 Caddy 服务"
    echo "3. 查看实时日志"
    echo ""
    echo "【站点管理】"
    echo "4. 站点管理"
    echo "5. Emby 专用管理"
    echo ""
    echo "【系统管理】"
    echo "6. 服务与配置"
    echo "7. 诊断与维护"
    echo "8. 安装与更新"
    echo ""
    echo "0. 退出"
    echo "============================"
}

menu_sites() {
    show_menu_header "站点管理"
    echo ""
    echo "【查看】"
    echo "1. 查看所有站点"
    echo ""
    echo "【添加站点】"
    echo "2. 添加反向代理"
    echo "3. 添加静态网站"
    echo ""
    echo "【管理站点】"
    echo "4. 修改站点配置"
    echo "5. 启用/禁用站点"
    echo "6. 删除站点"
    echo ""
    echo "0. 返回上一级"
    echo "======================"
}

menu_emby() {
    show_menu_header "Emby 专用管理"
    echo ""
    echo "【查看】"
    echo "1. 查看 Emby 配置"
    echo ""
    echo "【添加】"
    echo "2. 添加固定反代"
    echo "3. 添加通用网关"
    echo ""
    echo "【管理】"
    echo "4. 修改配置"
    echo "5. 删除配置"
    echo ""
    echo "0. 返回上一级"
    echo "======================"
}

menu_config() {
    show_menu_header "服务与配置"
    echo ""
    echo "【服务控制】"
    echo "1. 启动 Caddy"
    echo "2. 重启 Caddy"
    echo "3. 停止 Caddy"
    echo "4. 查看服务状态"
    echo ""
    echo "【配置管理】"
    echo "5. 查看当前配置"
    echo "6. 校验并应用配置"
    echo "7. 配置设置（邮箱/超时/上游）"
    echo ""
    echo "【高级操作】"
    echo "8. 导入现有配置"
    echo ""
    _hook_menu_config_items
    echo "0. 返回上一级"
    echo "======================"
}

menu_diagnostics() {
    show_menu_header "诊断与维护"
    echo ""
    echo "【诊断工具】"
    echo "1. 环境检查"
    echo "2. 查看 Caddy 日志"
    echo "3. 证书诊断"
    echo ""
    echo "【备份回滚】"
    echo "4. 查看回滚快照"
    echo "5. 回滚到上一步"
    echo ""
    echo "0. 返回上一级"
    echo "======================"
}

menu_install() {
    show_menu_header "安装与更新"
    echo "1. 安装/初始化 Caddy"
    echo "2. 安装脚本命令"
    echo "3. 更新脚本"
    echo "0. 返回上一级"
    echo "======================"
}

interactive_sites_menu() {
    local choice=""
    while true; do
        menu_sites
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_list ;;
            2) require_command caddy; with_global_lock run_mutation add cmd_add ;;
            3) require_command caddy; with_global_lock run_mutation add-static cmd_add_static ;;
            4) require_command caddy; with_global_lock run_mutation set cmd_set ;;
            5) require_command caddy; with_global_lock run_mutation toggle cmd_toggle_site ;;
            6) require_command caddy; with_global_lock run_mutation rm cmd_rm ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_emby_menu() {
    local choice=""
    while true; do
        menu_emby
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_list_emby ;;
            2) require_command caddy; with_global_lock run_mutation add-emby cmd_add_emby ;;
            3) require_command caddy; with_global_lock run_mutation add-gateway cmd_add_gateway ;;
            4) require_command caddy; with_global_lock run_mutation set-emby cmd_set_emby ;;
            5) require_command caddy; with_global_lock run_mutation rm-emby cmd_rm_emby ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_config_menu() {
    local choice=""
    while true; do
        menu_config
        read -rp "选择: " choice
        case "$choice" in
            1) with_global_lock cmd_start ;;
            2) with_global_lock cmd_restart ;;
            3) with_global_lock cmd_stop ;;
            4) cmd_status ;;
            5) cmd_config ;;
            6) require_command caddy; with_global_lock run_mutation validate-apply cmd_validate_and_apply ;;
            7) cmd_settings_menu ;;
            8) require_command caddy; with_global_lock run_mutation import cmd_import ;;
            0) return 0 ;;
            *) _hook_menu_config_handler "$choice" && continue ;&
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_diagnostics_menu() {
    local choice=""
    while true; do
        menu_diagnostics
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_doctor ;;
            2) cmd_logs ;;
            3) cmd_cert_check ;;
            4) cmd_snapshots ;;
            5) require_command caddy; with_global_lock cmd_undo ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_install_menu() {
    local choice=""
    while true; do
        menu_install
        read -rp "选择: " choice
        case "$choice" in
            1) with_global_lock cmd_install ;;
            2) with_global_lock cmd_install_self ;;
            3) with_global_lock cmd_update ;;
            0) return 0 ;;
            *) fail "无效输入" ;;
        esac
        pause_menu
    done
}

interactive_menu() {
    local choice=""
    while true; do
        menu_main
        read -rp "选择: " choice
        case "$choice" in
            1) cmd_list; pause_menu ;;
            2) with_global_lock cmd_restart; pause_menu ;;
            3) cmd_logs; pause_menu ;;
            4) interactive_sites_menu ;;
            5) interactive_emby_menu ;;
            6) interactive_config_menu ;;
            7) interactive_diagnostics_menu ;;
            8) interactive_install_menu ;;
            0) exit 0 ;;
            *) fail "无效输入"; pause_menu ;;
        esac
    done
}

main() {
    local cmd="${1:-}"

    # Pure help never needs root or /etc side effects.
    case "$cmd" in
        help|-h|--help)
            cmd_show_help
            return 0
            ;;
        cloudflare|cf)
            case "${2:-}" in
                ""|status|show|check)
                    # Read-only Cloudflare status — no root, no mutation lock required.
                    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                        ensure_dirs
                        load_state
                    else
                        [[ -r "$STATE_FILE" ]] && load_state
                    fi
                    require_command caddy
                    # Shift is handled inside hook path; call cmd_cloudflare directly if available.
                    if declare -F cmd_cloudflare >/dev/null 2>&1; then
                        cmd_cloudflare "${2:-}"
                    else
                        fail "当前不是 Cloudflare 版 CLI（缺少 cloudflare 子命令）"
                        return 1
                    fi
                    return 0
                    ;;
            esac
            ;;
    esac

    # Read-only commands: allow non-root best-effort inspection.
    case "$cmd" in
        list|ls|list-emby|emby-list|status|logs|snapshots|snapshot|config|cat|validate|check|doctor|check-env|cert-check)
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                ensure_dirs
                load_state
            else
                if [[ -r "$STATE_FILE" ]]; then
                    load_state
                fi
            fi
            case "$cmd" in
                list|ls) cmd_list ;;
                list-emby|emby-list) shift; cmd_list_emby "$@" ;;
                status) cmd_status ;;
                logs) cmd_logs ;;
                snapshots|snapshot) shift; cmd_snapshots "${1:-20}" ;;
                config|cat) cmd_config ;;
                validate|check) require_command caddy; cmd_validate ;;
                doctor|check-env) cmd_doctor ;;
                cert-check) shift; cmd_cert_check "${1:-}" ;;
            esac
            return 0
            ;;
    esac

    require_root

    ensure_dirs
    load_state
    fix_permissions

    case "$cmd" in
        install) with_global_lock cmd_install ;;
        install-self|self-install) with_global_lock cmd_install_self ;;
        update) shift; with_global_lock cmd_update "$@" ;;
        add) shift; require_command caddy; with_global_lock run_mutation add cmd_add "$@" ;;
        add-static|static) shift; require_command caddy; with_global_lock run_mutation add-static cmd_add_static "$@" ;;
        add-emby|emby) shift; require_command caddy; with_global_lock run_mutation add-emby cmd_add_emby "$@" ;;
        add-gateway|gateway) shift; require_command caddy; with_global_lock run_mutation add-gateway cmd_add_gateway "$@" ;;
        set-emby) shift; require_command caddy; with_global_lock run_mutation set-emby cmd_set_emby_site "$@" ;;
        set-gateway) shift; require_command caddy; with_global_lock run_mutation set-gateway cmd_set_gateway "$@" ;;
        rm-emby|del-emby|delete-emby) shift; require_command caddy; with_global_lock run_mutation rm-emby cmd_rm_emby "$@" ;;
        set) shift; require_command caddy; with_global_lock run_mutation set cmd_set "$@" ;;
        set-static) shift; require_command caddy; with_global_lock run_mutation set-static cmd_set_static "$@" ;;
        rm|del|delete) shift; require_command caddy; with_global_lock run_mutation rm cmd_rm "${1:-}" ;;
        enable) shift; require_command caddy; with_global_lock run_mutation enable cmd_enable "${1:-}" ;;
        disable) shift; require_command caddy; with_global_lock run_mutation disable cmd_disable "${1:-}" ;;
        email) shift; require_command caddy; with_global_lock run_mutation email cmd_email "${1:-}" ;;
        timeout) shift; with_global_lock run_mutation timeout cmd_timeout "${1:-}" ;;
        upstream-mode) shift; with_global_lock run_mutation upstream-mode cmd_upstream_mode "${1:-}" ;;
        import) shift; require_command caddy; with_global_lock run_mutation import cmd_import "$@" ;;
        apply|reload) require_command caddy; with_global_lock run_mutation apply cmd_apply ;;
        undo) shift; require_command caddy; with_global_lock cmd_undo "${1:-latest}" ;;
        start) with_global_lock cmd_start ;;
        restart) with_global_lock cmd_restart ;;
        stop) with_global_lock cmd_stop ;;
        ""|menu) interactive_menu ;;
        *)
            if _hook_cli_command "$@"; then
                exit 0
            fi
            fail "未知命令: $cmd"
            cmd_show_help
            exit 1
            ;;
    esac
}
