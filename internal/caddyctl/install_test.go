package caddyctl

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInstallerRefValidation(t *testing.T) {
	valid := []string{"refactor/go", "main", "v0.1.0", "feature/menu-v2"}
	for _, ref := range valid {
		if !validInstallerRef(ref) {
			t.Errorf("valid installer ref rejected: %q", ref)
		}
	}
	invalid := []string{"", ".", "..", "../main", "main/../other", "/main", "main/", "main//other", "main?x"}
	for _, ref := range invalid {
		if validInstallerRef(ref) {
			t.Errorf("invalid installer ref accepted: %q", ref)
		}
	}
}

func TestSelfInstallCreatesBinaryAndAlias(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	binDir := filepath.Join(t.TempDir(), "bin")
	t.Setenv("CADDYCTL_GO_BIN_DIR", binDir)
	if err := app.selfInstallCommand(nil); err != nil {
		t.Fatal(err)
	}
	installed := filepath.Join(binDir, "caddyctl")
	if info, err := os.Stat(installed); err != nil || info.Mode()&0o111 == 0 {
		t.Fatalf("installed binary is missing or not executable: %v", err)
	}
	target, err := os.Readlink(filepath.Join(binDir, "c"))
	if err != nil || target != installed {
		t.Fatalf("alias target=%q err=%v", target, err)
	}
}
