package caddyctl

import (
	"strings"
	"testing"
)

// TestRenderGatewayRoutes 覆盖 allow-list 网关的正则路由、重写与 header_down 生成。
func TestRenderGatewayRoutes(t *testing.T) {
	opts := SiteOptions{
		Label:  "gate.example.com",
		Scheme: "https",
		Allow:  []string{"10.0.0.5:8096", "emby.internal:443"},
	}
	out, err := renderGateway(opts, "")
	if err != nil {
		t.Fatalf("renderGateway: %v", err)
	}
	// 访问格式与上游限制注释
	if !strings.Contains(out, "# 访问格式: https://gate.example.com/https://<上游主机:端口>/路径") {
		t.Error("missing access format comment")
	}
	if !strings.Contains(out, "仅允许: 10.0.0.5:8096,emby.internal:443") {
		t.Error("missing upstream restriction comment")
	}
	// 每个目标应有 http/https 重定向与代理路由
	for _, want := range []string{
		"redir_http_0", "redir_https_0", "httpProxy0", "httpsProxy0",
		"redir_http_1", "redir_https_1", "httpProxy1", "httpsProxy1",
		"to 10.0.0.5:8096", "to emby.internal:443",
		"flush_interval -1",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("gateway output missing %q", want)
		}
	}
	// Location 级联合并：http 和 https 合为一条正则（避免级联重写）
	if !strings.Contains(out, `header_down Location ^(https?)://`) {
		t.Error("missing merged Location header_down regex")
	}
	// 默认拒绝分支
	if !strings.Contains(out, `respond "upstream is not allowed" 403`) {
		t.Error("missing 403 fallback")
	}
}

// TestRenderGatewayDefaultPortRoutes 覆盖 80/443 默认端口的额外路由。
func TestRenderGatewayDefaultPortRoutes(t *testing.T) {
	opts := SiteOptions{Label: "gate.example.com", Scheme: "https", Allow: []string{"emby.internal:443"}}
	out, err := renderGateway(opts, "")
	if err != nil {
		t.Fatalf("renderGateway: %v", err)
	}
	for _, want := range []string{"redir_https_default_port_0", "httpsProxyDefaultPort0", "to emby.internal:443"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}
	// 443 上游应有 transport tls 块
	if !strings.Contains(out, "transport http {") || !strings.Contains(out, "keepalive_idle_conns_per_host 10") {
		t.Error("missing transport block")
	}
}

// TestRenderGatewayUnsafe 覆盖 --unsafe-open-proxy 的开放路由。
func TestRenderGatewayUnsafe(t *testing.T) {
	opts := SiteOptions{Label: "gate.example.com", Scheme: "https", UnsafeGateway: true}
	out, err := renderGateway(opts, "")
	if err != nil {
		t.Fatalf("renderGateway: %v", err)
	}
	for _, want := range []string{"httpProxyWithPort", "httpProxyNoPort", "httpsProxyWithPort", "httpsProxyNoPort", "任意上游（高风险"} {
		if !strings.Contains(out, want) {
			t.Errorf("unsafe gateway missing %q", want)
		}
	}
}

// TestRenderGatewayRequiresAllowList 覆盖无 allow-list 且非 unsafe 时报错。
func TestRenderGatewayRequiresAllowList(t *testing.T) {
	opts := SiteOptions{Label: "gate.example.com", Scheme: "https"}
	if _, err := renderGateway(opts, ""); err == nil {
		t.Fatal("expected error without allow-list or unsafe flag")
	}
}

// TestRenderGatewayInsecureVerify 覆盖内网 IP HTTPS 上游跳过证书验证。
func TestRenderGatewayInsecureVerify(t *testing.T) {
	opts := SiteOptions{Label: "gate.example.com", Scheme: "https", Allow: []string{"10.0.0.5:443"}}
	out, err := renderGateway(opts, "")
	if err != nil {
		t.Fatalf("renderGateway: %v", err)
	}
	if !strings.Contains(out, "tls_insecure_skip_verify") {
		t.Error("private IP HTTPS upstream should get tls_insecure_skip_verify")
	}
}
