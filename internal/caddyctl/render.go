package caddyctl

import (
	"bytes"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type SiteKind string

const (
	SiteProxy   SiteKind = "反代站点"
	SitePath    SiteKind = "路径反代"
	SiteRemote  SiteKind = "远程反代"
	SiteStatic  SiteKind = "静态站点"
	SiteEmby    SiteKind = "Emby反代"
	SiteGateway SiteKind = "网关"
	SiteUnknown SiteKind = "未知类型"
)

type SiteOptions struct {
	Label, Scheme, Port, Path, Root, Target string
	SPA, DNSTLS, Stream                     bool
	Allow                                   []string
	UnsafeGateway                           bool
}

func (a *App) renderManaged() ([]byte, error) {
	var out bytes.Buffer
	out.WriteString("# managed by caddyctl\n\n")
	globals, err := matchingFiles(a.Paths.Globals, "*.inc")
	if err != nil {
		return nil, err
	}
	if a.State.Email != "" || len(globals) > 0 {
		out.WriteString("{\n")
		if a.State.Email != "" {
			fmt.Fprintf(&out, "    email %s\n", quoteCaddy(a.State.Email))
		}
		for _, path := range globals {
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				return nil, readErr
			}
			for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
				if strings.TrimSpace(line) == "" {
					out.WriteByte('\n')
				} else {
					fmt.Fprintf(&out, "    %s\n", line)
				}
			}
		}
		out.WriteString("}\n\n")
	}
	sites, err := matchingFiles(a.Paths.Sites, "*.conf")
	if err != nil {
		return nil, err
	}
	for _, path := range sites {
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil, readErr
		}
		out.Write(bytes.TrimRight(data, "\n"))
		out.WriteString("\n\n")
	}
	return out.Bytes(), nil
}

func matchingFiles(dir, pattern string) ([]string, error) {
	files, err := filepath.Glob(filepath.Join(dir, pattern))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
}

func renderSite(opts SiteOptions, kind SiteKind) (string, error) {
	label := formatLabels(opts.Label, opts.Scheme)
	tls := ""
	if opts.Scheme != "http" && opts.DNSTLS {
		tls = "    tls {\n        dns cloudflare {env.CLOUDFLARE_API_TOKEN}\n    }\n"
	}
	switch kind {
	case SiteProxy:
		target := "127.0.0.1:" + opts.Port
		if opts.Scheme == "http" {
			target = "http://" + target
		}
		stream := ""
		if opts.Stream {
			stream = "    flush_interval -1\n"
		}
		return fmt.Sprintf("%s {\n    encode zstd gzip\n%s%s    reverse_proxy %s\n}\n", label, tls, stream, target), nil
	case SitePath:
		matcher := "@path_" + sanitizeName(primaryLabel(opts.Label)) + "_" + sanitizeName(opts.Path)
		target := "127.0.0.1:" + opts.Port
		if opts.Scheme == "http" {
			target = "http://" + target
		}
		return fmt.Sprintf("%s {\n    encode zstd gzip\n%s    %s path %s %s/*\n    handle %s {\n        uri strip_prefix %s\n        reverse_proxy %s\n    }\n    handle {\n        respond \"Not Found\" 404\n    }\n}\n", label, tls, matcher, quoteCaddy(opts.Path), quoteCaddy(opts.Path+"/*"), matcher, quoteCaddy(opts.Path), target), nil
	case SiteRemote:
		// 远程 HTTPS 上游（PaaS 边缘如 Northflank *.code.run、Cloudflare）按 Host 头路由
		// 且证书只匹配自己的域名：必须改写 Host 并显式指定 SNI，否则 404/503 或握手失败。
		host := remoteHost(opts.Target)
		if host == "" {
			return "", fmt.Errorf("无法解析目标主机: %s", opts.Target)
		}
		var transport strings.Builder
		transport.WriteString("        transport http {\n")
		if strings.HasPrefix(opts.Target, "https://") {
			transport.WriteString("            tls\n")
			transport.WriteString("            tls_server_name " + host + "\n")
		}
		transport.WriteString("            dial_timeout 5s\n")
		transport.WriteString("            response_header_timeout 300s\n")
		transport.WriteString("            keepalive 30s\n")
		transport.WriteString("            keepalive_idle_conns 100\n")
		transport.WriteString("            keepalive_idle_conns_per_host 10\n")
		transport.WriteString("        }\n")
		stream := ""
		if opts.Stream {
			stream = "        flush_interval -1\n"
		}
		return fmt.Sprintf("%s {\n    encode zstd gzip\n%s    reverse_proxy %s {\n        header_up Host %s\n%s%s    }\n}\n", label, tls, quoteCaddy(opts.Target), host, stream, transport.String()), nil
	case SiteStatic:
		spa := ""
		if opts.SPA {
			spa = "    try_files {path} /index.html\n"
		}
		return fmt.Sprintf("%s {\n    encode zstd gzip\n%s    root * %s\n%s    file_server\n}\n", label, tls, quoteCaddy(opts.Root), spa), nil
	case SiteEmby:
		// Emby 流媒体反代：flush_interval -1 关闭缓冲保证流式传输；
		// keepalive 连接池复用上游 TCP，减少握手开销。
		var transport string
		if strings.HasPrefix(opts.Target, "https://") {
			tlsLine := "            tls\n"
			// 对内网 IP 地址的 HTTPS 上游，跳过 TLS 证书验证（自签证书场景）
			if isIPHost(opts.Target) {
				tlsLine = "            tls\n            tls_insecure_skip_verify\n"
			}
			transport = transportBlock("        ", tlsLine)
		} else {
			transport = transportBlock("        ", "")
		}
		return fmt.Sprintf("%s {\n%s    reverse_proxy %s {\n        header_up Host {upstream_hostport}\n%s        flush_interval -1\n    }\n}\n", label, tls, quoteCaddy(opts.Target), transport), nil
	case SiteGateway:
		return renderGateway(opts, tls)
	default:
		return "", fmt.Errorf("未知站点类型: %s", kind)
	}
}

