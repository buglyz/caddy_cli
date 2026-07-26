# 修复 Go CLI 交互菜单清屏

日期：2026-07-26
分支：`refactor/go`

## 目标

仅在 stdin 和 stdout 都是真实 TTY 时，于主菜单和每个分层子菜单重绘前清屏；非 TTY 与普通命令输出保持纯文本。

## 边界

- 不依赖外部 `clear` 命令或新增第三方依赖。
- 不修改生产 `/etc/caddy`、Caddy 服务或已安装 caddyctl。
- 不提交、不推送。
- 所有 Go 文件不超过 400 行。

## TODO

- [x] 核对 Shell 与 Go 菜单渲染差异及全部菜单入口。
- [x] 实现可测试的真实 TTY 检测与菜单清屏。
- [x] 添加非 TTY、TTY 分层菜单和普通命令回归测试。
- [x] 完成 gofmt、test、race、vet、make check 与文件行数检查。

## 状态

本地实现与验证完成，待提交发布。

## 验证结果

- 真实伪终端菜单切换检测到 3 次完整清屏序列，管道输出不含 ANSI 控制字符。
- `go test ./...`、10 次随机顺序测试、`go test -race ./...`、`go vet ./...` 和 `make check` 全部通过。
- linux/amd64 与 linux/arm64 交叉构建通过；`bash -n` 与 ShellCheck 通过。
- 所有 Go 文件不超过 400 行，最大文件 391 行。
