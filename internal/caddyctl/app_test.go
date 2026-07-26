package caddyctl

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestApp(t *testing.T, input string) (*App, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	fake := filepath.Join(root, "fake-caddy")
	script := `#!/bin/sh
config=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--config" ]; then
        shift
        config="$1"
    fi
    shift
done
if [ -n "$config" ] && grep -q INVALID "$config"; then
    echo "invalid test config" >&2
    exit 1
fi
exit 0
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CADDYCTL_ROOT", root)
	t.Setenv("CADDYCTL_SKIP_DNS_CHECK", "1")
	t.Setenv("CADDYCTL_NO_RELOAD", "1")
	t.Setenv("CADDY_BIN", fake)
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	app, err := New(strings.NewReader(input), out, errOut)
	if err != nil {
		t.Fatal(err)
	}
	return app, out, errOut
}

func runOK(t *testing.T, app *App, args ...string) {
	t.Helper()
	if err := app.Run(args); err != nil {
		t.Fatalf("run %v: %v", args, err)
	}
}

func TestAppSiteLifecycleAndUndo(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "3000", "--skip-dns-check")
	runOK(t, app, "add-static", "static.example.com", "/srv/site", "--spa", "--skip-dns-check")
	runOK(t, app, "add-emby", "emby.example.com", "https://10.0.0.5:8096", "--skip-dns-check")
	runOK(t, app, "add-gateway", "gate.example.com", "--allow", "emby.example.com:443", "--skip-dns-check")
	runOK(t, app, "set", "app.example.com", "--port", "4000")
	runOK(t, app, "disable", "app.example.com")
	runOK(t, app, "enable", "app.example.com")
	runOK(t, app, "validate")

	proxyPath := filepath.Join(app.Paths.Sites, "app.example.com.conf")
	data, err := os.ReadFile(proxyPath)
	if err != nil || !strings.Contains(string(data), "127.0.0.1:4000") {
		t.Fatalf("updated proxy missing: %s err=%v", data, err)
	}
	staticPath := filepath.Join(app.Paths.Sites, "static.example.com.conf")
	runOK(t, app, "rm", "static.example.com")
	if _, err := os.Stat(staticPath); !os.IsNotExist(err) {
		t.Fatalf("static site should be removed: %v", err)
	}
	runOK(t, app, "undo", "latest")
	if _, err := os.Stat(staticPath); err != nil {
		t.Fatalf("undo did not restore static site: %v", err)
	}
}

func TestSetPreservesCustomBlocks(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "app.example.com", "3000", "--skip-dns-check")
	path := filepath.Join(app.Paths.Sites, "app.example.com.conf")
	custom := `app.example.com {
    encode zstd gzip
    header {
        X-Test yes
    }
    basic_auth {
        user hash
    }
    reverse_proxy 127.0.0.1:3000
}
`
	if err := os.WriteFile(path, []byte(custom), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := app.apply(); err != nil {
		t.Fatal(err)
	}
	runOK(t, app, "set", "app.example.com", "--port", "4000")
	data, _ := os.ReadFile(path)
	for _, value := range []string{"X-Test yes", "user hash", "127.0.0.1:4000"} {
		if !strings.Contains(string(data), value) {
			t.Errorf("set lost %q:\n%s", value, data)
		}
	}
}

func TestFailedImportRestoresManagedDirectories(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add", "keep.example.com", "3000", "--skip-dns-check")
	source := filepath.Join(app.Paths.Root, "bad.Caddyfile")
	if err := os.WriteFile(source, []byte("bad.example.com {\n    INVALID\n}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := app.Run([]string{"import", "--force", source}); err == nil {
		t.Fatal("invalid import unexpectedly succeeded")
	}
	keep := filepath.Join(app.Paths.Sites, "keep.example.com.conf")
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("failed import did not restore original site: %v", err)
	}
}

func TestCloudflareTokenSetUsesStdinAndMode0600(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer secret-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		fmt.Fprint(w, `{"success":true,"result":{"status":"active"}}`)
	}))
	defer server.Close()
	app, _, _ := newTestApp(t, "secret-token\n")
	app.Cloudflare = true
	t.Setenv("CADDYCTL_CLOUDFLARE_VERIFY_URL", server.URL)
	runOK(t, app, "cloudflare", "set")
	info, err := os.Stat(app.Paths.CloudflareEnv)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("token mode=%o, want 600", info.Mode().Perm())
	}
	data, _ := os.ReadFile(app.Paths.CloudflareEnv)
	if !strings.Contains(string(data), "secret-token") {
		t.Fatal("token was not persisted")
	}
}

func TestDoctorAndCertCheckValidation(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	runOK(t, app, "doctor")
	if !strings.Contains(out.String(), "===== 环境检查 =====") {
		t.Fatal("doctor output missing environment header")
	}
	if err := app.Run([]string{"cert-check", "bad-domain"}); err == nil {
		t.Fatal("cert-check accepted an invalid domain")
	}
}

func TestEmptyCommandShowsGoHelp(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	runOK(t, app)
	if !strings.Contains(out.String(), "c add <域名> <端口>") {
		t.Fatal("empty command did not show Go help")
	}
}

func TestCommandClassification(t *testing.T) {
	for _, command := range []string{"version", "--version"} {
		if !readOnlyCommand(command, nil) {
			t.Errorf("%s should be read-only", command)
		}
	}
	for _, command := range []string{"timeout", "upstream-mode"} {
		if !readOnlyCommand(command, nil) || readOnlyCommand(command, []string{"value"}) {
			t.Errorf("%s query/update classification is wrong", command)
		}
	}
	if knownCommand("definitely-unknown") {
		t.Fatal("unknown command was classified as known")
	}
}

func TestReadOnlyStateQueriesDoNotCreateSnapshots(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	runOK(t, app, "timeout")
	runOK(t, app, "upstream-mode")
	if !strings.Contains(out.String(), "当前服务超时") || !strings.Contains(out.String(), "当前上游健康检查模式") {
		t.Fatalf("query output is incomplete: %s", out.String())
	}
	if _, err := os.Stat(app.Paths.Snapshots); !os.IsNotExist(err) {
		t.Fatalf("read-only queries created snapshot storage: %v", err)
	}
}

func TestEmailWithoutArgumentReadsStdin(t *testing.T) {
	app, out, _ := newTestApp(t, "admin@example.org\n")
	runOK(t, app, "email")
	if app.State.Email != "admin@example.org" {
		t.Fatalf("email=%q", app.State.Email)
	}
	if !strings.Contains(out.String(), "请输入邮箱") {
		t.Fatalf("interactive prompt missing: %s", out.String())
	}
}

func TestEmailWithoutArgumentRejectsMissingInput(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.Run([]string{"email"}); err == nil {
		t.Fatal("email command cleared state without reading input")
	}
}

func TestAddRejectsIgnoredArgumentsAndUnsupportedDNS(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	tests := [][]string{
		{"add", "app.example.com", "3000", "extra", "--skip-dns-check"},
		{"add", "app.example.com", "3000", "--spa", "--skip-dns-check"},
		{"add-static", "static.example.com", "/srv/site", "--path", "/api", "--skip-dns-check"},
		{"add-emby", "emby.example.com", "localhost:8096", "--spa", "--skip-dns-check"},
		{"add-gateway", "gate.example.com", "--allow", "example.com:443", "--spa", "--skip-dns-check"},
		{"add", "dns.example.com", "3000", "--dns-only", "--skip-dns-check"},
	}
	for _, args := range tests {
		if err := app.Run(args); err == nil {
			t.Errorf("run %v unexpectedly succeeded", args)
		}
	}
}

func TestDNSOnlyCannotBeCombinedWithHTTP(t *testing.T) {
	if _, err := parseAddFlags([]string{"app.example.com", "3000", "--dns-only", "--http"}, "add"); err == nil {
		t.Fatal("add flags accepted --dns-only with --http")
	}
	if _, err := parseSetFlags([]string{"app.example.com", "--dns-only", "--http"}, "set"); err == nil {
		t.Fatal("set flags accepted --dns-only with --http")
	}
}

func TestSetRejectsNoOpAndWrongSiteOptions(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runOK(t, app, "add-static", "static.example.com", "/srv/site", "--skip-dns-check")
	for _, args := range [][]string{
		{"set-static", "static.example.com"},
		{"set-static", "static.example.com", "--port", "4000"},
		{"set-static", "static.example.com", "--root", "/srv/site\nrespond hacked"},
		{"set-static", "static.example.com", "--dns-only"},
	} {
		if err := app.Run(args); err == nil {
			t.Errorf("run %v unexpectedly succeeded", args)
		}
	}
	runOK(t, app, "add", "app.example.com", "3000", "--skip-dns-check")
	if err := app.Run([]string{"set", "app.example.com", "--target", "https://example.org"}); err == nil {
		t.Fatal("proxy set accepted an ignored --target option")
	}
}
