# 将 main Shell 版公开功能迁移到 Go 版

状态：本地实现与验证完成，待提交/发布

## 目标

- 以 `origin/main` 的公开命令、交互菜单、安装更新行为和兼容约定为基准，补齐 `refactor/go`。
- 复用现有 Go 站点、快照、导入和校验实现，不逐行翻译 Shell 内部辅助函数。
- 保持标准 Caddy 模式为默认；Cloudflare 功能仅在显式 Cloudflare 模式下启用。
- 所有写入型测试使用临时 `CADDYCTL_ROOT`，不操作生产 `/etc/caddy`，不 reload/restart 生产 Caddy。

## 公开功能矩阵

### 已有，需回归

- [x] `list` / `list-emby`
- [x] `add` / `add-static` / `add-emby` / `add-gateway`
- [x] `set` / `set-static` / `set-emby` / `set-gateway`
- [x] `enable` / `disable` / `rm` 及旧别名
- [x] `config` / `validate` / `apply`
- [x] `email` / `timeout` / `upstream-mode`
- [x] `import --merge|--force`
- [x] `snapshots` / `undo`
- [x] `start` / `restart` / `stop` / `status` / `logs`
- [x] `doctor` / `cert-check`
- [x] `cloudflare set|check|remove` 及旧清理别名
- [x] `update` / `version`，包括 `--ref=`、`--main`、`--binary` 兼容

### 已确认缺口

- [x] 无参数和 `menu` 的完整交互菜单
- [x] 交互添加普通反代、路径反代、静态站、Emby 和受限网关
- [x] 交互修改、启停、删除、全局设置、导入、诊断、快照回滚
- [x] `install` / `install-self` / `self-install` 兼容入口
- [x] 安装后首次运行的已有 Caddyfile 安全导入流程
- [x] Shell 版帮助中公开的命令、别名和行为说明一致性

## 实现 TODO

- [x] 完成 Shell → Go 行为差异清单
- [x] 实现菜单输入层和子菜单
- [x] 为菜单动作组装显式参数并调用现有 `Run`
- [x] 实现缺失的安装兼容入口，复用 `install-go.sh`/Release 流程
- [x] 实现首次运行导入标记的安全处理
- [x] 更新帮助、README、CI/安装验证
- [x] 添加 EOF、取消、错误重试和主要菜单路径测试
- [x] 运行 gofmt、go test、go test -race、go vet、make check
- [x] 检查所有 Go 文件有效行数不超过 400

## 差异处理结论

- Shell 内部 helper/hook 不逐函数翻译；以公开命令、交互行为、生成配置和安全结果等价为准。
- Shell Release 的 `--binary` 下载仓库内固定 Caddy 资产；Go Release 不发布该资产，等价入口改为显式执行 `caddy upgrade --keep-backup`，保留备份且不自动重启服务。
- Go 版继续只支持项目文档声明的 Debian/Ubuntu 与 Alpine，不扩展 Shell 内部遗留的 dnf/pacman 安装分支。
- `CADDYCTL_ROOT` 下禁止 start/restart/stop/status 触碰真实服务，日志也只读取映射目录；这比 Shell 测试桩更适合 Go 单二进制隔离测试。

## 验证结果

- `gofmt`、`go test ./...`、`go test -race ./...`、`go vet ./...`、`make check`：通过。
- `bash -n install-go.sh`、`shellcheck install-go.sh`：通过。
- 真实 Caddy 隔离验证：安装器备份与 pending marker、首次导入、五类站点菜单添加、Go validate、真实 `caddy validate` 均通过。
- 生产 `/etc/caddy/Caddyfile` SHA256、Caddy `NRestarts` 与活动时间戳在隔离测试前后完全一致。
- 全项目 Go 文件 34 个，最大 378 行，无文件超过 400 行；Markdown 无重复章节。

## 完成标准

- `origin/main` 的公开操作均可通过 Go 命令或 Go 交互菜单完成。
- 旧命令/别名、managed 布局和旧 Shell 快照继续兼容。
- 隔离环境真实 Caddy 校验通过，生产 Caddy 未被修改或重启。
