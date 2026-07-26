package caddyctl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEmptyCommandAndMenuOpenInteractivePanel(t *testing.T) {
	for _, args := range [][]string{nil, {"menu"}} {
		app, out, _ := newTestApp(t, "0\n")
		if err := app.Run(args); err != nil {
			t.Fatalf("run %v: %v", args, err)
		}
		if !strings.Contains(out.String(), "Caddy CLI 管理面板") {
			t.Fatalf("run %v did not open menu: %s", args, out.String())
		}
	}
}

func TestInteractiveMenuAddsPathProxy(t *testing.T) {
	input := strings.Join([]string{
		"1", // main: sites
		"2", // add proxy
		"app.example.com",
		"3000",
		"/api",
		"",  // HTTPS default
		"y", // skip DNS check
		"",  // pause
		"0", // sites: back
		"0", // main: exit
	}, "\n") + "\n"
	app, out, _ := newTestApp(t, input)
	runOK(t, app)
	data, err := os.ReadFile(filepath.Join(app.Paths.Sites, "app.example.com.conf"))
	if err != nil {
		t.Fatal(err)
	}
	for _, wanted := range []string{"uri strip_prefix /api", "reverse_proxy 127.0.0.1:3000"} {
		if !strings.Contains(string(data), wanted) {
			t.Errorf("menu-created proxy missing %q:\n%s", wanted, data)
		}
	}
	if !strings.Contains(out.String(), "已添加路径反代") {
		t.Fatalf("success output missing: %s", out.String())
	}
}

func TestInteractiveMenuAddsStaticSite(t *testing.T) {
	input := strings.Join([]string{
		"1", "3", "static.example.com", "/srv/site", "y", "2", "y", "", "0", "0",
	}, "\n") + "\n"
	app, _, _ := newTestApp(t, input)
	runOK(t, app, "menu")
	data, err := os.ReadFile(filepath.Join(app.Paths.Sites, "static.example.com.conf"))
	if err != nil {
		t.Fatal(err)
	}
	for _, wanted := range []string{"http://static.example.com", "try_files {path} /index.html"} {
		if !strings.Contains(string(data), wanted) {
			t.Errorf("menu-created static site missing %q:\n%s", wanted, data)
		}
	}
}

func TestInteractiveMenuAddsEmbyAndRestrictedGateway(t *testing.T) {
	input := strings.Join([]string{
		"2", "2", "emby.example.com", "https://10.0.0.5:8096", "", "y", "",
		"3", "gate.example.com", "emby.example.com:443", "", "y", "",
		"0", "0",
	}, "\n") + "\n"
	app, _, _ := newTestApp(t, input)
	runOK(t, app)
	checks := map[string][]string{
		"emby.example.com.conf": {"reverse_proxy https://10.0.0.5:8096", "header_up Host {upstream_hostport}"},
		"gate.example.com.conf": {"# 上游限制: 仅允许: emby.example.com:443", `respond "upstream is not allowed" 403`},
	}
	for name, wantedValues := range checks {
		data, err := os.ReadFile(filepath.Join(app.Paths.Sites, name))
		if err != nil {
			t.Fatal(err)
		}
		for _, wanted := range wantedValues {
			if !strings.Contains(string(data), wanted) {
				t.Errorf("%s missing %q:\n%s", name, wanted, data)
			}
		}
	}
}

func TestInteractiveMenuCanModifyDisableAndCancelRemoval(t *testing.T) {
	input := strings.Join([]string{
		"1", "4", "1", "app.example.com", "4000", "", "0", "", "0",
		"5", "app.example.com", "2", "",
		"6", "app.example.com", "n", "",
		"0", "0",
	}, "\n") + "\n"
	app, out, _ := newTestApp(t, input)
	runOK(t, app, "add", "app.example.com", "3000", "--skip-dns-check")
	app.In = strings.NewReader(input)
	runOK(t, app)
	disabled := filepath.Join(app.Paths.Sites, "app.example.com.conf.disabled")
	data, err := os.ReadFile(disabled)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "127.0.0.1:4000") {
		t.Fatalf("interactive modification was not retained: %s", data)
	}
	if !strings.Contains(out.String(), "已取消删除") {
		t.Fatalf("removal cancellation was not reported: %s", out.String())
	}
}

func TestInteractiveMenuRetriesInvalidChoiceAndExitsOnEOF(t *testing.T) {
	app, _, errOut := newTestApp(t, "invalid\n\n")
	runOK(t, app)
	if !strings.Contains(errOut.String(), "无效输入") {
		t.Fatalf("invalid choice was not reported: %s", errOut.String())
	}

	app, out, _ := newTestApp(t, "")
	runOK(t, app)
	if !strings.Contains(out.String(), "Caddy CLI 管理面板") {
		t.Fatal("EOF did not exit cleanly after rendering menu")
	}
}

func TestAddCommandWithoutArgumentsPromptsInteractively(t *testing.T) {
	input := strings.Join([]string{"direct.example.com", "3200", "", "", "y"}, "\n") + "\n"
	app, _, _ := newTestApp(t, input)
	runOK(t, app, "add")
	data, err := os.ReadFile(filepath.Join(app.Paths.Sites, "direct.example.com.conf"))
	if err != nil || !strings.Contains(string(data), "127.0.0.1:3200") {
		t.Fatalf("interactive add command failed: %s err=%v", data, err)
	}
}
