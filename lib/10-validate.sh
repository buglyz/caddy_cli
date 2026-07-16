# caddyctl library module: 10-validate.sh
# shellcheck shell=bash
sanitize_name() {
    printf '%s\n' "$1" | tr '/: ,' '____' | tr -cd 'A-Za-z0-9._-'
}

is_site_enabled() {
    local file="$1"
    [[ "$file" == *.conf ]]
}

site_file_status() {
    local file="$1"
    if is_site_enabled "$file"; then
        echo "启用"
    else
        echo "禁用"
    fi
}

validate_site_label() {
    local label="$1"
    local part
    label="$(trim "$label")"
    [[ -n "$label" ]] || return 1
    [[ "$label" != *$'\r'* ]] || return 1
    [[ "$label" != *$'\n'* ]] || return 1
    [[ "$label" != *"{"* ]] || return 1
    [[ "$label" != *"}"* ]] || return 1
    [[ "$label" != *"\""* ]] || return 1
    [[ "$label" != *"'"* ]] || return 1
    [[ "$label" != *";"* ]] || return 1
    [[ "$label" != *"#"* ]] || return 1
    [[ "$label" != *"\\"* ]] || return 1

    IFS=',' read -ra parts <<< "$label"
    for part in "${parts[@]}"; do
        part="$(trim "$part")"
        [[ -n "$part" ]] || return 1
        [[ "$part" != *[[:space:]]* ]] || return 1
        validate_domain "$part" || return 1
    done
    return 0
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

validate_email() {
    local email="$1"
    local local_part domain_part

    [[ -z "$email" ]] && return 0 # 允许空值用于清除 email
    [[ "$email" != *$'\r'* ]] || return 1
    [[ "$email" != *$'\n'* ]] || return 1
    [[ "$email" != *[[:space:]]* ]] || return 1
    [[ "$email" == *@* ]] || return 1
    [[ "$email" != *@*@* ]] || return 1

    local_part="${email%@*}"
    domain_part="${email#*@}"
    [[ -n "$local_part" && -n "$domain_part" ]] || return 1
    [[ ${#local_part} -le 64 ]] || return 1
    [[ "$local_part" =~ ^[A-Za-z0-9._%+-]+$ ]] || return 1
    [[ "$local_part" != .* && "$local_part" != *. ]] || return 1
    [[ "$local_part" != *..* ]] || return 1
    validate_domain "$domain_part"
}

validate_domain() {
    local domain="$1"
    local label
    [[ -n "$domain" ]] || return 1
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != *..* ]] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS='.' read -ra labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" ]] || return 1
        [[ ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_ip_address() {
    local ip="$1"
    local octet
    local -a octets=()
    local -a numbers=()

    ip="${ip%%%*}"
    [[ -n "$ip" ]] || return 1

    if command_exists python3; then
        python3 - "$ip" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.ip_address(sys.argv[1]).compressed.lower())
except ValueError:
    sys.exit(1)
PY
        return $?
    fi

    if [[ "$ip" == *:* ]]; then
        [[ "$ip" != *.* ]] || return 1
        [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        [[ "$ip" == *[0-9A-Fa-f]* ]] || return 1
        printf '%s\n' "${ip,,}"
        return 0
    fi

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 0 <= 10#$octet && 10#$octet <= 255 )) || return 1
        numbers+=("$((10#$octet))")
    done
    printf '%s.%s.%s.%s\n' "${numbers[0]}" "${numbers[1]}" "${numbers[2]}" "${numbers[3]}"
    return 0
}

looks_like_ip_address() {
    normalize_ip_address "$1" >/dev/null 2>&1
}

ip_is_public_candidate() {
    local ip="$1"
    local normalized

    normalized="$(normalize_ip_address "$ip" 2>/dev/null)" || return 1
    ip="$normalized"
    case "$ip" in
        127.*|10.*|169.254.*|192.168.*|0.*|255.*) return 1 ;;
        172.*)
            local second="${ip#172.}"
            second="${second%%.*}"
            if [[ "$second" =~ ^[0-9]+$ ]] && (( 16 <= 10#$second && 10#$second <= 31 )); then
                return 1
            fi
            ;;
        ::1|fe80:*|fc*|fd*) return 1 ;;
    esac
    return 0
}

local_ip_addresses() {
    local token ip

    printf '%s\n' 127.0.0.1 ::1
    if command_exists hostname; then
        for token in $(hostname -I 2>/dev/null || true); do
            token="${token%%%*}"
            [[ -n "$token" ]] && printf '%s\n' "$token"
        done
    fi
    if command_exists ip; then
        while IFS= read -r ip; do
            ip="${ip%%/*}"
            ip="${ip%%%*}"
            [[ -n "$ip" ]] && printf '%s\n' "$ip"
        done < <(ip -o addr show scope global 2>/dev/null | awk '{ print $4 }')
        while IFS= read -r ip; do
            ip="${ip%%/*}"
            ip="${ip%%%*}"
            [[ -n "$ip" ]] && printf '%s\n' "$ip"
        done < <(ip -o addr show scope host 2>/dev/null | awk '{ print $4 }')
    fi
}

public_ip_addresses() {
    local ip url

    if command_exists curl; then
        for url in \
            "https://api.ipify.org" \
            "https://ifconfig.me/ip" \
            "https://icanhazip.com"; do
            ip="$(curl -4fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ -n "$ip" ]] && ip_is_public_candidate "$ip"; then
                printf '%s\n' "$ip"
                break
            fi
        done
        for url in \
            "https://api64.ipify.org" \
            "https://icanhazip.com"; do
            ip="$(curl -6fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ -n "$ip" ]] && ip_is_public_candidate "$ip"; then
                printf '%s\n' "$ip"
                break
            fi
        done
    fi
}

dns_resolver_available() {
    command_exists getent || command_exists dig || command_exists host || command_exists nslookup
}

resolve_domain_addresses() {
    local domain="$1"

    if command_exists getent; then
        getent ahosts "$domain" 2>/dev/null | awk '{ print $1 }'
    fi
    if command_exists dig; then
        dig +short A "$domain" 2>/dev/null
        dig +short AAAA "$domain" 2>/dev/null
    fi
    if command_exists host; then
        host "$domain" 2>/dev/null | awk '/ has address / { print $4 } / has IPv6 address / { print $5 }'
    fi
    if command_exists nslookup; then
        nslookup "$domain" 2>/dev/null \
            | awk 'BEGIN { answer=0 } /^Name:/ { answer=1; next } answer && /^Address([[:space:]][0-9]+)?:[[:space:]]/ { print $NF }'
    fi
}

join_by_comma() {
    local IFS=", "
    printf '%s' "$*"
}

check_domain_points_to_local() {
    local domain="$1"
    local resolved_ips local_ips
    local ip local_ip normalized
    local found=0
    local -a resolved=()
    local -a locals=()

    domain="$(trim "$domain")"
    [[ -n "$domain" ]] || return 1

    if ! dns_resolver_available; then
        fail "缺少 DNS 查询工具，不能确认域名解析是否指向本机: $domain"
        say "请安装 getent、dig、host 或 nslookup 后重试；内网、测试或 Cloudflare 代理场景可加 --skip-dns-check。"
        return 1
    fi

    while IFS= read -r ip; do
        normalized="$(normalize_ip_address "$ip" 2>/dev/null)" || continue
        resolved+=("$normalized")
    done < <(resolve_domain_addresses "$domain" | awk 'NF')

    if (( ${#resolved[@]} == 0 )); then
        fail "域名未解析到任何 A/AAAA 记录: $domain"
        say "请确认 DNS 生效后重试；内网、测试或 Cloudflare 代理场景可加 --skip-dns-check。"
        return 1
    fi

    while IFS= read -r ip; do
        normalized="$(normalize_ip_address "$ip" 2>/dev/null)" || continue
        locals+=("$normalized")
    done < <(local_ip_addresses | awk 'NF')

    for ip in "${resolved[@]}"; do
        for local_ip in "${locals[@]}"; do
            if [[ "$ip" == "$local_ip" ]]; then
                found=1
                break 2
            fi
        done
    done

    if (( found )); then
        return 0
    fi

    while IFS= read -r ip; do
        normalized="$(normalize_ip_address "$ip" 2>/dev/null)" || continue
        locals+=("$normalized")
    done < <(public_ip_addresses | awk 'NF')

    for ip in "${resolved[@]}"; do
        for local_ip in "${locals[@]}"; do
            if [[ "$ip" == "$local_ip" ]]; then
                found=1
                break 2
            fi
        done
    done

    if (( found )); then
        return 0
    fi

    if (( ${#locals[@]} == 0 )); then
        fail "无法获取本机 IP，不能确认域名解析是否指向本机: $domain"
        say "内网、测试或 Cloudflare 代理场景可加 --skip-dns-check 或设置 CADDYCTL_SKIP_DNS_CHECK=1。"
        return 1
    fi

    resolved_ips="$(join_by_comma "${resolved[@]}")"
    local_ips="$(join_by_comma "${locals[@]}")"
    fail "域名未解析到本机: $domain"
    say "域名解析结果: ${resolved_ips:-<无>}"
    say "本机 IP: ${local_ips:-<未知>}"
    say "请将 DNS A/AAAA 记录指向本机后重试；内网、测试或 Cloudflare 代理场景可加 --skip-dns-check 或设置 CADDYCTL_SKIP_DNS_CHECK=1。"
    return 1
}

check_site_dns_points_to_local() {
    local label="$1"
    local part
    local -a parts=()

    if is_truthy "${CADDYCTL_SKIP_DNS_CHECK:-0}"; then
        return 0
    fi

    IFS=',' read -ra parts <<< "$label"
    for part in "${parts[@]}"; do
        part="$(trim "$part")"
        [[ -n "$part" ]] || continue
        if ! check_domain_points_to_local "$part"; then
            return 1
        fi
    done
    return 0
}

validate_static_dir() {
    local dir="$1"
    [[ -n "$dir" ]] || return 1
    [[ "$dir" != *$'\r'* ]] || return 1
    [[ "$dir" != *$'\n'* ]] || return 1
    return 0
}

caddyfile_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

validate_path_prefix() {
    local prefix="$1"
    [[ -n "$prefix" ]] || return 1
    [[ "$prefix" == /* ]] || return 1
    [[ "$prefix" != "/" ]] || return 1
    [[ "$prefix" != *[[:space:]]* ]] || return 1
    [[ "$prefix" != *"{"* ]] || return 1
    [[ "$prefix" != *"}"* ]] || return 1
    [[ "$prefix" != *"\""* ]] || return 1
    [[ "$prefix" != *"'"* ]] || return 1
    [[ "$prefix" != *";"* ]] || return 1
    [[ "$prefix" != *"#"* ]] || return 1
    [[ "$prefix" != *"\\"* ]] || return 1
    return 0
}

validate_gateway_upstream() {
    local upstream="$1"
    local host port
    [[ -n "$upstream" ]] || return 1
    [[ "$upstream" != *$'\r'* ]] || return 1
    [[ "$upstream" != *$'\n'* ]] || return 1
    [[ "$upstream" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
    [[ "$upstream" == *:* ]] || return 1
    host="${upstream%:*}"
    port="${upstream##*:}"
    [[ -n "$host" ]] || return 1
    validate_port "$port"
}

validate_proxy_target() {
    local target="$1"
    [[ -n "$target" ]] || return 1
    [[ "$target" == http://* || "$target" == https://* ]] || return 1
    [[ "$target" != *[[:space:]]* ]] || return 1
    [[ "$target" != *"{"* ]] || return 1
    [[ "$target" != *"}"* ]] || return 1
    [[ "$target" != *"\""* ]] || return 1
    [[ "$target" != *"'"* ]] || return 1
}

regex_escape() {
    printf '%s' "$1" | sed 's/[][(){}.^$+*?|\\]/\\&/g'
}

gateway_allow_regex() {
    local spec="$1"
    local item escaped out=""
    local -a items=()

    IFS=',' read -ra items <<< "$spec"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [[ -n "$item" ]] || continue
        if ! validate_gateway_upstream "$item"; then
            fail "网关 allow-list 条目不合法: $item（请使用 host:port）"
            return 1
        fi
        escaped="$(regex_escape "$item")"
        out="${out:+$out|}$escaped"
    done

    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

extract_gateway_allow_spec() {
    local file="$1"
    sed -n 's/^# 上游限制: 仅允许: //p' "$file" | head -n 1
}

extract_gateway_scheme() {
    local file="$1"
    local label

    label="$(extract_primary_site_label_from_file "$file" 2>/dev/null || true)"
    if [[ "$label" == http://* ]]; then
        printf '%s' "http"
    else
        printf '%s' "https"
    fi
}

normalize_path_prefix() {
    local prefix
    prefix="$(trim "$1")"
    prefix="${prefix%\*}"
    prefix="${prefix%/}"
    [[ -n "$prefix" ]] || prefix="/"
    printf '%s' "$prefix"
}

has_any_config() {
    if [[ -n "${EMAIL:-}" ]]; then
        return 0
    fi
    compgen -G "$SITES_DIR/*.conf" >/dev/null 2>&1 && return 0
    compgen -G "$GLOBALS_DIR/*.inc" >/dev/null 2>&1 && return 0
    return 1
}
