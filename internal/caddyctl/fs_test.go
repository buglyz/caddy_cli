package caddyctl

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCopyFileReplacesDestinationSymlink(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source")
	victim := filepath.Join(dir, "victim")
	destination := filepath.Join(dir, "destination")
	if err := os.WriteFile(source, []byte("new content"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(victim, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, destination); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(source, destination, 0o600); err != nil {
		t.Fatal(err)
	}
	victimData, _ := os.ReadFile(victim)
	if string(victimData) != "keep me" {
		t.Fatalf("copy followed destination symlink: %q", victimData)
	}
	info, err := os.Lstat(destination)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatal("destination is still a symlink")
	}
	destinationData, _ := os.ReadFile(destination)
	if string(destinationData) != "new content" {
		t.Fatalf("destination content=%q", destinationData)
	}
}
