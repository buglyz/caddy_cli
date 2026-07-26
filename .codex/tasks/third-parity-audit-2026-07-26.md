# Go CLI 第三轮行为与错误边界核查

状态：实现与本地验证完成，待发布

## 已确认问题

- [x] 直接交互命令 stdin EOF 可能静默成功
- [x] 无参数命令会忽略多余参数，与严格校验说明不一致
- [x] `import`、`cert-check`、Cloudflare 子命令存在尾随参数未拒绝
- [x] `list` 全局片段输出未沿用 Shell 版 80 行上限

## 验证与发布

- [x] 定向单测和完整 test/race/vet/ShellCheck
- [x] 所有 Go 文件不超过 400 行
- [x] 真实 Caddy 隔离验证且生产环境不变
- [ ] 提交推送并确认 CI / `go-latest`

## 验证结果

- 定向单测、`go test -shuffle=on -count=10`、race、vet、`make check` 全部通过。
- `bash -n` 与 ShellCheck 通过。
- 真实 Caddy 隔离验证覆盖 EOF、尾随参数、多个导入源、80 行输出限制及菜单正常退出。
- 最大 Go 文件 377 行；生产 Caddyfile 哈希、`NRestarts=0`、活动时间戳未变化。
