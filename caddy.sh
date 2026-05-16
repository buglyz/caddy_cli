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
    LIB_PATH="/dev/stdin"
    source <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/main/caddy-lib.sh)
else
    source "$LIB_PATH"
fi

main "$@"
