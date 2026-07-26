# Go CLI main 分支行为兼容二次审计

状态：本地实现与验证完成，待推送

## 目标

- 核对 Shell `main` 公开命令在缺少位置参数时的交互行为。
- 补齐 `list` 的全局片段、启用/禁用分区和 Cloudflare 状态展示。
- 保持 `CADDYCTL_ROOT` 隔离验证，不修改生产 Caddy 配置或服务。

## TODO

- [x] `set` / `set-static` / `set-emby` / `set-gateway` 缺参交互
- [x] `rm` / `rm-emby` / `enable` / `disable` 缺参交互及类型边界
- [x] `cert-check` 缺参交互
- [x] `list` 输出与 Shell 版信息范围对齐
- [x] 单测、race、vet、ShellCheck、真实 Caddy 隔离验证
- [ ] 推送并确认 CI / `go-latest`

## 验证结果

- `gofmt`、`go test ./...`、`go test -race ./...`、`go vet ./...`、`make check`：通过。
- `bash -n install-go.sh`、`shellcheck install-go.sh`：通过。
- 真实 Caddy 隔离验证通过；额外确认 managed 漂移保护会拒绝未应用的 `globals.d` 手工变动。
- 生产 Caddyfile SHA256、`NRestarts=0` 和活动时间戳未变化。
- 最大 Go 文件 377 行，低于 400 行硬限制。
