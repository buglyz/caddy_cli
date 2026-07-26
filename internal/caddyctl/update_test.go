package caddyctl

import (
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestUpdateBinaryVerifiesAndKeepsBackup(t *testing.T) {
	current, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	payload, err := os.ReadFile(current)
	if err != nil {
		t.Fatal(err)
	}
	asset := "caddyctl-linux-" + runtime.GOARCH
	sum := sha256.Sum256(payload)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch filepath.Base(request.URL.Path) {
		case asset:
			writer.Write(payload)
		case "caddyctl-checksums.txt":
			fmt.Fprintf(writer, "%x  %s\n", sum, asset)
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()
	t.Setenv("CADDYCTL_GO_RELEASE_BASE_URL", server.URL)
	destination := filepath.Join(t.TempDir(), "caddyctl-go")
	old := []byte("#!/bin/sh\nexit 0\n")
	if err := os.WriteFile(destination, old, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := updateBinary(destination, "latest"); err != nil {
		t.Fatal(err)
	}
	updated, _ := os.ReadFile(destination)
	if string(updated) != string(payload) {
		t.Fatal("destination does not contain verified release binary")
	}
	backup, _ := os.ReadFile(destination + ".bak")
	if string(backup) != string(old) {
		t.Fatal("previous binary backup was not preserved")
	}
}

func TestUpdateBinaryRejectsBadChecksum(t *testing.T) {
	asset := "caddyctl-linux-" + runtime.GOARCH
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if strings.HasSuffix(request.URL.Path, "checksums.txt") {
			fmt.Fprintf(writer, "%064d  %s\n", 0, asset)
			return
		}
		fmt.Fprint(writer, "not a binary")
	}))
	defer server.Close()
	t.Setenv("CADDYCTL_GO_RELEASE_BASE_URL", server.URL)
	destination := filepath.Join(t.TempDir(), "caddyctl-go")
	old := []byte("old")
	if err := os.WriteFile(destination, old, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := updateBinary(destination, "latest"); err == nil {
		t.Fatal("bad checksum unexpectedly succeeded")
	}
	after, _ := os.ReadFile(destination)
	if string(after) != string(old) {
		t.Fatal("destination changed after checksum failure")
	}
}
