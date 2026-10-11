package caddyctl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readSiteConf(t *testing.T, app *App, label string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(app.Paths.Sites, label+".conf"))
	if err != nil {
		t.Fatalf("read site conf: %v", err)
	}
	return string(data)
}

func runErr(t *testing.T, app *App, want string, args ...string) {
	t.Helper()
	err := app.Run(args)
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("run %v: want error containing %q, got %v", args, want, err)
	}
}

func TestAddRemoteTargetExactShape(t *testing.T) {
	// 精确锁定模板形状：transport 必须位于 reverse_proxy 块内部，
	// 防止再出现闭合括号位置错误导致 caddy validate 报 unrecognized directive。
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "--target", "https://upstream.example.com", "--stream", "--skip-dns-check")
	data := readSiteConf(t, app, "app.example.com")
	want := `app.example.com {
    encode zstd gzip
    reverse_proxy "https://upstream.example.com" {
        header_up Host upstream.example.com
        flush_interval -1
        transport http {
            tls
            tls_server_name upstream.example.com
            dial_timeout 5s
            response_header_timeout 300s
            keepalive 30s
            keepalive_idle_conns 100
            keepalive_idle_conns_per_host 10
        }
    }
}
`
	if data != want {
		t.Errorf("remote conf shape mismatch:\n--- got ---\n%s\n--- want ---\n%s", data, want)
	}
}

func TestAddRemoteTarget(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "--target", "https://upstream.example.com", "--skip-dns-check")
	data := readSiteConf(t, app, "app.example.com")
	for _, want := range []string{
		`reverse_proxy "https://upstream.example.com"`,
		"header_up Host upstream.example.com",
		"tls_server_name upstream.example.com",
		"response_header_timeout 300s",
	} {
		if !strings.Contains(data, want) {
			t.Errorf("remote conf missing %q:\n%s", want, data)
		}
	}
	if strings.Contains(data, "flush_interval") {
		t.Errorf("remote conf should not stream by default:\n%s", data)
	}
	if got := detectSite(data); got != SiteRemote {
		t.Errorf("detectSite = %q, want %q", got, SiteRemote)
	}
}

func TestAddRemoteTargetStream(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "--target", "upstream.example.com", "--stream", "--skip-dns-check")
	data := readSiteConf(t, app, "app.example.com")
	// 无 scheme 时按站点默认 https:// 补全
	if !strings.Contains(data, `reverse_proxy "https://upstream.example.com"`) {
		t.Errorf("missing default scheme target:\n%s", data)
	}
	if !strings.Contains(data, "flush_interval -1") {
		t.Errorf("missing flush_interval -1:\n%s", data)
	}
}

func TestAddRemoteTargetHTTPUpstream(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "--target", "http://upstream.example.com", "--skip-dns-check")
	data := readSiteConf(t, app, "app.example.com")
	if !strings.Contains(data, "header_up Host upstream.example.com") {
		t.Errorf("missing header_up Host:\n%s", data)
	}
	if strings.Contains(data, "tls_server_name") {
		t.Errorf("http upstream should not set tls_server_name:\n%s", data)
	}
}

func TestAddRemoteRejectsPortWithTarget(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runErr(t, app, "--target 模式不接端口参数", "add", "app.example.com", "3000", "--target", "https://upstream.example.com")
}

func TestAddStaticRejectsStream(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runErr(t, app, "--stream", "add-static", "static.example.com", "/srv/site", "--stream")
}

func TestDetectRemoteKind(t *testing.T) {
	// 手写风格（如 Northflank 反代）：字面量 header_up Host，无占位符
	handWritten := `new.example.com {
    reverse_proxy https://http--svc--abc123.code.run {
        header_up Host http--svc--abc123.code.run
        transport http {
            tls
            tls_server_name http--svc--abc123.code.run
        }
    }
}`
	if got := detectSite(handWritten); got != SiteRemote {
		t.Errorf("hand-written remote detect = %q, want %q", got, SiteRemote)
	}
	// Emby 占位符仍归类为 Emby
	emby := "emby.example.com {\n    reverse_proxy \"https://10.0.0.5:8096\" {\n        header_up Host {upstream_hostport}\n    }\n}"
	if got := detectSite(emby); got != SiteEmby {
		t.Errorf("emby detect = %q, want %q", got, SiteEmby)
	}
	// 本机端口反代不受影响
	proxy := "app.example.com {\n    reverse_proxy 127.0.0.1:3000\n}"
	if got := detectSite(proxy); got != SiteProxy {
		t.Errorf("proxy detect = %q, want %q", got, SiteProxy)
	}
	// 网关注释被 import 丢弃后，仍按内容特征（path_regexp）识别
	gatewayNoComment := "https://auto.example.com {\n    @httpsProxyWithPort path_regexp up_https_port ^/https:/*([A-Za-z0-9.\\-_]+):([0-9]+)(/.*)\n    handle @httpsProxyWithPort {\n        reverse_proxy 127.0.0.1:8998 {\n            flush_interval -1\n        }\n    }\n}"
	if got := detectSite(gatewayNoComment); got != SiteGateway {
		t.Errorf("gateway detect = %q, want %q", got, SiteGateway)
	}
}