func formatLabels(label, scheme string) string {
	parts := strings.Split(label, ",")
	for i, part := range parts {
		part = strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(part), "http://"), "https://"))
		if scheme == "http" {
			part = "http://" + part
		}
		parts[i] = part
	}
	return strings.Join(parts, ", ")
}

func primaryLabel(label string) string {
	first, _, _ := strings.Cut(label, ",")
	return strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(first, "http://"), "https://"))
}

func sanitizeName(value string) string {
	replacer := strings.NewReplacer("/", "_", ":", "_", " ", "_", ",", "_")
	value = replacer.Replace(value)
	return regexp.MustCompile(`[^A-Za-z0-9._-]`).ReplaceAllString(value, "")
}

func quoteCaddy(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	return `"` + value + `"`
}

// unquoteCaddy 是 quoteCaddy 的逆操作：去掉包裹引号并还原转义，
// 用于从站点配置行中解析出原始目标值。
func unquoteCaddy(value string) string {
	if len(value) >= 2 && strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`) {
		value = value[1 : len(value)-1]
		value = strings.ReplaceAll(value, `\"`, `"`)
		value = strings.ReplaceAll(value, `\\`, `\`)
	}
	return value
}

// remoteHost 从目标 URL 提取用于 header_up Host / tls_server_name 的裸主机名
// （去掉端口与路径）。IPv6 地址保留方括号形式。
func remoteHost(target string) string {
	u, err := url.Parse(target)
	if err != nil || u.Host == "" {
		return ""
	}
	host := u.Hostname()
	if host == "" {
		return ""
	}
	if ip := net.ParseIP(host); ip != nil && ip.To4() == nil {
		return "[" + host + "]"
	}
	return host
}

func detectSite(data string) SiteKind {
	headerUpHostRE := regexp.MustCompile(`(?m)^\s*header_up Host\s+(\S+)`)
	switch {
	// 注释可能被 import 重写丢弃，网关同时按内容特征（path_regexp 动态回源匹配器）识别。
	case strings.Contains(data, "通用反代网关") || strings.Contains(data, "path_regexp"):
		return SiteGateway
	case regexp.MustCompile(`(?m)^\s*file_server(?:\s|$)`).MatchString(data):
		return SiteStatic
	case strings.Contains(data, "uri strip_prefix") && regexp.MustCompile(`(?m)^\s*@path_.* path `).MatchString(data):
		return SitePath
	case strings.Contains(data, "tls_server_name"):
		return SiteRemote
	case strings.Contains(data, "header_up Host {upstream_hostport}"):
		return SiteEmby
	case headerUpHostRE.MatchString(data):
		return SiteRemote
	case regexp.MustCompile(`(?m)^\s*reverse_proxy `).MatchString(data):
		return SiteProxy
	default:
		return SiteUnknown
	}
}

// normalizeCaddyfile 规范化 Caddyfile 内容用于一致性比较。
// 统一换行为 \n，去除每行尾部空白与首尾空白，折叠连续空行为单个空行。
// 这样 assertManaged 不会因为无关的空白/换行差异（如 caddy fmt、手动编辑）
// 误判为"不一致"，但仍能捕获真实的配置内容差异。
func normalizeCaddyfile(data []byte) []byte {
	// 统一换行
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	lines := strings.Split(text, "\n")
	var out []string
	for _, line := range lines {
		// 去除每行尾部空白（含尾部注释外的多余空格）
		out = append(out, strings.TrimRight(line, " \t"))
	}
	// 折叠连续空行为单个空行，并去除首尾空白
	joined := strings.Join(out, "\n")
	// 折叠 3+ 换行为 2 换行（即最多一个空行）
	for strings.Contains(joined, "\n\n\n") {
		joined = strings.ReplaceAll(joined, "\n\n\n", "\n\n")
	}
	return []byte(strings.TrimSpace(joined))
}

// transportBlock 生成 Caddyfile transport http 块（keepalive 连接池）。
// insecure 为 true 时对内网 HTTPS 上游加 tls_insecure_skip_verify。
// indent 为每行前导空格（外层调用者决定层级）。
func transportBlock(indent string, tlsLine string) string {
	out := indent + "transport http {\n"
	if tlsLine != "" {
		out += tlsLine
	}
	out += indent + "    keepalive 30s\n"
	out += indent + "    keepalive_idle_conns 100\n"
	out += indent + "    keepalive_idle_conns_per_host 10\n"
	out += indent + "}\n"
	return out
}
