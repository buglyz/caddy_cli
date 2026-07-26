package caddyctl

import "testing"

func TestValidationCompatibility(t *testing.T) {
	tests := []struct {
		name string
		got  bool
		want bool
	}{
		{"domain", validDomain("example.com"), true},
		{"double dot", validDomain("example..com"), false},
		{"leading hyphen", validDomain("-bad.example.com"), false},
		{"multi label", validSiteLabel("a.example.com,www.example.com"), true},
		{"site injection", validSiteLabel("a.example.com; respond hacked"), false},
		{"port lower", validPort("0"), false},
		{"port upper", validPort("65535"), true},
		{"path", validPathPrefix("/api"), true},
		{"path injection", validPathPrefix("/api { respond hacked }"), false},
		{"email", validEmail("admin@example.org"), true},
		{"email dots", validEmail("a..b@example.org"), false},
		{"proxy", validProxyTarget("https://10.0.0.5:8096"), true},
		{"proxy missing host", validProxyTarget("https://"), false},
		{"proxy path", validProxyTarget("https://example.com/path"), false},
		{"proxy slash", validProxyTarget("https://example.com/"), false},
		{"proxy query", validProxyTarget("https://example.com?x=1"), false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if test.got != test.want {
				t.Fatalf("got %v, want %v", test.got, test.want)
			}
		})
	}
}

func TestGatewayAllow(t *testing.T) {
	items, err := parseGatewayAllow("emby.example.com:443,10.0.0.5:8096")
	if err != nil || len(items) != 2 {
		t.Fatalf("parse allow: items=%v err=%v", items, err)
	}
	if _, err := parseGatewayAllow("example.com"); err == nil {
		t.Fatal("expected missing-port allow entry to fail")
	}
}
