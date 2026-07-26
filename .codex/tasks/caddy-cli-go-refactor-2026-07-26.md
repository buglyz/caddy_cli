# Caddy CLI Go Refactor

## Goal

Move the daily runtime from Bash to an idiomatic Go CLI while preserving the
current command surface, generated Caddy configuration, safety checks, snapshot
format, rollback behavior, standard/Cloudflare variants, and Debian/Alpine
installation paths. Keep package installation and the interactive menu in the
legacy entry until their Go replacements have equivalent distribution coverage.

## Baseline

- Branch: `refactor/go`
- Base: `origin/main` at `7338e97c4841bd6392dbdea268bb55f8e58573f0`
- Existing Bash entry points remain available until behavior parity is verified.
- Tests must use isolated temporary paths and must not mutate host Caddy state.

## TODO

- [x] Create the refactor branch from the latest remote baseline.
- [x] Inventory commands, flags, environment variables, hooks, and file formats.
- [x] Define the Go package boundaries and compatibility strategy.
- [x] Implement the Go CLI with focused unit/integration tests.
- [x] Add the verified Go release installer, CI/release builds, and documentation.
- [x] Compare Go and Bash behavior for critical workflows.
- [x] Run formatting, tests, static checks, race tests, and file-size checks.

## Compatibility Checklist

- Site operations: list/add/set/enable/disable/remove, static, Emby, gateway.
- Configuration: email/import/config/validate/apply/timeout/upstream mode.
- Service operations: start/restart/stop/status/logs/doctor/cert-check.
- Recovery: mutation lock, snapshots, undo, validation failure rollback.
- Cloudflare: token lifecycle, readiness check, per-site DNS-01 behavior.
- Distribution: verified amd64/arm64 release install, native Go update, and
  legacy Debian/Alpine package installation fallback.

## Non-Goals

- No unrelated Caddy policy changes.
- No production `/etc/caddy` mutations during development or tests.
- No removal of the Bash implementation before parity is demonstrated.
