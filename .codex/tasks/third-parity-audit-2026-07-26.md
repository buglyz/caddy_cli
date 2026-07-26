# Go CLI 第三轮行为与错误边界核查

状态：已完成并发布

## 已确认问题

- [x] 直接交互命令 stdin EOF 可能静默成功
- [x] 无参数命令会忽略多余参数，与严格校验说明不一致
- [x] `import`、`cert-check`、Cloudflare 子命令存在尾随参数未拒绝
- [x] `list` 全局片段输出未沿用 Shell 版 80 行上限

## 验证与发布

- [x] 定向单测和完整 test/race/vet/ShellCheck
- [x] 所有 Go 文件不超过 400 行
- [x] 真实 Caddy 隔离验证且生产环境不变
- [x] 提交推送并确认 CI / `go-latest`

## 第四轮事务与解析审查

- [x] `--` 不得绕过 add 参数冲突检查
- [x] 在写文件前拒绝 Caddy 不支持的带路径/查询/片段反代目标
- [x] 拒绝多域名站点之间的部分标签重叠及大小写重复
- [x] 导入解析跨行保持词法状态，忽略双引号/单行及多行反引号内的字面量大括号
- [x] 显式拒绝符号链接快照根目录

第四轮验证：10 次随机顺序测试、race、vet、ShellCheck、真实 Caddy 多行反引号导入及大小写重叠域名验证均通过；生产环境状态未变化。

## 验证结果

- 定向单测、`go test -shuffle=on -count=10`、race、vet、`make check` 全部通过。
- `bash -n` 与 ShellCheck 通过。
- 真实 Caddy 隔离验证覆盖 EOF、尾随参数、多个导入源、80 行输出限制及菜单正常退出。
- 最大 Go 文件 391 行；生产 Caddyfile 哈希、`NRestarts=0`、活动时间戳未变化。
- 提交 `095eecf` 已推送；CI `30194415099` 与滚动 Release `30194415115` 均成功。
