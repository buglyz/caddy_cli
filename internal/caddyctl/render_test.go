package caddyctl

import (
	"strings"
	"testing"
)

func TestRenderSiteTemplates(t *testing.T) {
	tests := []struct {
		name  string
		kind  SiteKind
		opts  SiteOptions
		has   []string
		lacks []string
	}{
		{"proxy https", SiteProxy, SiteOptions{Label: "app.example.com", Port: "3000", Scheme: "https"}, []string{"app.example.com {", "reverse_proxy 127.0.0.1:3000"}, nil},
		{"proxy http labels", SiteProxy, SiteOptions{Label: "app.example.com,api.example.com", Port: "3000", Scheme: "http"}, []string{"http://app.example.com, http://api.example.com {", "reverse_proxy http://127.0.0.1:3000"}, []string{"tls {"}},
		{"path", SitePath, SiteOptions{Label: "app.example.com", Port: "3000", Scheme: "https", Path: "/api"}, []string{"uri strip_prefix /api", "respond \"Not Found\" 404"}, nil},
		{"static", SiteStatic, SiteOptions{Label: "static.example.com", Root: "/srv/site with spaces", Scheme: "https", SPA: true}, []string{`root * "/srv/site with spaces"`, "try_files {path} /index.html"}, nil},
		{"emby", SiteEmby, SiteOptions{Label: "emby.example.com", Target: "https://10.0.0.5:8096", Scheme: "https"}, []string{"reverse_proxy https://10.0.0.5:8096", "header_up Host {upstream_hostport}"}, []string{"encode zstd gzip"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := renderSite(test.opts, test.kind)
			if err != nil {
				t.Fatal(err)
			}
			for _, value := range test.has {
				if !strings.Contains(got, value) {
					t.Errorf("missing %q in:\n%s", value, got)
				}
			}
			for _, value := range test.lacks {
				if strings.Contains(got, value) {
					t.Errorf("unexpected %q in:\n%s", value, got)
				}
			}
		})
	}
}

func TestRenderGatewayAllowList(t *testing.T) {
	got, err := renderSite(SiteOptions{
		Label: "gate.example.com", Scheme: "https",
		Allow: []string{"emby.example.com:443"},
	}, SiteGateway)
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{
		"https://gate.example.com {",
		`respond "OK\n\n通用反代网关`,
		"header_up X-Real-IP {remote_host}",
		"header_up Host emby.example.com",
		"header_down Location ^https://([^/]+)(/.*)$ https://gate.example.com/https://$1$2",
		"path_regexp up_https_default_port_0 ^/https:/*emby\\.example\\.com(/.*)",
		"respond \"upstream is not allowed\" 403",
	} {
		if !strings.Contains(got, value) {
			t.Errorf("missing %q in gateway", value)
		}
	}
	if strings.Contains(got, "<<INFO") {
		t.Fatal("gateway uses heredoc unsupported by older Caddy releases")
	}
}

func TestCustomDirectivesPreservedAsBlocks(t *testing.T) {
	source := `app.example.com {
    encode zstd gzip
    header {
        X-Test yes
    }
    basic_auth {
        user hash
    }
    reverse_proxy 127.0.0.1:3000
}`
	extras := extractCustomDirectives(source)
	if !strings.Contains(extras, "X-Test yes") || !strings.Contains(extras, "user hash") {
		t.Fatalf("multi-line extras lost: %s", extras)
	}
	filtered := whitelistCustomDirectives(extras)
	if !strings.Contains(filtered, "X-Test yes") || !strings.Contains(filtered, "user hash") {
		t.Fatalf("whitelist lost block body: %s", filtered)
	}
}

func TestInjectCustomDirectivesAtSiteRoot(t *testing.T) {
	block, err := renderSite(SiteOptions{Label: "app.example.com", Port: "3000", Path: "/api", Scheme: "https"}, SitePath)
	if err != nil {
		t.Fatal(err)
	}
	got := injectCustomDirectives(block, "    header X-Test yes")
	if !strings.Contains(got, "    }\n    header X-Test yes\n}") {
		t.Fatalf("custom directive was not injected at site root:\n%s", got)
	}
}

func TestSiteSchemeUsesHeaderAfterComments(t *testing.T) {
	data := "# generated\n\nhttp://gate.example.com {\n    respond ok\n}\n"
	if got := siteScheme(data); got != "http" {
		t.Fatalf("siteScheme=%q, want http", got)
	}
}

