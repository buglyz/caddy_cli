# Caddy CLI

面向服务器运维的 Go 单文件 Caddy 管理工具，支持 Debian/Ubuntu 与 Alpine Linux。

[![CI](https://github.com/buglyz/caddy_cli/actions/workflows/ci.yml/badge.svg?branch=refactor%2Fgo)](https://github.com/buglyz/caddy_cli/actions/workflows/ci.yml?query=branch%3Arefactor%2Fgo)

> 当前 Go 版本位于 `refactor/go` 分支。每次提交都会更新滚动预发布 `go-latest`；首个固定版本为 `v0.1.0`。

## 功能

- 反代、路径反代、静态站、Emby 和受限动态网关管理
- `sites.d` / `globals.d` 受管配置渲染
- Caddy 配置校验、应用及 systemd/OpenRC 服务控制
- 全局并发锁、操作前快照、失败恢复和 `undo`
- 新旧快照完整性校验和事务式恢复，失败时不会留下半恢复状态
- Caddyfile 覆盖/合并导入
- Cloudflare DNS-01 Token 与 per-site `--dns-only`
- 环境诊断、证书检查、日志和本地上游健康检查
- 经 SHA256 校验的 release 安装和原生自更新
- 与 Shell `main` 版一致的分层交互管理菜单；无参数或 `c menu` 均可进入
- 兼容 `c install`、`c install-self` 和安装后首次运行导入已有 Caddyfile
- 严格的命令参数校验，不适用于当前站点类型的选项会直接报错

## 安装

前置条件：

- Debian/Ubuntu 或 Alpine Linux
- `curl`、`bash`、root 或 `sudo`
- Linux `amd64` 或 `arm64`
- Go 1.23+（仅源码构建需要）

### 一键安装预构建版本（推荐）

无需预装 Caddy 或 Go 工具链。以下命令会从零开始：安装官方 Caddy、准备服务和配置目录，再自动识别 `amd64` / `arm64`，下载 `go-latest` 的预构建 caddyctl，校验 SHA256 后安装：

```bash
curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/refactor/go/install-go.sh | sudo bash
```

Cloudflare 版会自动为 Caddy 添加 `dns.providers.cloudflare` 模块：

```bash
curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/refactor/go/install-go.sh | sudo bash -s -- --cloudflare
```

如需固定 caddyctl 二进制版本：

```bash
curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/refactor/go/install-go.sh | sudo env CADDYCTL_GO_VERSION=v0.1.0 bash
```

### 从源码安装

```bash
git clone --branch refactor/go https://github.com/buglyz/caddy_cli.git
cd caddy_cli
make check
make build VERSION=dev
sudo install -m 0755 bin/caddyctl /usr/local/bin/caddyctl
sudo ln -sfn /usr/local/bin/caddyctl /usr/local/bin/c
c version
c                    # 进入交互管理菜单
```

从源码手动安装时，需要自行确保 Caddy 已包含 `dns.providers.cloudflare`，并写入版本标记：

```bash
sudo install -d -m 0755 /etc/caddy
sudo touch /etc/caddy/.caddyctl-cloudflare
sudo chmod 0644 /etc/caddy/.caddyctl-cloudflare
```

### 手动指定 Release 版本

仅使用明确包含以下三个资产的 tag：

```text
caddyctl-linux-amd64
caddyctl-linux-arm64
caddyctl-checksums.txt
```

下载当前分支的安装器，并指定版本：

```bash
curl -fsSLO https://raw.githubusercontent.com/buglyz/caddy_cli/refactor/go/install-go.sh
sudo CADDYCTL_GO_VERSION=v0.1.0 bash install-go.sh
```

Cloudflare 版：

```bash
sudo CADDYCTL_GO_VERSION=v0.1.0 bash install-go.sh --cloudflare
```

安装器默认下载滚动预发布 `go-latest`。它会先下载并校验 caddyctl 资产；校验失败时不会安装 Caddy、创建配置目录或替换现有 CLI。校验通过后会：

1. 检测 Debian/Ubuntu 或 Alpine，以及 `amd64` / `arm64` 架构；
2. 下载对应的预构建 caddyctl 和 `caddyctl-checksums.txt`；
3. 校验 SHA256，并执行新二进制自检；
4. Caddy 缺失时，通过官方软件源安装、初始化受管 Caddyfile 并配置服务；
5. `--cloudflare` 模式自动添加并验证 Cloudflare DNS 模块；
6. 备份已有 Caddy 配置，并在已有内联 Caddyfile 且 `sites.d` 为空时创建首次导入标记；
7. 将原 `/usr/local/bin/caddyctl` 备份为 `caddyctl.bak`；
8. 安装新二进制并创建 `/usr/local/bin/c` 软链。

如果系统已有 Caddy，安装器会保留现有版本和配置，不会主动升级或覆盖；仅在明确使用 `--cloudflare` 且模块缺失时更新 Caddy 二进制。

回滚已有版本：

```bash
sudo install -m 0755 /usr/local/bin/caddyctl.bak /usr/local/bin/caddyctl
```

### 从旧 Shell 版迁移

Go CLI 沿用原来的 `/etc/caddy/sites.d`、`globals.d`、状态文件和快照布局。安装器切换前会分别备份现有配置和 `/usr/local/bin/caddyctl`；旧 Shell 快照也仍可恢复。

当安装器发现已有非空 Caddyfile 且 `sites.d` 为空时，会创建一次性导入标记。首次以 root 运行 `c` 后，Go CLI 会先创建快照、导入并校验；失败会恢复并把标记改为 `.failed`。已有 `sites.d` 时不会自动覆盖。需要跳过可设置 `CADDYCTL_SKIP_AUTO_IMPORT=1`。

未经过安装器迁移或报告配置漂移时，先审查并显式导入：

```bash
sudo c import --merge /etc/caddy/Caddyfile
sudo c validate
```

## 常用命令

```bash
# 站点
c                    # 交互添加、修改、启停和删除
c list
c add app.example.com 3000
c add app.example.com 3000 --path /api
c add-static static.example.com /var/www/site --spa
c set app.example.com --port 4000
c set-static static.example.com --root /var/www/new --spa
c enable app.example.com
c disable app.example.com
c rm app.example.com

# Emby 与网关
c list-emby
c add-emby emby.example.com https://10.0.0.5:8096
c set-emby emby.example.com --target https://10.0.0.6:8096
c add-gateway gate.example.com --allow emby.example.com:443,10.0.0.5:8096
c set-gateway gate.example.com --allow 10.0.0.6:8096

# 配置与恢复
c config
c validate
c apply
c import --merge /path/to/Caddyfile
c snapshots all
c undo

# 服务与诊断
c status
c restart
c logs
c doctor
c cert-check app.example.com
c version
c update
c update --binary    # 同时执行 caddy upgrade --keep-backup，不自动重启服务
c install-self       # 安装当前正在运行的 Go 二进制及 c 别名
```

默认会检查域名 A/AAAA 是否指向本机。内网、测试或 Cloudflare 代理场景可显式使用：

```bash
c add app.example.com 3000 --skip-dns-check
```

## Cloudflare DNS-01

Cloudflare 安装模式会写入 `/etc/caddy/.caddyctl-cloudflare` 标记。配置 Token：

```bash
sudo c cloudflare set
sudo c cloudflare check
```

Token 不接受命令行参数，写入 `/etc/caddy/cloudflare.env`，权限为 `0600`。需要 DNS-01 的站点显式添加：

```bash
sudo c add wildcard.example.com 3000 --dns-only --skip-dns-check
```

普通站点默认仍使用 HTTP-01 / TLS-ALPN-01。

## 安全机制

- 写操作需要 root；只读命令支持非 root 尽力检查
- `version`、`timeout` 查询和 `upstream-mode` 查询不会创建目录或快照
- 写操作前确认 live Caddyfile 与受管渲染一致，防止覆盖未知配置
- 配置先生成、检查本地上游、执行 `caddy validate`，再原子替换
- apply/reload 失败会恢复站点文件、状态和 live Caddyfile
- 锁目录与锁文件拒绝符号链接和非当前用户属主
- 快照会先核对目录、manifest 及声明文件，再以事务方式恢复站点、全局配置和状态
- 默认保留最近 30 个快照，支持旧 Shell 快照格式恢复
- `add-gateway` 默认必须提供 allow-list；开放代理必须显式使用 `--unsafe-open-proxy`

## 路径

| 路径 | 用途 |
|---|---|
| `/usr/local/bin/caddyctl` | Go CLI 二进制 |
| `/usr/local/bin/c` | CLI 软链 |
| `/etc/caddy/Caddyfile` | 生成后的 live 配置 |
| `/etc/caddy/sites.d` | 站点片段 |
| `/etc/caddy/globals.d` | 全局片段 |
| `/etc/caddy/caddyctl.conf` | CLI 状态 |
| `/etc/caddy/backup/snapshots` | 操作快照 |
| `/etc/caddy/cloudflare.env` | Cloudflare Token |

## 环境变量

| 变量 | 用途 |
|---|---|
| `CADDY_BIN` | 指定 Caddy 可执行文件 |
| `CADDYCTL_ROOT` | 将 `/etc`、日志和锁路径映射到隔离根目录 |
| `CADDYCTL_NO_RELOAD=1` | 写入配置但不操作服务 |
| `CADDYCTL_SKIP_DNS_CHECK=1` | 跳过域名指向本机检查 |
| `CADDYCTL_IMPORT_FORCE=1` | 非交互覆盖导入 |
| `CADDYCTL_LOCK_WAIT_SECONDS` | 全局锁等待秒数，默认 30 |
| `CADDYCTL_UPSTREAM_CHECK_MODE` | 本地上游检查模式：`warn` 或 `strict` |
| `CADDYCTL_CLOUDFLARE=1` | 临时启用 Cloudflare 版行为 |
| `CADDYCTL_GO_VERSION` | 安装或更新使用的 release tag，默认 `go-latest`；`latest` 表示 GitHub 最新固定版 |
| `CADDYCTL_GO_REPOSITORY` | 安装或更新使用的 GitHub 仓库 |
| `CADDYCTL_GO_BIN_DIR` | 安装目录，默认 `/usr/local/bin` |
| `CADDYCTL_GO_INSTALLER_REF` | `c install` 获取安装器的分支，默认 `refactor/go` |
| `CADDYCTL_SKIP_AUTO_IMPORT=1` | 跳过安装后首次运行的已有 Caddyfile 自动导入 |

## 项目结构

```text
cmd/caddyctl/          CLI 入口
internal/caddyctl/    配置、站点、快照、导入、诊断和更新实现
install-go.sh         Release 二进制安装器
Makefile              构建与验证入口
.github/workflows/    CI 和 Release 构建
```

## 开发与测试

```bash
make check
```

隔离测试可通过 `CADDYCTL_ROOT` 重映射所有受管路径：

```bash
root="$(mktemp -d)"
CADDYCTL_ROOT="$root" \
CADDYCTL_SKIP_DNS_CHECK=1 \
CADDYCTL_NO_RELOAD=1 \
  go run ./cmd/caddyctl add app.example.com 3000
```

CI 会执行格式检查、单元/集成测试、竞态检测、`go vet`、安装器 ShellCheck、真实 Caddy 校验及 amd64/arm64 静态构建。

## 发布

每次向 `refactor/go` 推送普通提交，Release 工作流会先执行格式检查、单元测试、竞态检测和 `go vet`，通过后构建两个架构的静态二进制，并覆盖滚动预发布 `go-latest` 中的资产。发布后工作流会重新下载三个资产、核对 SHA256，并执行 amd64 二进制确认版本号。该滚动 tag 会始终指向最新通过质量门禁的提交。

推送 `v*` tag 后，Release 工作流会发布：

- `caddyctl-linux-amd64`
- `caddyctl-linux-arm64`
- `caddyctl-checksums.txt`

每次发布都应使用递增的新 tag，例如 `v0.1.1`；不要复用或移动已经发布的 tag。工作流检测到同名固定 Release 已存在时会直接失败，不会覆盖其资产。

安装脚本和 `c update` 默认使用 `go-latest`，因此不传版本参数即可获得最近一次成功构建。`go-latest` 会随普通提交变化；固定版本 Release 保持不变。如需锁定生产版本，可显式设置 `CADDYCTL_GO_VERSION=v0.1.0` 或运行 `c update --ref v0.1.0`。

## 许可证

[MIT](LICENSE)
