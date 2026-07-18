#!/usr/bin/env bash
# caddy.sh — 标准版 Caddy CLI (无 Cloudflare DNS 集成)
# 用法: sudo c <subcommand>

# shellcheck disable=SC2034 # consumed by sourced caddy-lib.sh cmd_update
DEFAULT_REF="${CADDY_CLI_REF:-v2.11.3-cloudflare-r14}"
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
    echo "Fatal: 本地 caddy-lib.sh 未找到。请重新运行安装脚本（共享库已拆成入口 + lib/*.sh 模块，不再支持仅远程 source 入口）。" >&2
    exit 1
fi
# shellcheck disable=SC1090 # runtime install path is resolved dynamically
source "$LIB_PATH"

main "$@"
