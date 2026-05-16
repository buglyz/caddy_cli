#!/usr/bin/env bash
# Backward-compat shim — delegates to caddy-cloudflare
LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
exec bash "${LIB_DIR}/caddy-cloudflare" "$@"