func TestCustomDirectivesExtractionWithoutIndentation(t *testing.T) {
	// 无缩进的 Caddyfile:提取不应依赖缩进层级。
	source := `app.example.com {
encode zstd gzip
header {
X-Test yes
}
reverse_proxy 127.0.0.1:3000
}`
	extras := extractCustomDirectives(source)
	if !strings.Contains(extras, "X-Test yes") {
		t.Fatalf("no-indent block body lost: %s", extras)
	}
	if strings.Contains(extras, "reverse_proxy") || strings.Contains(extras, "encode") {
		t.Fatalf("template directives leaked into extras: %s", extras)
	}
}

func TestCustomDirectivesSkipsQuotedBraces(t *testing.T) {
	source := "app.example.com {\n    respond \"literal { brace\" 200\n    header {\n        X-Test yes\n    }\n}\n"
	extras := extractCustomDirectives(source)
	if strings.Contains(extras, "respond") {
		t.Fatalf("respond should be template, got extras: %s", extras)
	}
	if !strings.Contains(extras, "X-Test yes") {
		t.Fatalf("header block body lost: %s", extras)
	}
}

func TestCustomDirectivesPreservesOnlySiteLevel(t *testing.T) {
	source := `app.example.com {
    encode zstd gzip
    handle /api {
        reverse_proxy 127.0.0.1:3000
    }
    header {
        X-Test yes
    }
}`
	extras := extractCustomDirectives(source)
	if !strings.Contains(extras, "X-Test yes") {
		t.Fatalf("header body lost: %s", extras)
	}
	if strings.Contains(extras, "reverse_proxy") || strings.Contains(extras, "handle /api") {
		t.Fatalf("nested template directives should not be extracted: %s", extras)
	}
}

func TestCustomDirectivesMultipleBlocksAndTemplates(t *testing.T) {
	// 多个自定义块 + 模板指令交错,验证深度追踪不串块。
	source := `app.example.com {
    encode zstd gzip
    header {
        X-One yes
    }
    reverse_proxy 127.0.0.1:3000
    log {
        output file /var/log/app.log
    }
    basic_auth {
        user hash
    }
}`
	extras := extractCustomDirectives(source)
	for _, want := range []string{"X-One yes", "output file /var/log/app.log", "user hash"} {
		if !strings.Contains(extras, want) {
			t.Fatalf("missing %q in extras:\n%s", want, extras)
		}
	}
	for _, bad := range []string{"encode zstd", "reverse_proxy"} {
		if strings.Contains(extras, bad) {
			t.Fatalf("template directive leaked: %q\n%s", bad, extras)
		}
	}
}

func TestCustomDirectivesOneLineAndSameLineBrace(t *testing.T) {
	// header 与 { 同行、块内仅一行,以及无嵌套单行指令。
	cases := []struct{ source, want string }{
		{"app.example.com {\n    header X-Test yes\n}\n", "header X-Test yes"},
		{"app.example.com {\n    header { X-Test yes }\n}\n", "X-Test yes"},
		{"app.example.com {\n    basic_auth user hash\n}\n", "basic_auth user hash"},
	}
	for _, tc := range cases {
		if got := extractCustomDirectives(tc.source); !strings.Contains(got, tc.want) {
			t.Errorf("source %q: missing %q in extras: %q", tc.source, tc.want, got)
		}
	}
}

func TestWhitelistWorksWithNewExtraction(t *testing.T) {
	// Emby/Gateway 场景:extract 后经 whitelist 过滤,只保留 header/basic_auth/log。
	source := `emby.example.com {
    reverse_proxy https://10.0.0.5:8096 {
        header_up Host {upstream_hostport}
    }
    header {
        X-Frame-Options DENY
    }
    log {
        output file /var/log/emby.log
    }
    respond "unused" 403
}`
	extras := extractCustomDirectives(source)
	filtered := whitelistCustomDirectives(extras)
	for _, want := range []string{"X-Frame-Options DENY", "output file /var/log/emby.log"} {
		if !strings.Contains(filtered, want) {
			t.Fatalf("whitelist lost %q:\n%s", want, filtered)
		}
	}
	if strings.Contains(filtered, "unused") || strings.Contains(filtered, "reverse_proxy") {
		t.Fatalf("whitelist kept non-whitelisted directive:\n%s", filtered)
	}
}
