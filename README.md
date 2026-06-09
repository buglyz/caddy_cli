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
bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/v2.11.3-cloudflare-r7/install.sh)
```

**Cloudflare DNS 版（自动申请泛域名证书）：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/v2.11.3-cloudflare-r7/install-cloudflare.sh)
```

> Alpine 用户同上，安装脚本会自动检测发行版并使用 `apk`。  
> CF 版的预编译二进制是 x86-64 `CGO_ENABLED=0` 纯静态编译，glibc 和 musl 通用；非 x86-64 会自动切换为源码构建。
> 默认安装固定 release ref，并通过 `checksums.txt` 校验下载文件；如需测试 main，可设置 `CADDY_CLI_REF=main`。

安装完成后直接运行：
```bash
sudo c          # 交互菜单
sudo c help     # 命令行模式
```

## 常用命令

```bash
# 站点管理
c add example.com 3000
c add example.com 3000 --path /api
c add-static static.example.com /var/www/site --spa
c add-gateway gate.example.com --allow emby.example.com:443,10.0.0.5:8096
c add-gateway gate.local --allow 10.0.0.5:8096 --no-ssl
c set example.com --port 4000
c enable example.com
c disable example.com
c rm example.com
c list

# 配置与服务
c validate
c apply
c start / restart / stop
c status
c logs

# 工具
c timeout 45                  # systemctl 超时（秒）
c upstream-mode warn          # 上游检查模式: warn/strict
c cert-check example.com      # 证书诊断
c undo                        # 回滚上一步
c update                      # 更新脚本（前端 + 共享库）
c doctor                      # 环境诊断
c import /path/to/Caddyfile   # 导入现有配置
```

## Cloudflare DNS 版额外功能

- 自动通过 DNS-01 challenge 申请 Let's Encrypt 证书（支持泛域名 `*.example.com`）
- `c cloudflare set` — 配置 Cloudflare API token（交互式隐藏输入；脚本环境可通过 stdin 传入）
- `c cloudflare check` — 检查 Cloudflare DNS-01 就绪状态
- `c cloudflare remove` — 删除 Cloudflare 配置

## 功能特性

- 写操作自动快照，可 `c undo` 回滚
- 上游本地端口健康检查（`warn/strict`）
- 全局并发锁，避免多终端同时修改互相覆盖
- 配置应用前自动校验，失败自动回滚
- 配置重载失败时自动降级 `restart`（兼容老 systemd）
- `c update` 同时更新前端脚本和共享库
- Hook 扩展架构：Cloudflare 版通过 override 10 个 hook 函数注入功能，零侵入
- 服务抽象层：同时支持 systemd（Debian/Ubuntu）和 OpenRC（Alpine）
- 通用反代网关：通过 `c add-gateway --allow <host:port,...>` 创建受限动态上游代理，支持 `/http/<host>/path` 和 `/https/<host>/path` 自动路由

## 供应链与安全

- 安装脚本默认使用固定 tag `v2.11.3-cloudflare-r7`，并校验同 tag 下的 `checksums.txt`。
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

- 需要 `root/sudo` 运行
- 如果系统没有 service manager（systemd / OpenRC），脚本只写配置，不会自动重载服务
- Cloudflare DNS 版需要先运行 `c cloudflare set` 配置 API token
- **不要手动编辑 `/etc/caddy/Caddyfile`**，它由脚本从 `sites.d/` 和 `globals.d/` 自动生成
- 不要把 `add-gateway --unsafe-open-proxy` 暴露到公网；它会允许访问者指定任意上游地址。
