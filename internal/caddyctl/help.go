package caddyctl

import "fmt"

func (a *App) help() {
	fmt.Fprint(a.Out, `用法:
  c <命令> [参数]

站点:
  c list
  c add <域名> <端口> [--http|--https] [--path <前缀>] [--dns-only] [--skip-dns-check]
  c add-static <域名> <目录> [--spa] [--http|--https] [--dns-only]
  c add-emby <域名> <目标> [--http|--https] [--dns-only]
  c add-gateway <域名> --allow <host:port,...> [--http|--https] [--dns-only]
  c set <域名> [--port <端口>] [--path <前缀|off>] [--http|--https] [--dns-only]
  c set-static <域名> [--root <目录>] [--spa|--no-spa] [--http|--https] [--dns-only]
  c set-emby <域名> [--target <地址>] [--http|--https] [--dns-only]
  c set-gateway <域名> [--allow <列表>|--unsafe-open-proxy] [--http|--https] [--dns-only]
  c enable|disable|rm <域名>

配置与恢复:
  c config | validate | apply
  c email [邮箱]
  c timeout [秒|default]
  c upstream-mode [warn|strict]
  c import [--merge] [--force] [Caddyfile路径]
  c snapshots [数量|all]
  c undo [快照ID]

服务与维护:
  c start | restart | stop | status | logs
  c cloudflare set|check|remove
  c update [--latest|--ref <release-tag>]
  c version

说明:
  · 所有命令均由 Go 原生实现；安装请使用 install-go.sh。
  · c update 和 --latest 默认更新到滚动版 go-latest；固定版本使用 --ref vX.Y.Z。
  · 无参数或 menu 会显示本帮助。
  · 设置 CADDYCTL_ROOT 可在隔离目录测试，不会访问生产 /etc/caddy。
`)
}
