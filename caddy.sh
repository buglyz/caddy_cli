#!/usr/bin/env bash
# caddy.sh — 标准版 Caddy CLI (无 Cloudflare DNS 集成)
# 用法: sudo c <subcommand>

# shellcheck disable=SC2034 # consumed by sourced caddy-lib.sh cmd_update
DEFAULT_REF="${CADDY_CLI_REF:-v2.11.3-cloudflare-r7}"
DEFAULT_BASE_URL="${CADDY_CLI_BASE_URL:-https://raw.githubusercontent.com/buglyz/caddy_cli/${DEFAULT_REF}}"
DEFAULT_UPDATE_URL="${DEFAULT_BASE_URL}/caddy.sh"

# 定位共享库（与当前脚本同目录）
LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_PATH="${LIB_DIR}/caddy-lib.sh"

if [[ ! -f "$LIB_PATH" ]]; then
    # 如果安装到 /usr/local/bin/c，尝试从同目录查找
    LIB_PATH="$(dirname "$(readlink -f /usr/local/bin/c)")/caddy-lib.sh"
fi
if [[ ! -f "$LIB_PATH" ]]; then
    if [[ "${CADDYCTL_ALLOW_REMOTE_LIB:-0}" != "1" ]]; then
        echo "Fatal: 本地 caddy-lib.sh 未找到。请重新运行安装脚本，或临时设置 CADDYCTL_ALLOW_REMOTE_LIB=1 启用远程加载。" >&2
        exit 1
    fi
    echo "本地 caddy-lib.sh 未找到，按 CADDYCTL_ALLOW_REMOTE_LIB=1 从 GitHub 加载..." >&2
    LIB_CODE="$(curl -fsSL --retry 2 --connect-timeout 10 "${DEFAULT_BASE_URL}/caddy-lib.sh")" || {
        echo "Fatal: 无法加载 caddy-lib.sh（本地缺失且 GitHub 不可达）" >&2
        exit 1
    }
    # shellcheck disable=SC1091 # fallback sources downloaded library code from stdin
    source /dev/stdin <<<"$LIB_CODE"
else
    # shellcheck disable=SC1090 # runtime install path is resolved dynamically
    source "$LIB_PATH"
fi

main "$@"
