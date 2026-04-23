# Caddy CLI 管理脚本

一个面向服务器运维的 Caddy 管理脚本集合，包含：

- `caddy.sh`：主脚本（交互菜单 + 命令行）
- `install.sh`：一键安装脚本

## 快速开始
一键部署
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/main/install.sh)
```
cloudflare dns版本
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/buglyz/caddy_cli/main/install-cloudflare.sh)
```
或者git clone后
```bash
cd /path/to/caddy
sudo bash install.sh
```

安装完成后，直接运行：

```bash
sudo c
```

或命令行模式：

```bash
sudo c help
```

## 常用命令

```bash
# 站点管理
c add example.com 3000 --www --log
c add example.com 3000 --path /api --log
c add-static static.example.com /var/www/site --www
c set example.com --port 4000 --no-log
c enable example.com
c disable example.com
c rm example.com
c list

# 配置与服务
c validate
c apply
c start
c restart
c stop
c status
c logs

# 新增能力
c timeout 45                  # systemctl 超时（秒）
c upstream-mode warn          # 上游检查模式: warn/strict
c cert-check example.com      # 证书诊断
c undo                        # 回滚上一步
```

## 功能特性

- 写操作自动快照，可 `c undo` 回滚
- 上游本地端口健康检查（`warn/strict`）
- 全局并发锁，避免多终端同时修改互相覆盖
- 配置应用前自动校验，失败自动回滚
- 站点访问日志自动滚动（默认 `20MiB`、保留 `10` 份、保留 `720h`）

## 关键路径

- 主配置：`/etc/caddy/Caddyfile`
- 站点目录：`/etc/caddy/sites.d`
- 全局片段：`/etc/caddy/globals.d`
- 状态文件：`/etc/caddy/caddyctl.conf`
- 访问日志：`/var/log/caddy`
- 快照目录：`/etc/caddy/backup/snapshots`

## 排障建议

```bash
c doctor
c validate
c logs
c cert-check your-domain.com
```

## 注意事项

- 需要 `root/sudo` 运行
- 如果系统没有 `systemctl`，脚本会只写配置，不会自动重载服务
