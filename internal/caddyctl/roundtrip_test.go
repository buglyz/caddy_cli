package caddyctl

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestRenderParseRoundTrip 不变量：render → detect/optionsFromSite → render
// 必须逐字节一致。解析器与渲染器的任何分歧（引号、scheme、注释、字段回读）
// 都会在测试生成阶段被抓住，而不是在实机上以配置损坏的形式出现。
func TestRenderParseRoundTrip(t *testing.T) {
	cases := []struct {
		name string
		kind SiteKind
		opts SiteOptions
	}{
		{"proxy", SiteProxy, SiteOptions{Label: "app.example.com", Port: "3000", Scheme: "https"}},
		{"proxy-http", SiteProxy, SiteOptions{Label: "app.example.com", Port: "3000", Scheme: "http"}},
		{"proxy-stream", SiteProxy, SiteOptions{Label: "app.example.com", Port: "3000", Scheme: "https", Stream: true}},
		{"proxy-multi-label", SiteProxy, SiteOptions{Label: "a.example.com, b.example.com", Port: "3000", Scheme: "https"}},
		{"path", SitePath, SiteOptions{Label: "api.example.com", Port: "3001", Path: "/api", Scheme: "https"}},
		{"path-nested", SitePath, SiteOptions{Label: "api.example.com", Port: "3001", Path: "/v1/export", Scheme: "https"}},
		{"remote", SiteRemote, SiteOptions{Label: "r.example.com", Target: "https://up.example.com", Scheme: "https"}},
		{"remote-stream", SiteRemote, SiteOptions{Label: "r.example.com", Target: "https://up.example.com", Scheme: "https", Stream: true}},
		{"remote-http-upstream", SiteRemote, SiteOptions{Label: "r.example.com", Target: "http://up.example.com", Scheme: "https"}},
		{"remote-dns-only", SiteRemote, SiteOptions{Label: "r.example.com", Target: "https://up.example.com", Scheme: "https", DNSTLS: true}},
		{"static", SiteStatic, SiteOptions{Label: "s.example.com", Root: "/srv/site", Scheme: "https"}},
		{"static-spa", SiteStatic, SiteOptions{Label: "s.example.com", Root: "/srv/site with spaces", SPA: true, Scheme: "https"}},
		{"emby-ip", SiteEmby, SiteOptions{Label: "e.example.com", Target: "https://10.0.0.5:8096", Scheme: "https"}},
		{"emby-domain", SiteEmby, SiteOptions{Label: "e.example.com", Target: "https://emby.up.example.com:443", Scheme: "https"}},
		{"gateway", SiteGateway, SiteOptions{Label: "g.example.com", Scheme: "https", Allow: []string{"e.example.com:443", "10.0.0.5:8096"}}},
		{"gateway-unsafe", SiteGateway, SiteOptions{Label: "g.example.com", Scheme: "https", UnsafeGateway: true}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			first, err := renderSite(tc.opts, tc.kind)
			if err != nil {
				t.Fatalf("render: %v", err)
			}
			kind := detectSite(first)
			if kind != tc.kind {
				t.Fatalf("detectSite = %q, want %q\ndata:\n%s", kind, tc.kind, first)
			}
			site := siteFile{Data: first, Kind: kind, Labels: extractLabels(first)}
			parsed, err := optionsFromSite(site)
			if err != nil {
				t.Fatalf("parse: %v\n--- data ---\n%s", err, first)
			}
			second, err := renderSite(parsed, kind)
			if err != nil {
				t.Fatalf("re-render: %v", err)
			}
			if first != second {
				t.Errorf("round-trip mismatch:\n--- first ---\n%s\n--- second ---\n%s", first, second)
			}
		})
	}
}

// TestRenderedKindsValidateWithRealCaddy 用真实 caddy 校验每种类型的渲染产物。
// 找不到 caddy 时跳过（本地开发）；CI 已安装 caddy，始终执行。
func TestRenderedKindsValidateWithRealCaddy(t *testing.T) {
	caddyBin := os.Getenv("CADDYCTL_TEST_CADDY")
	if caddyBin == "" {
		if _, err := exec.LookPath("caddy"); err != nil {
			t.Skip("未找到 caddy，跳过真实校验")
		}
		caddyBin = "caddy"
	}
	app, _, _ := newTestApp(t, "")
	app.CaddyBin = caddyBin

	// dns-only 变体依赖 Cloudflare DNS 插件，标准 caddy 无法校验，不在覆盖范围。
	cases := []struct {
		name string
		kind SiteKind
		opts SiteOptions
	}{
		{"proxy", SiteProxy, SiteOptions{Label: "p1.example.com", Port: "3000", Scheme: "https"}},
		{"proxy-stream", SiteProxy, SiteOptions{Label: "p2.example.com", Port: "3000", Scheme: "https", Stream: true}},
		{"proxy-http", SiteProxy, SiteOptions{Label: "p3.example.com", Port: "3000", Scheme: "http"}},
		{"path", SitePath, SiteOptions{Label: "p4.example.com", Port: "3001", Path: "/api", Scheme: "https"}},
		{"remote-https-stream", SiteRemote, SiteOptions{Label: "r1.example.com", Target: "https://up1.example.com", Scheme: "https", Stream: true}},
		{"remote-http-upstream", SiteRemote, SiteOptions{Label: "r2.example.com", Target: "http://up2.example.com", Scheme: "https"}},
		{"static-spa", SiteStatic, SiteOptions{Label: "s1.example.com", Root: "/srv/site with spaces", SPA: true, Scheme: "https"}},
		{"emby-ip", SiteEmby, SiteOptions{Label: "e1.example.com", Target: "https://10.0.0.5:8096", Scheme: "https"}},
		{"gateway", SiteGateway, SiteOptions{Label: "g1.example.com", Scheme: "https", Allow: []string{"e1.example.com:443", "10.0.0.5:8096"}}},
	}
	var combined strings.Builder
	combined.WriteString("{\n    email admin@example.com\n}\n\n")
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			data, err := renderSite(tc.opts, tc.kind)
			if err != nil {
				t.Fatalf("render: %v", err)
			}
			if err := app.validate([]byte(data)); err != nil {
				t.Errorf("rendered config rejected by real caddy:\n%s\n%v", data, err)
			}
			combined.WriteString(data)
			combined.WriteString("\n")
		})
	}
	// 全部类型共存于一个 Caddyfile 时也必须合法（跨站点冲突检查）。
	t.Run("combined", func(t *testing.T) {
		if err := app.validate([]byte(combined.String())); err != nil {
			t.Errorf("combined config rejected by real caddy:\n%v", err)
		}
	})
}
