# Caddy CLI 管理脚本

一个面向服务器运维的 Caddy 管理脚本集合，采用**共享库 + 前端**架构，消除重复代码。支持 **Debian/Ubuntu** 和 **Alpine Linux**，需要 **Bash 4.0+**。

| 文件 | 说明 |
|------|------|
| `caddy-lib.sh` | 共享引擎（hook 架构，所有公共逻辑） |
| `caddy.sh` | 标准版前端（27 行，source 共享库） |
| `caddy-cloudflare` | Cloudflare DNS 版前端（override 10 个 hook 注入 CF 功能） |
| `install.sh` | 标准版一键安装（自动检测 Debian/Alpine） |
| `install-cloudflare.sh` | Cloudflare DNS 版一键安装（含预编译 Caddy 二进制） |

## 快速开始

**标准版：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/v2.11.3-cloudflare-r9/install.sh)
```

**Cloudflare DNS 版（自动申请泛域名证书）：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/v2.11.3-cloudflare-r9/install-cloudflare.sh)
```

> Alpine 用户同上，安装脚本会自动检测发行版并使用 `apk`。  
> CF 版的预编译二进制是 x86-64 `CGO_ENABLED=0` 纯静态编译，glibc 和 musl 通用；非 x86-64 会自动切换为源码构建。
> 默认安装固定 release ref，并通过 `checksums.txt` 校验下载文件；如需测试 main，可设置 `CADDY_CLI_REF=main`。

安装完成后直接运行：
```bash
sudo c          # 交互菜单
c help          # 只读帮助（无需 root）
sudo c doctor   # 环境诊断
```

## 常用命令

```bash
# 站点管理
c list
c add example.com 3000
c add example.com 3000 --path /api
c add lan.example.com 3000 --http --skip-dns-check
c add-static static.example.com /var/www/site --spa
c add-static lan-static.example.com /var/www/site --http --skip-dns-check
c add lan.example.com 3000 --skip-dns-check
c set example.com --port 4000
c enable example.com
c disable example.com
c rm example.com

# Emby 管理
c list-emby
c add-emby emby.example.com https://10.0.0.5:8096
c add-emby lan.example.com http://10.0.0.5:8096 --http
c add-gateway gate.example.com --allow emby.example.com:443,10.0.0.5:8096
c add-gateway gate.local --allow 10.0.0.5:8096 --no-ssl --skip-dns-check
c set-emby emby.example.com --target https://10.0.0.6:8096
c set-gateway gate.example.com --allow 10.0.0.6:8096 --https
c rm-emby emby.example.com

# 配置与全局设置
c email admin@example.com
c import /path/to/Caddyfile
c config
c validate
c apply
c timeout 45
c upstream-mode warn

# 服务控制
c start
c restart
c stop

# 诊断与日志
c doctor
c status
c logs
c cert-check example.com

# 备份与回滚
c snapshots
c undo
c undo <快照ID>

# 安装与更新
c install
c install-self
c update
```

## Cloudflare DNS 版额外功能

- 配置 Cloudflare API token 后，默认仍走 **HTTP-01 / TLS-ALPN-01**（不会因为存在 token 就全局强制 DNS-01）
- 需要 DNS-01（泛域名、CF 橙云、80/443 不可达）时显式加：`c add example.com 3000 --dns-only`
- `c cloudflare set` — 配置 Cloudflare API token（交互式隐藏输入；脚本环境可通过 stdin 传入）
- `c cloudflare check` — 检查 Cloudflare DNS-01 就绪状态
- `c cloudflare remove` — 删除 Cloudflare 配置

## 功能特性

