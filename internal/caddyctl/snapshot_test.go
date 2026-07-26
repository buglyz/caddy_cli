package caddyctl

import (
	"path/filepath"
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
