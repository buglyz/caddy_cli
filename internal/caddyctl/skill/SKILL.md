---
name: caddyctl
description: caddyctl 使用与安全操作手册——管理由 caddyctl 托管的 Caddy 反代（sites.d 注册表、快照回滚、漂移处理、远程上游反代）。本文档内嵌于 caddyctl 二进制，随版本发布：`caddyctl skill` 打印，`caddyctl skill install` 安装到 /etc/caddy/skill/SKILL.md。
---

# caddyctl — Caddy 站点管理

本手册内嵌于 caddyctl 二进制（`caddyctl skill` 打印全文，`caddyctl skill install` 写入配置目录），与当前安装版本的行为严格一致。

## 核心模型（先读这个）

- 主 `/etc/caddy/Caddyfile` 由 caddyctl 从 `/etc/caddy/sites.d/<域名>.conf` **重新生成**——不要手工改主文件：会产生漂移，之后所有变更命令都会被拒绝。
- 每个变更命令的执行路径：全局锁 → 一致性断言（漂移即拒绝）→ 自动快照 → 执行 → **失败自动回滚**。
- sites.d 里的 conf 是事实源：手工写 conf 完全兼容（list 识别、config 再生成包含）。
- 全局片段在 `globals.d/*.inc`，ACME 邮箱在状态里（`c email` 修改）。

## 命令

```
c list                                   # 全部站点（含 conf 内容与启用状态）
c add <域名> <端口> [--path <前缀>] [--stream]         # 反代本机 127.0.0.1:端口
c add <域名> --target <URL> [--stream]                # 反代外部 HTTPS 上游
c add-static <域名> <目录> [--spa]                     # 静态站点
c add-emby <域名> <目标>                              # Emby 反代（占位符 Host + 恒开流式）
c add-gateway <域名> --allow <host:port,...>          # 动态回源网关（带 proxyguard 校验）
c set <域名> [--port|--target|--stream|--no-stream|--path|--root|--spa|--http|--https|--dns-only]
c set-static / set-emby / set-gateway ...             # 按类型的修改命令
c enable|disable|rm <域名>
c config | validate | apply                # config 只读预览；validate 校验+漂移提示；apply 生成+校验+重载
c import [--merge] [--force] [Caddyfile]   # 把外部 Caddyfile 收编进 sites.d
c snapshots [数量|all] / undo [快照ID]      # 快照与回滚
c email [邮箱] / timeout [秒] / upstream-mode [warn|strict]
c doctor / cert-check <域名>               # 环境体检 / 证书诊断
c cloudflare set|check|remove              # DNS-01 配置
c start|restart|stop|status|logs
c skill [install]                          # 打印/安装本手册
c update [--latest|--ref vX.Y.Z] [--binary] / install-self
```

任何子命令支持 `-h`/`--help` 查看单命令用法。

## 添加站点的推荐姿势

```bash
# 本机端口上游（加 --stream 生成 flush_interval -1，适合 SSE/LLM 流式）
c add app.example.com 3000 --stream

# 外部 HTTPS 上游：上游按 Host 头路由时（Northflank *.code.run、Cloudflare 等）
# 自动生成 header_up Host（裸主机名）与 tls_server_name（SNI+证书校验）
c add app.example.com --target https://http--svc--xxx.code.run --stream

# 复杂场景手写 sites.d conf，然后：
c apply
```

修改：`c set app.example.com --port 4000` / `--target https://new.host` / `--stream|--no-stream`。
手工改过 conf 后 set 会保留非模板指令（header/basic_auth/log）。

## 漂移处理（变更被拒绝时）

手工改过主 Caddyfile 后，validate 会警告「live 与 sites.d 渲染不一致」，变更命令被拒绝。二选一：

- `c import --merge /etc/caddy/Caddyfile`：以 live 为准收编进 sites.d（块前注释保留）；
- `c apply`：以 sites.d 为准覆盖 live。

## 沙箱演练（不碰生产）

```bash
export CADDYCTL_ROOT=/tmp/ct-test CADDYCTL_NO_RELOAD=1
rm -rf /tmp/ct-test && mkdir -p /tmp/ct-test
c add demo.example.com --target https://up.example.com --stream --skip-dns-check
c apply          # 真实 caddy 校验渲染产物
c set demo.example.com --no-stream
rm -rf /tmp/ct-test
```

## 验证与回滚

- 变更后 `curl -s -o /dev/null -w "%{http_code}" https://<域名>/`，并抽查一个旧站点；首次 000 通常是证书签发中。
- 回滚：`c undo [快照ID]`（快照在 /etc/caddy/backup/snapshots）。
- `c doctor` 体检；`c cert-check <域名>` 诊断证书/HTTPS。

## 已知坑

- `set` 系列无参/缺域名会打印用法（完整交互菜单已移除）；脚本里优先带全参数。
- 中文输出经 SSH 管道可能乱码（终端按 GBK 解码 UTF-8）：落盘后 `base64 -w0` 传回解码。
- 不要用 `tls_insecure_skip_verify` 绕过公网上游证书——用 `tls_server_name` 指向上游真实域名；仅内网 IP 自签上游由模板自动加 skip-verify。
- `--dns-only` 需要安装带 Cloudflare DNS 插件的 Caddy（`c install --cloudflare`）。
- `update --binary` 会执行 `caddy upgrade --keep-backup` 但不重启服务。
- CADDYCTL_ROOT 可整体隔离配置根目录（默认 /etc/caddy）。
