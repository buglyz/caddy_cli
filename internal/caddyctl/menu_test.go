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

func TestMenuDoesNotClearNonTerminalOutput(t *testing.T) {
	t.Setenv("TERM", "xterm-256color")
	app, out, _ := newTestApp(t, "0\n")
	runOK(t, app)
	if strings.Contains(out.String(), "\x1b") {
		t.Fatalf("non-terminal menu output contains ANSI controls: %q", out.String())
	}
}

func TestInteractiveTerminalRejectsUnsupportedOutput(t *testing.T) {
	for _, term := range []string{"", "dumb", "DUMB"} {
		t.Run(term, func(t *testing.T) {
			t.Setenv("TERM", term)
			if interactiveTerminal(os.Stdin, os.Stdout) {
				t.Fatalf("TERM=%q was treated as an interactive terminal", term)
			}
		})
	}
}

func TestMenuClearsEveryLevelOnInteractiveTerminal(t *testing.T) {
	input := strings.Join([]string{
		"4", "4", "0", "0",
		"5", "4", "0", "0",
		"6", "7", "0", "12", "0", "0",
		"7", "0",
		"8", "0",
		"0",
	}, "\n") + "\n"
	app, out, _ := newTestApp(t, input)
	app.Cloudflare = true
	app.interactive = true
	runOK(t, app)

	for _, title := range []string{
		"Caddy CLI 管理面板",
		"站点管理",
		"修改普通站点",
		"Emby 专用管理",
		"修改 Emby / 网关",
		"服务与配置",
		"配置设置",
		"Cloudflare DNS 管理",
		"诊断与维护",
		"安装与更新",
	} {
		wanted := clearScreenSequence + "\n====== " + title
		if !strings.Contains(out.String(), wanted) {
			t.Errorf("menu %q was not cleared before rendering", title)
		}
	}
	for _, section := range []string{
		"【查看】", "【添加站点】", "【管理站点】", "【添加】", "【管理】",
		"【服务控制】", "【配置管理】", "【高级操作】", "【诊断工具】",
		"【备份回滚】", "【状态】", "【凭据】",
	} {
		if !strings.Contains(out.String(), section) {
			t.Errorf("layered menus missing section %q", section)
		}
	}
}

func TestMainMenuSectionsAndNumbering(t *testing.T) {
	app, out, _ := newTestApp(t, "0\n")
	runOK(t, app)
	menu := out.String()
	items := []string{
		"【快速操作】",
		"1. 查看所有站点状态",
		"2. 重启 Caddy 服务",
		"3. 查看最近日志",
		"【站点管理】",
		"4. 站点管理",
		"5. Emby 专用管理",
		"【系统管理】",
		"6. 服务与配置",
		"7. 诊断与维护",
		"8. 安装与更新",
		"0. 退出",
	}
	previous := -1
	for _, item := range items {
		index := strings.Index(menu, item)
		if index < 0 {
			t.Errorf("main menu missing %q", item)
		} else if index <= previous {
			t.Errorf("main menu item %q is out of order", item)
		}
		previous = index
	}
}

func TestMainMenuQuickActionsKeepCommandMappings(t *testing.T) {
	app, out, errOut := newTestApp(t, "")
	runOK(t, app, "add", "quick.example.com", "3000", "--skip-dns-check")
	out.Reset()
	app.In = strings.NewReader("1\n\n0\n")
	runOK(t, app)
	if !strings.Contains(out.String(), "quick.example.com") {
		t.Fatalf("quick site list did not run: %s", out.String())
	}

	out.Reset()
	errOut.Reset()
	if os.Geteuid() == 0 {
		managerDir := t.TempDir()
		recordPath := filepath.Join(managerDir, "service-action")
		manager := "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$CADDYCTL_TEST_SERVICE_ACTION\"\n"
		if err := os.WriteFile(filepath.Join(managerDir, "systemctl"), []byte(manager), 0o755); err != nil {
			t.Fatal(err)
		}
		t.Setenv("PATH", managerDir)
		t.Setenv("CADDYCTL_TEST_SERVICE_ACTION", recordPath)
		isolatedRoot := app.Paths.Root
		app.Paths.Root = ""
		app.In = strings.NewReader("2\n\n0\n")
		runOK(t, app)
		app.Paths.Root = isolatedRoot
		action, err := os.ReadFile(recordPath)
		if err != nil || strings.TrimSpace(string(action)) != "restart caddy" {
			t.Fatalf("quick restart action=%q err=%v stderr=%s", action, err, errOut.String())
		}
	} else {
		app.In = strings.NewReader("2\n\n0\n")
		runOK(t, app)
		if !strings.Contains(errOut.String(), "隔离模式不执行 Caddy 服务操作") {
			t.Fatalf("quick service action did not run: %s", errOut.String())
		}
	}

	logPath := filepath.Join(app.Paths.Root, "var/log/caddy/caddy.log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logPath, []byte("quick-log-entry\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	app.In = strings.NewReader("3\n\n0\n")
	runOK(t, app)
	if !strings.Contains(out.String(), "quick-log-entry") {
		t.Fatalf("quick logs did not run: %s", out.String())
	}
}

func TestRegularCommandDoesNotClearInteractiveTerminal(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	app.interactive = true
	runOK(t, app, "version")
	if strings.Contains(out.String(), "\x1b") {
		t.Fatalf("regular command output contains ANSI controls: %q", out.String())
	}
}

func TestInteractiveMenuAddsPathProxy(t *testing.T) {
	input := strings.Join([]string{
		"4", // main: sites
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
		"4", "3", "static.example.com", "/srv/site", "y", "2", "y", "", "0", "0",
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
		"5", "2", "emby.example.com", "https://10.0.0.5:8096", "", "y", "",
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
		"4", "4", "1", "app.example.com", "4000", "", "0", "", "0",
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
