package caddyctl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSkillCommandPrintsEmbeddedDoc(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	runOK(t, app, "skill")
	if !strings.Contains(out.String(), "# caddyctl") {
		t.Errorf("skill output missing doc header:\n%.200s", out.String())
	}
}

func TestSkillInstallWritesToConfigDir(t *testing.T) {
	app, out, _ := newTestApp(t, "")
	runOK(t, app, "skill", "install")
	want := filepath.Join(filepath.Dir(app.Paths.Caddyfile), "skill", "SKILL.md")
	if !strings.Contains(out.String(), want) {
		t.Errorf("install output missing path %s:\n%s", want, out.String())
	}
	data, err := os.ReadFile(want)
	if err != nil || !strings.Contains(string(data), "# caddyctl") {
		t.Fatalf("skill doc not installed: err=%v data=%.100s", err, data)
	}
	// 幂等：重复安装成功且内容不变
	runOK(t, app, "skill", "install")
	again, _ := os.ReadFile(want)
	if string(data) != string(again) {
		t.Error("skill install is not idempotent")
	}
}

func TestSkillCommandRejectsUnknownArgs(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	runErr(t, app, "用法: c skill [install]", "skill", "bogus")
}

func TestSkillReadOnlyBoundary(t *testing.T) {
	if !skillReadOnly("skill", nil) {
		t.Error("bare skill should be read-only")
	}
	if skillReadOnly("skill", []string{"install"}) {
		t.Error("skill install should not be read-only")
	}
	if skillReadOnly("list", nil) {
		t.Error("list should not be handled by skillReadOnly")
	}
}
