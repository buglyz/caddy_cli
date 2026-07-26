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
