# Security Notes

## Installation and updates

Release installation and `c update` download a platform-specific Go binary and
verify it against `caddyctl-checksums.txt` from the same GitHub Release. A new
binary must also pass a local `--help` self-check before replacing the current
executable.

The installer completes those download, checksum, and self-check steps before
installing Caddy, creating the managed layout, or replacing the current CLI.
Release tags and GitHub repository identifiers are validated before they are
used to construct download URLs.

The installer keeps the previous executable at
`/usr/local/bin/caddyctl.bak`. The native updater uses the same `.bak` suffix.

## Configuration mutations

Before a write operation, caddyctl verifies that the live Caddyfile matches the
managed `sites.d` / `globals.d` rendering. Each mutation creates a snapshot,
uses a secure global lock, validates the generated Caddyfile, and restores the
previous files when validation or service reload fails.

Current manifest-based snapshots and legacy Shell snapshots are validated
before restore. Sites, global configuration, and state are staged first and
committed as one rollback-capable transaction. File copies use a temporary file
and atomic rename, so a destination symlink is replaced rather than followed.

## Cloudflare token

`c cloudflare set` reads the token from stdin and never accepts it as a command
argument. The token is stored in `/etc/caddy/cloudflare.env` with mode `0600`.

## Gateway mode

`add-gateway` requires an explicit `--allow host:port,...` list by default.
Only use `--unsafe-open-proxy` when another authentication or network-isolation
layer protects the gateway.
