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
