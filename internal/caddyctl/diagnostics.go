package caddyctl

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

func (a *App) doctor() error {
	fmt.Fprintln(a.Out, "===== 环境检查 =====")
	if err := a.caddyExists(); err != nil {
		fmt.Fprintln(a.Out, "[NO] 未安装 caddy")
	} else {
		path, _ := exec.LookPath(a.CaddyBin)
		if strings.Contains(a.CaddyBin, "/") {
			path = a.CaddyBin
		}
		version, _ := exec.Command(a.CaddyBin, "version").CombinedOutput()
		fmt.Fprintf(a.Out, "[OK] 已安装 caddy: %s (%s)\n", path, valueOr(strings.TrimSpace(string(version)), "unknown"))
	}
	backend := serviceBackend()
	if a.Paths.Root != "" {
		backend = ""
	}
	if backend == "" {
		fmt.Fprintln(a.Out, "[WARN] 未检测到 service manager（systemd/OpenRC）")
	} else {
		fmt.Fprintf(a.Out, "[OK] 检测到 service manager: %s\n", backend)
		if err := runServiceCommand(a.State.Timeout, backend, "is-active"); err == nil {
			fmt.Fprintln(a.Out, "[OK] Caddy 正在运行")
		} else {
			fmt.Fprintln(a.Out, "[WARN] Caddy 未运行")
		}
	}
	fmt.Fprintf(a.Out, "[INFO] 操作锁等待: %ss\n", getenv("CADDYCTL_LOCK_WAIT_SECONDS", "30"))
	fmt.Fprintf(a.Out, "[INFO] 上游健康检查模式: %s\n", getenv("CADDYCTL_UPSTREAM_CHECK_MODE", a.State.UpstreamMode))

	fmt.Fprintln(a.Out, "\n===== 目录检查 =====")
	for _, path := range []string{a.Paths.Caddyfile, a.Paths.Sites, a.Paths.Globals, a.Paths.Backup, a.Paths.State, a.Paths.AccessLog} {
		if _, err := os.Stat(path); err == nil {
			fmt.Fprintf(a.Out, "[OK] %s\n", path)
		} else {
			fmt.Fprintf(a.Out, "[WARN] %s 不存在或不可读\n", path)
		}
	}
	if a.Cloudflare {
		if _, err := os.Stat(a.Paths.CloudflareEnv); err == nil {
			fmt.Fprintln(a.Out, "[OK] Cloudflare API Token 已配置")
		} else {
			fmt.Fprintln(a.Out, "[WARN] Cloudflare API Token 未配置")
		}
	}
	a.doctorLayout()

	fmt.Fprintln(a.Out, "\n===== 配置检查 =====")
	if err := a.assertManaged(); err != nil {
		fmt.Fprintf(a.Out, "[WARN] %v\n", err)
	} else {
		fmt.Fprintln(a.Out, "[OK] live Caddyfile 与 managed 渲染一致")
	}
	rendered, err := a.renderManaged()
	if err != nil {
		return err
	}
	if err := a.validate(rendered); err != nil {
		fmt.Fprintf(a.Out, "[WARN] %v\n", err)
	} else {
		fmt.Fprintln(a.Out, "[OK] managed 配置校验通过")
	}
	a.doctorRuntime(rendered)
	return nil
}

func (a *App) certCheck(args []string) error {
	if len(args) == 0 || !validDomain(strings.TrimSpace(args[0])) {
		return fmt.Errorf("用法: c cert-check <合法域名>")
	}
	domain := strings.TrimSpace(args[0])
	fmt.Fprintf(a.Out, "===== 证书诊断: %s =====\n", domain)
	ips, err := net.LookupIP(domain)
	if err != nil || len(ips) == 0 {
		fmt.Fprintln(a.Out, "[WARN] DNS 未解析到 A/AAAA 记录")
	} else {
		var values []string
		for _, ip := range ips {
			values = append(values, ip.String())
		}
		fmt.Fprintf(a.Out, "[OK] DNS 解析: %s\n", strings.Join(values, ", "))
	}
	if site, findErr := a.findSite(domain); findErr == nil {
		fmt.Fprintf(a.Out, "[OK] 站点配置存在: %s\n", site.Path)
	} else {
		fmt.Fprintln(a.Out, "[WARN] 未在站点配置中发现该域名")
	}
	for _, scheme := range []string{"http", "https"} {
		status, requestErr := probeURL(scheme + "://" + domain + "/")
		if requestErr != nil {
			fmt.Fprintf(a.Out, "[WARN] %s 不可达: %v\n", strings.ToUpper(scheme), requestErr)
		} else {
			fmt.Fprintf(a.Out, "[OK] %s 可达，状态码: %d\n", strings.ToUpper(scheme), status)
		}
	}
	a.printCertificateLogs()
	return nil
}

func probeURL(target string) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return 0, err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return 0, err
	}
	response.Body.Close()
	return response.StatusCode, nil
}
