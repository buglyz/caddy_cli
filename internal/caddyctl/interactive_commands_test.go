package caddyctl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDirectSetCommandsPromptForMissingChanges(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "proxy.example.com", "3000", "--skip-dns-check")
	runOK(t, app, "add-static", "static.example.com", "/srv/site", "--spa", "--skip-dns-check")
	runOK(t, app, "add-emby", "emby.example.com", "https://10.0.0.5:8096", "--skip-dns-check")
	runOK(t, app, "add-gateway", "gate.example.com", "--allow", "emby.example.com:443", "--skip-dns-check")

	tests := []struct {
		args  []string
		input string
		path  string
		want  string
	}{
		{[]string{"set", "proxy.example.com"}, "4100\n\n0\n", "proxy.example.com.conf", "127.0.0.1:4100"},
		{[]string{"set-static", "static.example.com"}, "/srv/new\n2\n0\n", "static.example.com.conf", `root * "/srv/new"`},
		{[]string{"set-emby", "emby.example.com"}, "https://10.0.0.6:8096\n0\n", "emby.example.com.conf", "10.0.0.6:8096"},
		{[]string{"set-gateway", "gate.example.com"}, "10.0.0.7:8096\n0\n", "gate.example.com.conf", "仅允许: 10.0.0.7:8096"},
	}
	for _, test := range tests {
		app.In = strings.NewReader(test.input)
		runOK(t, app, test.args...)
		data, err := os.ReadFile(filepath.Join(app.Paths.Sites, test.path))
		if err != nil || !strings.Contains(string(data), test.want) {
			t.Errorf("run %v missing %q: %s err=%v", test.args, test.want, data, err)
		}
	}
}

func TestSetFlagsWithoutQueryPromptForSite(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "proxy.example.com", "3000", "--skip-dns-check")
	app.In = strings.NewReader("proxy.example.com\n")
	runOK(t, app, "set", "--port", "4200")
	data, err := os.ReadFile(filepath.Join(app.Paths.Sites, "proxy.example.com.conf"))
	if err != nil || !strings.Contains(string(data), "127.0.0.1:4200") {
		t.Fatalf("flag-only interactive set failed: %s err=%v", data, err)
	}
}

func TestMissingSiteArgumentsPromptAndEmbyRemovalChecksType(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "proxy.example.com", "3000", "--skip-dns-check")
	runOK(t, app, "add-emby", "emby.example.com", "https://10.0.0.5:8096", "--skip-dns-check")

	if err := app.Run([]string{"rm-emby", "proxy.example.com"}); err == nil {
		t.Fatal("rm-emby removed a non-Emby site")
	}
	app.In = strings.NewReader("proxy.example.com\n")
	runOK(t, app, "disable")
	app.In = strings.NewReader("proxy.example.com\n")
	runOK(t, app, "enable")
	app.In = strings.NewReader("emby.example.com\n")
	runOK(t, app, "rm-emby")
	if _, err := os.Stat(filepath.Join(app.Paths.Sites, "emby.example.com.conf")); !os.IsNotExist(err) {
		t.Fatalf("interactive rm-emby did not remove site: %v", err)
	}
	app.In = strings.NewReader("bad-domain\n")
	if err := app.Run([]string{"cert-check"}); err == nil {
		t.Fatal("interactive cert-check accepted invalid domain")
	}
}

func TestListIncludesGlobalsDisabledSitesAndCloudflareState(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	app.Cloudflare = true
	runOK(t, app, "add", "proxy.example.com", "3000", "--skip-dns-check")
	runOK(t, app, "disable", "proxy.example.com")
	if err := os.WriteFile(filepath.Join(app.Paths.Globals, "10-test.inc"), []byte("debug\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(app.Paths.CloudflareEnv, []byte("CLOUDFLARE_API_TOKEN=secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runOK(t, app, "list")
	for _, wanted := range []string{"===== 全局片段 =====", "10-test.inc", "===== 已禁用站点 =====", "proxy.example.com.conf.disabled", "===== Cloudflare =====", "状态: 已配置"} {
		if !strings.Contains(out.String(), wanted) {
			t.Errorf("list output missing %q: %s", wanted, out.String())
		}
	}
}
