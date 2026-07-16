# Security Notes

## Installation and updates

The installer defaults to a fixed release ref and verifies downloaded files
against `checksums.txt` from the same ref. To test another ref, set:

```bash
CADDY_CLI_REF=main bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/main/install.sh)
```

Checksum verification can be bypassed with `CADDYCTL_SKIP_CHECKSUM=1`, but this
should only be used for local development or emergency recovery.

## Cloudflare token

`c cloudflare set` reads the token from hidden interactive input or stdin. The
token is written to `/etc/caddy/cloudflare.env` with mode `600` and is not
accepted as a command-line argument.

## Gateway mode

`add-gateway` is a dynamic reverse proxy. By default it requires:

```bash
c add-gateway gate.example.com --allow emby.example.com:443,10.0.0.5:8096
```

Only use `--unsafe-open-proxy` when the gateway is protected by authentication,
network isolation, or another explicit access-control layer.


## Library layout

The shared engine is `caddy-lib.sh` plus modules under `lib/*.sh` (installed to
`/usr/local/lib/caddyctl`). Remote one-shot `source` of only the entry file is not
supported; reinstall if the local library is missing.
