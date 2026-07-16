#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    printf '%s\n' "错误: 需要 Bash 4.0+，当前: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

# Clean up on exit
trap 'cleanup_paths "${LAST_VALIDATE_LOG:-}"' EXIT

# Resolve module directory:
# 1) repo layout: <repo>/lib next to this file
# 2) installed layout: /usr/local/lib/caddyctl
# 3) same directory as this file (flat install fallback)
_caddyctl_resolve_libdir() {
    local here candidate
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "${here}/lib" \
        "/usr/local/lib/caddyctl" \
        "${here}"
    do
        if [[ -f "${candidate}/00-core.sh" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

_CADDYCTL_LIBDIR="$(_caddyctl_resolve_libdir)" || {
    printf '%s\n' "Fatal: 无法定位 caddyctl 库目录（需要 00-core.sh）。请重新运行安装脚本。" >&2
    exit 1
}

# shellcheck disable=SC1090,SC1091 # modules resolved at runtime
for _caddyctl_mod in \
    00-core.sh \
    10-validate.sh \
    20-config.sh \
    30-service.sh \
    40-lock-snapshot.sh \
    50-sites.sh \
    60-cmd-sites.sh \
    70-cmd-ops.sh
do
    # shellcheck source=/dev/null
    source "${_CADDYCTL_LIBDIR}/${_caddyctl_mod}"
done
unset _caddyctl_mod
