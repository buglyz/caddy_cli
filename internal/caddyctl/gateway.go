package caddyctl

import (
	"fmt"
	"net"
	"regexp"
	"strings"
)

func renderGateway(opts SiteOptions, tls string) (string, error) {
	label := primaryLabel(opts.Label)
	if !validDomain(label) {
		return "", fmt.Errorf("网关域名不合法")
	}
	access := "任意上游（高风险，仅限受控网络或已加外部认证）"
	if len(opts.Allow) > 0 {
		access = "仅允许: " + strings.Join(opts.Allow, ",")
	} else if !opts.UnsafeGateway {
		return "", fmt.Errorf("网关默认需要 allow-list")
	}
	scheme := opts.Scheme
	if scheme == "" {
		scheme = "https"
	}
	var out strings.Builder
	fmt.Fprintf(&out, "# Emby 通用反代网关\n# 访问格式: %s://%s/https://<上游主机:端口>/路径\n# 上游限制: %s\n\n%s://%s {\n%s", scheme, label, access, scheme, label, tls)
	out.WriteString("    request_body {\n        max_size 500MB\n    }\n\n")
	info := fmt.Sprintf("OK\n\n通用反代网关 — Emby Proxy Toolbox (Caddy)\n\n使用方式：\n  %s://%s/http://<上游主机:端口>/路径\n  %s://%s/https://<上游主机:端口>/路径\n\n上游限制: %s\n回源协议由路径中的 http:// 或 https:// 决定。", scheme, label, scheme, label, access)
	fmt.Fprintf(&out, "    handle / {\n        respond %q 200\n    }\n\n", info)
	if len(opts.Allow) == 0 {
		emitUnsafeGatewayRoutes(&out, scheme, label)
	} else {
		for i, target := range opts.Allow {
			host, port, _ := net.SplitHostPort(target)
			emitGatewayTarget(&out, i, target, host, port, scheme, label)
		}
		out.WriteString("    handle {\n        respond \"upstream is not allowed\" 403\n    }\n")
	}
	out.WriteString("}\n")
	return out.String(), nil
}

func emitGatewayTarget(out *strings.Builder, index int, target, host, port, scheme, label string) {
	targetRE := regexp.QuoteMeta(target)
	hostRE := regexp.QuoteMeta(host)
	emitGatewayRedirect(out, fmt.Sprintf("noSlashHttp%d", index), fmt.Sprintf("redir_http_%d", index), `^/http:/*`+targetRE+`$`, `/http://`+target+`/`)
	emitGatewayRedirect(out, fmt.Sprintf("noSlashHttps%d", index), fmt.Sprintf("redir_https_%d", index), `^/https:/*`+targetRE+`$`, `/https://`+target+`/`)
	emitGatewayRoute(out, fmt.Sprintf("httpProxy%d", index), fmt.Sprintf("up_http_%d", index), `^/http:/*`+targetRE+`(/.*)`, fmt.Sprintf("{re.up_http_%d.1}", index), target, "http", target, scheme+"://"+label+"/http://"+target)
	emitGatewayRoute(out, fmt.Sprintf("httpsProxy%d", index), fmt.Sprintf("up_https_%d", index), `^/https:/*`+targetRE+`(/.*)`, fmt.Sprintf("{re.up_https_%d.1}", index), target, "https", target, scheme+"://"+label+"/https://"+target)
	if port == "80" {
		emitGatewayRedirect(out, fmt.Sprintf("noSlashHttpDefaultPort%d", index), fmt.Sprintf("redir_http_default_port_%d", index), `^/http:/*`+hostRE+`$`, `/http://`+host+`/`)
		emitGatewayRoute(out, fmt.Sprintf("httpProxyDefaultPort%d", index), fmt.Sprintf("up_http_default_port_%d", index), `^/http:/*`+hostRE+`(/.*)`, fmt.Sprintf("{re.up_http_default_port_%d.1}", index), host+":80", "http", host, scheme+"://"+label+"/http://"+host)
	}
	if port == "443" {
		emitGatewayRedirect(out, fmt.Sprintf("noSlashHttpsDefaultPort%d", index), fmt.Sprintf("redir_https_default_port_%d", index), `^/https:/*`+hostRE+`$`, `/https://`+host+`/`)
		emitGatewayRoute(out, fmt.Sprintf("httpsProxyDefaultPort%d", index), fmt.Sprintf("up_https_default_port_%d", index), `^/https:/*`+hostRE+`(/.*)`, fmt.Sprintf("{re.up_https_default_port_%d.1}", index), host+":443", "https", host, scheme+"://"+label+"/https://"+host)
	}
}

