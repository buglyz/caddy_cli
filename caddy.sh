#!/usr/bin/env bash
# caddy.sh — 标准版 Caddy CLI (无 Cloudflare DNS 集成)
# 用法: sudo c <subcommand>

DEFAULT_UPDATE_URL="https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy.sh"

# 定位共享库（与当前脚本同目录）
LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_PATH="${LIB_DIR}/caddy-lib.sh"

if [[ ! -f "$LIB_PATH" ]]; then
    # 如果安装到 /usr/local/bin/c，尝试从同目录查找
    LIB_PATH="$(dirname "$(readlink -f /usr/local/bin/c)")/caddy-lib.sh"
fi
if [[ ! -f "$LIB_PATH" ]]; then
    # 最后尝试从 GitHub 在线加载
    echo "本地 caddy-lib.sh 未找到，尝试从 GitHub 加载..." >&2
    LIB_CODE="$(curl -fsSL --retry 2 --connect-timeout 10 https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy-lib.sh)" || {
        echo "Fatal: 无法加载 caddy-lib.sh（本地缺失且 GitHub 不可达）" >&2
        exit 1
    }
    source /dev/stdin <<<"$LIB_CODE"
else
    source "$LIB_PATH"
fi

main "$@"