func TestSetRemoteTargetAndStream(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "--target", "https://upstream.example.com", "--skip-dns-check")
	runOK(t, app, "set", "app.example.com", "--target", "https://other.example.com", "--stream")
	data := readSiteConf(t, app, "app.example.com")
	for _, want := range []string{
		`reverse_proxy "https://other.example.com"`,
		"header_up Host other.example.com",
		"tls_server_name other.example.com",
		"flush_interval -1",
	} {
		if !strings.Contains(data, want) {
			t.Errorf("set remote missing %q:\n%s", want, data)
		}
	}
	// 关闭流式
	runOK(t, app, "set", "app.example.com", "--no-stream")
	data = readSiteConf(t, app, "app.example.com")
	if strings.Contains(data, "flush_interval") {
		t.Errorf("--no-stream should remove flush_interval:\n%s", data)
	}
}

func TestSetRemoteRejectsPort(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "--target", "https://upstream.example.com", "--skip-dns-check")
	runErr(t, app, "远程反代仅支持", "set", "app.example.com", "--port", "4000")
}

func TestAddProxyStream(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "3000", "--stream", "--skip-dns-check")
	data := readSiteConf(t, app, "app.example.com")
	if !strings.Contains(data, "flush_interval -1") {
		t.Errorf("missing flush_interval -1:\n%s", data)
	}
	runOK(t, app, "set", "app.example.com", "--no-stream")
	data = readSiteConf(t, app, "app.example.com")
	if strings.Contains(data, "flush_interval") {
		t.Errorf("--no-stream should remove flush_interval:\n%s", data)
	}
}

func TestSetEmbyWithoutTargetPreservesQuotedTarget(t *testing.T) {
	// 回归：optionsFromSite 需反转义 quoteCaddy 包裹的目标值，
	// 否则不带 --target 的 set-emby 会把带引号的值原样写回配置。
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add-emby", "emby.example.com", "https://10.0.0.5:8096", "--skip-dns-check")
	runOK(t, app, "set-emby", "emby.example.com", "--https")
	data := readSiteConf(t, app, "emby.example.com")
	if !strings.Contains(data, `reverse_proxy "https://10.0.0.5:8096"`) {
		t.Errorf("emby target lost after set without --target:\n%s", data)
	}
	if strings.Contains(data, `\"`) {
		t.Errorf("double-escaped quotes leaked:\n%s", data)
	}
}

func TestCommandHelpFlag(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	runOK(t, app, "add", "-h")
	if !strings.Contains(out.String(), "用法: c add") {
		t.Errorf("add -h output missing usage:\n%s", out.String())
	}
	runOK(t, app, "set", "--help")
	if !strings.Contains(out.String(), "用法: c set") {
		t.Errorf("set --help output missing usage:\n%s", out.String())
	}
	// 用法表覆盖所有已知命令；未知命令无条目（由调用方回退主帮助）
	runOK(t, app, "emby-list", "-h")
	if !strings.Contains(out.String(), "用法: c list-emby") {
		t.Errorf("emby-list -h output missing usage:\n%s", out.String())
	}
	if _, ok := commandUsage("no-such-command"); ok {
		t.Error("unknown command should not have a usage entry")
	}
}

func TestValidateReportsDrift(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "3000", "--skip-dns-check")
	runOK(t, app, "apply")
	// 手工改动 live Caddyfile 制造漂移（append 不在 sites.d 注册表中的内容）
	live, err := os.ReadFile(app.Paths.Caddyfile)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(app.Paths.Caddyfile, append(live, []byte("\n# manual drift\n")...), 0o644); err != nil {
		t.Fatal(err)
	}
	runOK(t, app, "validate")
	if !strings.Contains(out.String(), "不一致") {
		t.Errorf("validate should report drift:\n%s", out.String())
	}
}