func emitGatewayRedirect(out *strings.Builder, matcher, name, pattern, target string) {
	fmt.Fprintf(out, "    @%s path_regexp %s %s\n    redir @%s %s 308\n\n", matcher, name, pattern, matcher, target)
}

func emitGatewayRoute(out *strings.Builder, matcher, name, pattern, rest, upstream, upstreamScheme, hostHeader, location string) {
	fmt.Fprintf(out, "    @%s path_regexp %s %s\n    handle @%s {\n        rewrite * %s\n        reverse_proxy {\n            to %s\n", matcher, name, pattern, matcher, rest, upstream)
	if upstreamScheme == "https" {
		out.WriteString("            transport http {\n                tls\n            }\n")
	} else {
		out.WriteString("            transport http\n")
	}
	gatewayBase := location
	if schemeEnd := strings.Index(location, "://"); schemeEnd >= 0 {
		if pathStart := strings.Index(location[schemeEnd+3:], "/"); pathStart >= 0 {
			gatewayBase = location[:schemeEnd+3+pathStart]
		}
	}
	fmt.Fprintf(out, "            header_up Host %s\n            header_up X-Real-IP {remote_host}\n            header_down Location ^http://([^/]+)(/.*)$ %s/http://$1$2\n            header_down Location ^https://([^/]+)(/.*)$ %s/https://$1$2\n            header_down Location ^/(.*)$ %s/$1\n            header_down Location ^([^/:][^:]*)$ %s/$1\n            flush_interval -1\n        }\n    }\n\n", hostHeader, gatewayBase, gatewayBase, location, location)
}

func emitUnsafeGatewayRoutes(out *strings.Builder, scheme, label string) {
	out.WriteString("    @noSlashHttp path_regexp redir_http ^/http:/*([A-Za-z0-9.\\-_:]+)$\n    redir @noSlashHttp /http://{re.redir_http.1}/ 308\n\n    @noSlashHttps path_regexp redir_https ^/https:/*([A-Za-z0-9.\\-_:]+)$\n    redir @noSlashHttps /https://{re.redir_https.1}/ 308\n\n")
	emitGatewayRoute(out, "httpProxyWithPort", "up_http_port", `^/http:/*([A-Za-z0-9.\-_]+):([0-9]+)(/.*)`, "{re.up_http_port.3}", "{re.up_http_port.1}:{re.up_http_port.2}", "http", "{re.up_http_port.1}:{re.up_http_port.2}", scheme+"://"+label+"/http://{re.up_http_port.1}:{re.up_http_port.2}")
	emitGatewayRoute(out, "httpProxyNoPort", "up_http_host", `^/http:/*([A-Za-z0-9.\-_]+)(/.*)`, "{re.up_http_host.2}", "{re.up_http_host.1}:80", "http", "{re.up_http_host.1}", scheme+"://"+label+"/http://{re.up_http_host.1}")
	emitGatewayRoute(out, "httpsProxyWithPort", "up_https_port", `^/https:/*([A-Za-z0-9.\-_]+):([0-9]+)(/.*)`, "{re.up_https_port.3}", "{re.up_https_port.1}:{re.up_https_port.2}", "https", "{re.up_https_port.1}:{re.up_https_port.2}", scheme+"://"+label+"/https://{re.up_https_port.1}:{re.up_https_port.2}")
	emitGatewayRoute(out, "httpsProxyNoPort", "up_https_host", `^/https:/*([A-Za-z0-9.\-_]+)(/.*)`, "{re.up_https_host.2}", "{re.up_https_host.1}:443", "https", "{re.up_https_host.1}", scheme+"://"+label+"/https://{re.up_https_host.1}")
}
