package caddyctl

import "fmt"

func isHelpFlag(args []string) bool {
	return len(args) > 0 && (args[0] == "-h" || args[0] == "--help")
}

// commandUsage 返回子命令的单行用法；ok 为 false 时调用方回退到主帮助。
func commandUsage(cmd string) (string, bool) {
	usage, ok := commandUsageMap[cmd]
	return usage, ok
}

var commandUsageMap = map[string]string{
	"list": "用法: c list", "ls": "用法: c list",
	"list-emby": "用法: c list-emby", "emby-list": "用法: c list-emby",
	"add":         "用法: c add <域名> <端口> [--path <前缀>] [--stream] 或 c add <域名> --target <URL> [--stream] [--http|--https] [--dns-only] [--skip-dns-check]",
	"add-static":  "用法: c add-static <域名> <目录> [--spa] [--http|--https] [--dns-only] [--skip-dns-check]",
	"static":      "用法: c add-static <域名> <目录> [--spa]",
	"add-emby":    "用法: c add-emby <域名> <目标> [--http|--https] [--dns-only] [--skip-dns-check]",
	"emby":        "用法: c add-emby <域名> <目标>",
	"add-gateway": "用法: c add-gateway <域名> --allow <host:port,...> [--unsafe-open-proxy] [--http|--https] [--dns-only] [--skip-dns-check]",
	"gateway":     "用法: c add-gateway <域名> --allow <host:port,...>",
	"set":         "用法: c set <域名> [--port|--path|--root|--target|--stream|--no-stream|--spa|--no-spa|--http|--https|--dns-only]",
	"set-static":  "用法: c set-static <域名> [--root <目录>] [--spa|--no-spa] [--http|--https] [--dns-only]",
	"set-emby":    "用法: c set-emby <域名> [--target <地址>] [--http|--https] [--dns-only]",
	"set-gateway": "用法: c set-gateway <域名> [--allow <列表>|--unsafe-open-proxy] [--http|--https] [--dns-only]",
	"rm":          "用法: c rm <域名>", "del": "用法: c rm <域名>", "delete": "用法: c rm <域名>",
	"rm-emby": "用法: c rm-emby <域名>", "del-emby": "用法: c rm-emby <域名>", "delete-emby": "用法: c rm-emby <域名>",
	"enable":        "用法: c enable <域名>",
	"disable":       "用法: c disable <域名>",
	"email":         "用法: c email [邮箱]",
	"timeout":       "用法: c timeout [秒|default]",
	"upstream-mode": "用法: c upstream-mode [warn|strict]",
	"validate":      "用法: c validate", "check": "用法: c validate",
	"apply": "用法: c apply", "reload": "用法: c apply",
	"config": "用法: c config", "cat": "用法: c config",
	"snapshots": "用法: c snapshots [数量|all]", "snapshot": "用法: c snapshots [数量|all]",
	"undo":  "用法: c undo [快照ID]",
	"start": "用法: c start", "restart": "用法: c restart", "stop": "用法: c stop",
	"status":       "用法: c status",
	"logs":         "用法: c logs",
	"doctor":       "用法: c doctor（别名 check-env）",
	"check-env":    "用法: c doctor",
	"cert-check":   "用法: c cert-check <域名>",
	"import":       "用法: c import [--merge] [--force] [Caddyfile路径]",
	"cloudflare":   "用法: c cloudflare set|check|remove",
	"cf":           "用法: c cloudflare set|check|remove",
	"update":       "用法: c update [--latest|--ref <release-tag>] [--binary]",
	"install":      "用法: c install [--cloudflare]",
	"install-self": "用法: c install-self",
	"self-install": "用法: c install-self",
	"version":      "用法: c version",
	"--version":    "用法: c version",
	"help":         "用法: c help",
	"-h":           "用法: c help",
	"--help":       "用法: c help",
}

func (a *App) help() {
	fmt.Fprint(a.Out, `用法:
  c <命令> [参数]

站点:
  c list
  c list-emby
  c add <域名> <端口> [--path <前缀>] [--stream] [--http|--https] [--dns-only] [--skip-dns-check]
  c add <域名> --target <URL> [--stream] [--http|--https] [--dns-only] [--skip-dns-check]
  c add-static <域名> <目录> [--spa] [--http|--https] [--dns-only] [--skip-dns-check]
  c add-emby <域名> <目标> [--http|--https] [--dns-only] [--skip-dns-check]
  c add-gateway <域名> --allow <host:port,...> [--http|--https] [--dns-only] [--skip-dns-check]
  c set <域名> [--port|--path|--root|--target|--stream|--no-stream|--spa|--no-spa|--http|--https|--dns-only]
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
  c doctor            # 环境体检（别名 check-env）
  c cert-check <域名> # 证书/HTTPS 诊断
  c cloudflare set|check|remove   # 别名 cf
  c install [--cloudflare]
  c install-self
  c update [--latest|--ref <release-tag>] [--binary]
  c version

说明:
  · 任何命令支持 -h/--help 查看该命令用法。
  · add --target 用于反代外部 HTTPS 上游（PaaS 边缘按 Host 路由的场景，自动生成
    header_up Host 与 tls_server_name）；--stream 生成 flush_interval -1 关闭流式缓冲。
  · 所有命令均由 Go 原生实现；安装请使用 install-go.sh。
  · c update 和 --latest 默认更新到滚动版 go-latest；固定版本使用 --ref vX.Y.Z。
  · update --binary 额外调用 caddy upgrade --keep-backup；不会自动重启服务。
  · 无参数运行显示本帮助；help、-h、--help 同。
  · install 调用同分支 install-go.sh；install-self 仅安装当前本机二进制。
  · 设置 CADDYCTL_ROOT 可在隔离目录测试，不会访问生产 /etc/caddy。
`)
}
