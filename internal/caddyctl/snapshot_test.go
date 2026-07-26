package caddyctl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLatestSnapshotUsesCreationOrderWithinSameSecond(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.ensureDirs(); err != nil {
		t.Fatal(err)
	}
	first, err := app.createSnapshot("first")
	if err != nil {
		t.Fatal(err)
	}
	second, err := app.createSnapshot("second")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(second) <= filepath.Base(first) {
		t.Fatalf("snapshot IDs are not time-sortable: first=%s second=%s", first, second)
	}
	latest, err := app.snapshotPath("latest")
	if err != nil {
		t.Fatal(err)
	}
	if latest != second {
		t.Fatalf("latest=%s, want %s", latest, second)
	}
}

func TestInvalidSnapshotDoesNotPartiallyRestore(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.ensureDirs(); err != nil {
		t.Fatal(err)
	}
	site := filepath.Join(app.Paths.Sites, "app.example.com.conf")
	if err := os.WriteFile(site, []byte("snapshot content"), 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot, err := app.createSnapshot("test")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(site, []byte("current content"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(snapshot, "state.conf")); err != nil {
		t.Fatal(err)
	}
	if err := app.restoreSnapshot(snapshot); err == nil {
		t.Fatal("snapshot with a missing declared state file was accepted")
	}
	data, err := os.ReadFile(site)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "current content" {
		t.Fatalf("invalid snapshot partially changed sites: %q", data)
	}
}

func TestSnapshotRejectsSymlinkedDeclaredFile(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.ensureDirs(); err != nil {
		t.Fatal(err)
	}
	snapshot, err := app.createSnapshot("test")
	if err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(snapshot, "state.conf")
	if err := os.Remove(state); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(app.Paths.State, state); err != nil {
		t.Fatal(err)
	}
	if err := app.validateSnapshot(snapshot); err == nil || !strings.Contains(err.Error(), "不安全") {
		t.Fatalf("symlinked state file was not rejected: %v", err)
	}
}

func TestLegacySnapshotWithoutManifestIsRestorable(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.ensureDirs(); err != nil {
		t.Fatal(err)
	}
	site := filepath.Join(app.Paths.Sites, "legacy.example.com.conf")
	if err := os.WriteFile(site, []byte("legacy snapshot"), 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot, err := app.createSnapshot("legacy")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(snapshot, "manifest")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(site, []byte("current content"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := app.restoreSnapshot(snapshot); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(site)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "legacy snapshot" {
		t.Fatalf("legacy snapshot content=%q", data)
	}
}

func TestRestorePreparationFailureKeepsCurrentFiles(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.ensureDirs(); err != nil {
		t.Fatal(err)
	}
	site := filepath.Join(app.Paths.Sites, "app.example.com.conf")
	if err := os.WriteFile(site, []byte("snapshot content"), 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot, err := app.createSnapshot("test")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(site, []byte("current content"), 0o644); err != nil {
		t.Fatal(err)
	}
	app.Paths.State = filepath.Join(app.Paths.Root, "missing-parent", "state.conf")
	if err := app.restoreSnapshot(snapshot); err == nil {
		t.Fatal("restore unexpectedly succeeded with an unavailable state staging directory")
	}
	data, err := os.ReadFile(site)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "current content" {
		t.Fatalf("failed restore changed current site: %q", data)
	}
}
