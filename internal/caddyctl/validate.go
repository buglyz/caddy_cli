package caddyctl

import (
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	domainPartRE = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$`)
	emailLocalRE = regexp.MustCompile(`^[A-Za-z0-9._%+\-]+$`)
	unsafeTextRE = regexp.MustCompile(`[\r\n{}"';#\\]`)
	gatewayRE    = regexp.MustCompile(`^[A-Za-z0-9._:\-]+$`)
)

func validDomain(domain string) bool {
	if domain == "" || len(domain) > 253 || !strings.Contains(domain, ".") || strings.Contains(domain, "..") {
		return false
	}
	for _, part := range strings.Split(domain, ".") {
		if len(part) == 0 || len(part) > 63 || !domainPartRE.MatchString(part) {
			return false
		}
	}
	return true
}

func validSiteLabel(label string) bool {
	label = strings.TrimSpace(label)
	if label == "" || unsafeTextRE.MatchString(label) {
		return false
	}
	for _, part := range strings.Split(label, ",") {
		part = strings.TrimSpace(part)
		if strings.ContainsAny(part, " \t") || !validDomain(part) {
			return false
		}
	}
	return true
}

func validEmail(email string) bool {
	if email == "" {
		return true
	}
	if strings.ContainsAny(email, "\r\n \t") || strings.Count(email, "@") != 1 {
		return false
	}
	local, domain, _ := strings.Cut(email, "@")
	return local != "" && len(local) <= 64 && !strings.HasPrefix(local, ".") &&
		!strings.HasSuffix(local, ".") && !strings.Contains(local, "..") &&
		emailLocalRE.MatchString(local) && validDomain(domain)
}

func validPort(value string) bool {
	n, err := strconv.Atoi(value)
	return err == nil && n >= 1 && n <= 65535
}

func validPathPrefix(value string) bool {
	return strings.HasPrefix(value, "/") && value != "/" && !strings.ContainsAny(value, " \t\r\n{}\"';#\\")
}

// 敏感目录黑名单，防止静态站点 root 意外暴露系统文件
var sensitiveRootPrefixes = []string{
	"/", "/etc", "/proc", "/sys", "/dev", "/boot", "/root", "/var/log",
}

func validStaticRoot(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, "\r\n") {
		return false
	}
	clean := strings.TrimSuffix(value, "/")
	for _, prefix := range sensitiveRootPrefixes {
		if clean == prefix || strings.HasPrefix(clean, prefix+"/") {
			return false
		}
	}
	return true
}

func normalizePathPrefix(value string) string {
	value = strings.TrimSpace(value)
	value = strings.TrimSuffix(value, "*")
	value = strings.TrimSuffix(value, "/")
	if value == "" {
		return "/"
	}
	return value
}

func validProxyTarget(target string) bool {
	if unsafeTextRE.MatchString(target) || strings.ContainsAny(target, " \t") {
		return false
	}
	u, err := url.Parse(target)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" &&
		u.Path == "" && u.RawPath == "" && u.RawQuery == "" && u.Fragment == ""
}

// isPrivateHost 检测目标 host 是否为内网/保留地址（RFC1918/链路本地/环回/元数据端点）
func isPrivateHost(host string) bool {
	hostname := host
	if h, _, err := net.SplitHostPort(host); err == nil {
		hostname = h
	}
	ip := net.ParseIP(hostname)
	if ip == nil {
		// 域名场景：localhost 或 .local
		return hostname == "localhost" || strings.HasSuffix(hostname, ".local")
	}
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
		return true
	}
	// 云元数据端点 169.254.169.254
	if ip.Equal(net.ParseIP("169.254.169.254")) {
		return true
	}
	return false
}

// isIPHost 判断 URL 的 host 部分是否为 IP 地址（用于决定是否跳过 TLS 验证）
func isIPHost(target string) bool {
	u, err := url.Parse(target)
	if err != nil {
		return false
	}
	host := u.Hostname()
	return net.ParseIP(host) != nil
}

func parseGatewayAllow(spec string) ([]string, error) {
	var result []string
	for _, raw := range strings.Split(spec, ",") {
		item := strings.TrimSpace(raw)
		if item == "" {
			continue
		}
		host, port, err := net.SplitHostPort(item)
		if err != nil || host == "" || !validPort(port) || !gatewayRE.MatchString(item) {
			return nil, fmt.Errorf("网关 allow-list 条目不合法: %s（请使用 host:port）", item)
		}
		result = append(result, item)
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("allow-list 不能为空")
	}
	return result, nil
}

func (a *App) checkDNS(label string) error {
	if truthy(getenv("CADDYCTL_SKIP_DNS_CHECK", "0")) {
		return nil
	}
	local := map[string]bool{"127.0.0.1": true, "::1": true}
	ifaces, _ := net.InterfaceAddrs()
	for _, addr := range ifaces {
		if ip, _, err := net.ParseCIDR(addr.String()); err == nil {
			local[ip.String()] = true
		}
	}
	for _, endpoint := range []string{"https://api.ipify.org", "https://api64.ipify.org"} {
		client := http.Client{Timeout: 3 * time.Second}
		if resp, err := client.Get(endpoint); err == nil {
			var buf [64]byte
			n, _ := resp.Body.Read(buf[:])
			resp.Body.Close()
			if ip := net.ParseIP(strings.TrimSpace(string(buf[:n]))); ip != nil {
				local[ip.String()] = true
			}
		}
	}
	for _, domain := range strings.Split(label, ",") {
		domain = strings.TrimSpace(domain)
		ips, err := net.LookupIP(domain)
		if err != nil || len(ips) == 0 {
			return fmt.Errorf("域名未解析到任何 A/AAAA 记录: %s", domain)
		}
		matched := false
		for _, ip := range ips {
			matched = matched || local[ip.String()]
		}
		if !matched {
			return fmt.Errorf("域名未解析到本机: %s；内网、测试或 Cloudflare 代理场景可加 --skip-dns-check", domain)
		}
	}
	return nil
}

func getenv(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