- 写操作自动快照，可 `c snapshots` 查看、`c undo [快照ID]` 回滚
- 上游本地端口健康检查（`warn/strict`）
- 添加域名反代前会检查 DNS A/AAAA 是否解析到本机 IP，可用 `--skip-dns-check` 跳过
- 交互式添加配置时会询问是否启用 TLS/HTTPS；命令行可用 `--http` 或 `--https` 显式指定
- 全局并发锁，避免多终端同时修改互相覆盖
- 配置应用前自动校验，失败自动回滚
- 配置重载失败时自动降级 `restart`（兼容老 systemd）
- `c update` 同时更新前端脚本和共享库
- Hook 扩展架构：Cloudflare 版通过 override 10 个 hook 函数注入功能，零侵入
- Cloudflare 版支持 per-site DNS-01（`--dns-only`）；默认 HTTP-01，覆盖普通反代、静态站、Emby 与网关
- 服务抽象层：同时支持 systemd（Debian/Ubuntu）和 OpenRC（Alpine）
- 通用反代网关：通过 `c add-gateway --allow <host:port,...>` 创建受限动态上游代理，支持 `/http://<host>/path` 和 `/https://<host>/path` 自动路由，并可用 `c set-gateway` 修改 allow-list 或协议

## 供应链与安全

- 安装脚本默认使用固定 tag `v2.11.3-cloudflare-r9`，并校验同 tag 下的 `checksums.txt`。
- Cloudflare 版预编译 `caddy` **仅通过 GitHub Release 分发**（仓库不再追踪 46MB 二进制）；安装脚本下载 Release 资产并校验 checksum，不可用时用 `--build-from-source`。
- `c update` 会同时校验前端脚本和共享库；如确需跳过校验，可设置 `CADDYCTL_SKIP_CHECKSUM=1`。
- Cloudflare 版源码构建固定 Caddy、xcaddy 和 `caddy-dns/cloudflare` 版本；可通过 `CADDY_VERSION`、`XCADDY_VERSION`、`CLOUDFLARE_MODULE` 覆盖。
- 本地共享库缺失时，CLI 默认不再在线 `source` 远程代码；临时救急可设置 `CADDYCTL_ALLOW_REMOTE_LIB=1`。
- `add-gateway` 默认必须配置 allow-list。只有在已有认证、内网隔离或其他访问控制时，才使用 `--unsafe-open-proxy`。

## 发行版支持

| 发行版 | 标准版 | Cloudflare DNS 版 |
|--------|--------|-------------------|
| Debian / Ubuntu | `apt` + Cloudsmith 官方源 | 预编译二进制 或 `--build-from-source` |
| Alpine Linux | `apk` + community 源 | 预编译二进制（CGO_ENABLED=0 纯静态）或 `--build-from-source` |

> Cloudflare DNS 版在 Alpine 上如需从源码编译：  
> `bash install-cloudflare.sh --build-from-source`

## 关键路径

| 路径 | 说明 |
|------|------|
| `/etc/caddy/Caddyfile` | 主配置（由脚本自动生成，**请勿手动编辑**） |
| `/etc/caddy/sites.d` | 站点配置片段 |
| `/etc/caddy/globals.d` | 全局配置片段 |
| `/etc/caddy/caddyctl.conf` | 状态文件 |
| `/etc/caddy/backup/snapshots` | 快照目录 |
| `/var/log/caddy` | 访问日志 |
| `/usr/local/bin/caddyctl` | 脚本本体 |
| `/usr/local/bin/c` | `caddyctl` 软链 |
| `/usr/local/bin/caddy-lib.sh` | 共享库 |

## 排障

```bash
c doctor
c validate
c logs
c cert-check your-domain.com
```

## 注意事项

- 写操作需要 `root/sudo`；`help` / `list` / `doctor` / `status` / `logs` / `validate` 等只读命令可非 root 尽力执行
- 如果系统没有 service manager（systemd / OpenRC），脚本只写配置，不会自动重载服务
- Cloudflare DNS 版需要先运行 `c cloudflare set` 配置 API token
- **不要手动编辑 `/etc/caddy/Caddyfile`**，它由脚本从 `sites.d/` 和 `globals.d/` 自动生成
- 不要把 `add-gateway --unsafe-open-proxy` 暴露到公网；它会允许访问者指定任意上游地址。
