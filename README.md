# Caddy CLI 管理脚本

一个面向服务器运维的 Caddy 管理脚本集合，采用**共享库 + 前端**架构，消除重复代码。

| 文件 | 说明 |
|------|------|
| `caddy-lib.sh` | 共享引擎（hook 架构，所有公共逻辑） |
| `caddy.sh` | 标准版前端（23 行，source 共享库） |
| `caddy-cloudflare.sh` | Cloudflare DNS 版前端（override 10 个 hook 注入 CF 功能） |
| `install.sh` | 标准版一键安装 |
| `install-cloudflare.sh` | Cloudflare DNS 版一键安装 |

## 快速开始

**标准版：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/main/install.sh)
```

**Cloudflare DNS 版（自动申请泛域名证书）：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/main/install-cloudflare.sh)
```

安装完成后直接运行：
```bash
sudo c          # 交互菜单
sudo c help     # 命令行模式
```

## 常用命令

```bash
# 站点管理
c add example.com 3000 --www --log
c add example.com 3000 --path /api --log
c add-static static.example.com /var/www/site --www --spa
c set example.com --port 4000 --no-log
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
- `c cf-env` — 配置 Cloudflare API token
- `c cf-clear-cache` — 清除 Cloudflare 缓存
- `c cf-purge-files` — 按 URL 清除缓存文件
- `c cf-zones` — 列出所有域名

## 功能特性

- 写操作自动快照，可 `c undo` 回滚
- 上游本地端口健康检查（`warn/strict`）
- 全局并发锁，避免多终端同时修改互相覆盖
- 配置应用前自动校验，失败自动回滚
- 配置重载失败时自动降级 `restart`（兼容老 systemd）
- 站点访问日志自动滚动（默认 `20MiB`、保留 `10` 份、保留 `720h`）
- `c update` 同时更新前端脚本和共享库
- Hook 扩展架构：Cloudflare 版通过 override 10 个 hook 函数注入功能，零侵入

## 关键路径

| 路径 | 说明 |
|------|------|
| `/etc/caddy/Caddyfile` | 主配置（由脚本自动生成） |
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
- 如果系统没有 `systemctl`，脚本只写配置，不会自动重载服务
- Cloudflare DNS 版需要先运行 `c cf-env` 配置 API token
