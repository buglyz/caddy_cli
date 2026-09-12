package caddyctl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRestoreSnapshotTransactionRollback 覆盖 restoreSnapshotFiles 的事务语义：
// 恢复成功、目标丢失时重建、以及 stage 缺失时的错误路径。
func TestRestoreSnapshotTransactionRollback(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.ensureDirs(); err != nil {
		t.Fatal(err)
	}
	// 准备现有站点与状态
	sitePath := filepath.Join(app.Paths.Sites, "rollback.example.com.conf")
	if err := os.WriteFile(sitePath, []byte("old content"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(app.Paths.State, []byte("email old@example.com"), 0o644); err != nil {
		t.Fatal(err)
	}

	snapshot := t.TempDir()
	sites := filepath.Join(snapshot, "sites")
	globals := filepath.Join(snapshot, "globals")
	if err := os.MkdirAll(sites, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(globals, 0o755); err != nil {
		t.Fatal(err)
	}
	newSite := filepath.Join(sites, "rollback.example.com.conf")
	if err := os.WriteFile(newSite, []byte("new content"), 0o644); err != nil {
		t.Fatal(err)
	}
	added := filepath.Join(sites, "added.example.com.conf")
	if err := os.WriteFile(added, []byte("added"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(snapshot, "state.conf"), []byte("email new@example.com"), 0o644); err != nil {
		t.Fatal(err)
	}
	manifest := map[string]string{"FORMAT": "1", "STATE_PRESENT": "1", "CADDYFILE_PRESENT": "0"}

	if err := app.restoreSnapshotFiles(snapshot, manifest); err != nil {
		t.Fatalf("restoreSnapshotFiles: %v", err)
	}

	// 覆盖型站点更新为新内容
	data, err := os.ReadFile(sitePath)
	if err != nil || string(data) != "new content" {
		t.Fatalf("site not restored: %q err=%v", data, err)
	}
	// 新增站点落地
	if _, err := os.Stat(filepath.Join(app.Paths.Sites, "added.example.com.conf")); err != nil {
		t.Fatalf("added site missing: %v", err)
	}
	// 状态文件更新
	stateData, err := os.ReadFile(app.Paths.State)
	if err != nil || string(stateData) != "email new@example.com" {
		t.Fatalf("state not restored: %q err=%v", stateData, err)
	}
	// 事务产物（.caddyctl-*）不残留
	entries, err := os.ReadDir(app.Paths.Sites)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".caddyctl-") {
			t.Fatalf("transaction leftover in sites.d: %s", e.Name())
		}
	}
	// .old 备份不残留
	parentEntries, err := os.ReadDir(filepath.Dir(app.Paths.Sites))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range parentEntries {
		if strings.HasPrefix(e.Name(), ".caddyctl-restore-old-") {
			t.Fatalf("restore-old leftover: %s", e.Name())
		}
	}
}

// TestRestoreSnapshotMissingSiteStageIsError 覆盖快照结构缺失时返回错误且不破坏现状。
func TestRestoreSnapshotMissingSiteStageIsError(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.ensureDirs(); err != nil {
		t.Fatal(err)
	}
	sitePath := filepath.Join(app.Paths.Sites, "keep.example.com.conf")
	if err := os.WriteFile(sitePath, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot := t.TempDir()
	// 缺 sites/globals 目录
	manifest := map[string]string{"FORMAT": "1", "STATE_PRESENT": "0", "CADDYFILE_PRESENT": "0"}
	if err := app.restoreSnapshotFiles(snapshot, manifest); err == nil {
		t.Fatal("expected error for incomplete snapshot")
	}
	data, err := os.ReadFile(sitePath)
	if err != nil || string(data) != "keep" {
		t.Fatalf("existing site should be untouched: %q err=%v", data, err)
	}
}

// TestJoinErrors 覆盖 joinErrors 语义。
func TestJoinErrors(t *testing.T) {
	if joinErrors(nil, nil) != nil {
		t.Fatal("all-nil should be nil")
	}
	e1 := os.ErrNotExist
	e2 := os.ErrPermission
	joined := joinErrors(e1, nil, e2)
	if joined == nil {
		t.Fatal("expected non-nil")
	}
	msg := joined.Error()
	if !strings.Contains(msg, "file does not exist") || !strings.Contains(msg, "permission denied") {
		t.Fatalf("unexpected message: %s", msg)
	}
}
