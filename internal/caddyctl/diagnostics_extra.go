package caddyctl

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

func (a *App) doctorLayout() {
	fmt.Fprintln(a.Out, "\n===== CLI / 布局 =====")
	fmt.Fprintf(a.Out, "[INFO] Go CLI 版本: %s\n", Version)
	if _, err := os.Stat(a.Paths.PendingImport); err == nil {
		fmt.Fprintf(a.Out, "[WARN] 存在首次导入标记: %s\n", a.Paths.PendingImport)
	}
	if _, err := os.Stat(a.Paths.PendingImport + ".failed"); err == nil {
		fmt.Fprintf(a.Out, "[WARN] 自动导入曾失败: %s.failed\n", a.Paths.PendingImport)
	}
	live, err := os.ReadFile(a.Paths.Caddyfile)
	if err != nil {
		fmt.Fprintln(a.Out, "[WARN] 无法读取 live Caddyfile")
		return
	}
	text := string(live)
	if regexp.MustCompile(`(?m)^\s*import\s+.*sites\.d`).MatchString(text) || strings.Contains(text, "# managed by caddyctl") {
		fmt.Fprintln(a.Out, "[OK] Caddyfile 使用标准 managed 布局")
		return
	}
	sites, siteErr := a.allSites()
	inline := siteHeaderRE.MatchString(text)
	if siteErr == nil && len(sites) > 0 && inline {
		fmt.Fprintln(a.Out, "[WARN] 疑似 dual-write：sites.d 有站点且主 Caddyfile 使用内联站点块")
	} else if inline {
		fmt.Fprintln(a.Out, "[INFO] 主 Caddyfile 使用内联站点块")
	} else {
		fmt.Fprintln(a.Out, "[INFO] 未识别到典型站点布局")
	}
}

func (a *App) doctorRuntime(rendered []byte) {
	fmt.Fprintln(a.Out, "\n===== 端口监听 =====")
	for _, port := range []string{"80", "443"} {
		conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), 250*time.Millisecond)
		if err != nil {
			fmt.Fprintf(a.Out, "[WARN] TCP %s 未监听\n", port)
			continue
		}
		conn.Close()
		fmt.Fprintf(a.Out, "[OK] TCP %s 正在监听\n", port)
	}

	fmt.Fprintln(a.Out, "\n===== 本地上游 =====")
	matches := reverseProxyRE.FindAllSubmatch(rendered, -1)
	if len(matches) == 0 {
		fmt.Fprintln(a.Out, "[INFO] 未发现 localhost 上游")
	} else {
		seen := map[string]bool{}
		for _, match := range matches {
			port := string(match[1])
			if seen[port] {
				continue
			}
			seen[port] = true
			conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), 250*time.Millisecond)
			if err != nil {
				fmt.Fprintf(a.Out, "[WARN] localhost:%s 未监听\n", port)
			} else {
				conn.Close()
				fmt.Fprintf(a.Out, "[OK] localhost:%s 可连接\n", port)
			}
		}
	}
	a.doctorTLSFiles(rendered)
	a.doctorNginxCoverage(rendered)
}

var tlsFilesRE = regexp.MustCompile(`(?m)^\s*tls\s+("(?:\\.|[^"])+"|\S+)\s+("(?:\\.|[^"])+"|\S+)\s*$`)

func (a *App) doctorTLSFiles(rendered []byte) {
	fmt.Fprintln(a.Out, "\n===== TLS 文件引用 =====")
	matches := tlsFilesRE.FindAllSubmatch(rendered, -1)
	if len(matches) == 0 {
		fmt.Fprintln(a.Out, "[INFO] 未发现手工证书文件引用")
		return
	}
	for _, match := range matches {
		for _, raw := range match[1:] {
			path := strings.Trim(string(raw), `"`)
			checkPath := path
			if a.Paths.Root != "" && filepath.IsAbs(path) {
				checkPath = filepath.Join(a.Paths.Root, strings.TrimPrefix(path, "/"))
			}
			if _, err := os.Stat(checkPath); err == nil {
				fmt.Fprintf(a.Out, "[OK] %s\n", path)
			} else {
				fmt.Fprintf(a.Out, "[WARN] TLS 文件不存在: %s\n", path)
			}
		}
	}
}

func (a *App) doctorNginxCoverage(rendered []byte) {
	fmt.Fprintln(a.Out, "\n===== nginx 迁移覆盖 =====")
	dir := "/etc/nginx/conf.d"
	if a.Paths.Root != "" {
		dir = filepath.Join(a.Paths.Root, "etc/nginx/conf.d")
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*.conf"))
	if len(files) == 0 {
		fmt.Fprintln(a.Out, "[INFO] 未发现 nginx conf.d 站点")
		return
	}
	nameRE := regexp.MustCompile(`(?m)^\s*server_name\s+([^;]+);`)
	missing := map[string]bool{}
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		for _, match := range nameRE.FindAllSubmatch(data, -1) {
			for _, name := range strings.Fields(string(match[1])) {
				if name != "_" && !strings.Contains(string(rendered), name) {
					missing[name] = true
				}
			}
		}
	}
	if len(missing) == 0 {
		fmt.Fprintln(a.Out, "[OK] nginx server_name 均可在 managed 配置中找到")
		return
	}
	names := make([]string, 0, len(missing))
	for name := range missing {
		names = append(names, name)
	}
	sort.Strings(names)
	fmt.Fprintf(a.Out, "[WARN] 未迁移的 nginx server_name: %s\n", strings.Join(names, ", "))
}

func (a *App) printCertificateLogs() {
	if a.Paths.Root != "" {
		return
	}
	if _, err := exec.LookPath("journalctl"); err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := exec.CommandContext(ctx, "journalctl", "-u", "caddy", "-n", "300", "--no-pager").Output()
	if err != nil {
		return
	}
	var matching []string
	for _, line := range strings.Split(string(data), "\n") {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "acme") || strings.Contains(lower, "certificate") || strings.Contains(lower, "tls") || strings.Contains(lower, "challenge") {
			matching = append(matching, line)
		}
	}
	if len(matching) > 20 {
		matching = matching[len(matching)-20:]
	}
	if len(matching) > 0 {
		fmt.Fprintln(a.Out, "\n===== 最近证书相关日志（最多20行） =====")
		fmt.Fprintln(a.Out, strings.Join(matching, "\n"))
	}
}
