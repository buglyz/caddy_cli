# Caddy CLI

面向服务器运维的 Go 单文件 Caddy 管理工具，支持 Debian/Ubuntu 与 Alpine Linux。

## 功能

- 反代、路径反代、静态站、Emby 和受限动态网关管理
- `sites.d` / `globals.d` 受管配置渲染
- Caddy 配置校验、应用及 systemd/OpenRC 服务控制
- 全局并发锁、操作前快照、失败恢复和 `undo`
- Caddyfile 覆盖/合并导入
- Cloudflare DNS-01 Token 与 per-site `--dns-only`
- 环境诊断、证书检查、日志和本地上游健康检查
- 经 SHA256 校验的 release 安装和原生自更新

## 安装

前置条件：主机已安装 Caddy。Cloudflare 模式还要求 Caddy 包含：

```text
dns.providers.cloudflare
```

发布 Go release 后下载并运行安装器：

```bash
curl -fsSLO https://raw.githubusercontent.com/buglyz/caddy_cli/refactor/go/install-go.sh
sudo CADDYCTL_GO_VERSION=vX.Y.Z bash install-go.sh
```

Cloudflare 版：

```bash
sudo CADDYCTL_GO_VERSION=vX.Y.Z bash install-go.sh --cloudflare
```

安装器会：

1. 检查 Caddy 与当前 CPU 架构；
2. 下载 `linux/amd64` 或 `linux/arm64` release 二进制；
3. 使用 release 的 `caddyctl-checksums.txt` 校验 SHA256；
4. 执行 `--help` 自检；
5. 将原 `/usr/local/bin/caddyctl` 备份为 `caddyctl.bak`；
6. 安装新二进制并创建 `/usr/local/bin/c` 软链。

回滚已有版本：

```bash
sudo install -m 0755 /usr/local/bin/caddyctl.bak /usr/local/bin/caddyctl
```

## 从源码构建

```bash
make check
make build VERSION=dev
sudo install -m 0755 bin/caddyctl /usr/local/bin/caddyctl
sudo ln -sfn /usr/local/bin/caddyctl /usr/local/bin/c
```

## 常用命令

```bash
# 站点
c list
c add app.example.com 3000
c add app.example.com 3000 --path /api
c add-static static.example.com /var/www/site --spa
c set app.example.com --port 4000
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
c update --latest
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
- 写操作前确认 live Caddyfile 与受管渲染一致，防止覆盖未知配置
- 配置先生成、检查本地上游、执行 `caddy validate`，再原子替换
- apply/reload 失败会恢复站点文件、状态和 live Caddyfile
- 锁目录与锁文件拒绝符号链接和非当前用户属主
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

推送 `v*` tag 后，Release 工作流会发布：

- `caddyctl-linux-amd64`
- `caddyctl-linux-arm64`
- `caddyctl-checksums.txt`

## 许可证

[MIT](LICENSE)
