package caddyctl

import (
	"testing"
)

func TestKnownCommand(t *testing.T) {
	known := []string{
		"list", "ls", "list-emby", "emby-list",
		"add", "add-static", "static", "add-emby", "emby", "add-gateway", "gateway",
		"set", "set-static", "set-emby", "set-gateway",
		"rm", "del", "delete", "rm-emby", "del-emby", "delete-emby", "enable", "disable",
		"email", "timeout", "upstream-mode", "validate", "check", "apply", "reload",
		"config", "cat", "snapshots", "snapshot", "undo", "start", "restart", "stop", "status", "logs",
		"doctor", "check-env", "cert-check", "import", "cloudflare", "cf", "update",
		"install", "install-self", "self-install", "version", "--version",
	}
	for _, cmd := range known {
		if !knownCommand(cmd) {
			t.Errorf("knownCommand(%q) = false, want true", cmd)
		}
	}
	unknown := []string{"foo", "", "delete-all", "-x"}
	for _, cmd := range unknown {
		if knownCommand(cmd) {
			t.Errorf("knownCommand(%q) = true, want false", cmd)
		}
	}
}

func TestNoArgCommand(t *testing.T) {
	noArg := []string{"list", "ls", "list-emby", "emby-list", "validate", "check", "apply", "reload",
		"config", "cat", "start", "restart", "stop", "status", "logs", "doctor", "check-env",
		"version", "--version", "install-self", "self-install"}
	for _, cmd := range noArg {
		if !noArgCommand(cmd) {
			t.Errorf("noArgCommand(%q) = false, want true", cmd)
		}
	}
	withArg := []string{"add", "set", "rm", "enable", "disable", "email", "timeout", "update", "install", "import"}
	for _, cmd := range withArg {
		if noArgCommand(cmd) {
			t.Errorf("noArgCommand(%q) = true, want false", cmd)
		}
	}
}

func TestReadOnlyCommand(t *testing.T) {
	readOnly := []struct {
		cmd  string
		args []string
	}{
		{"list", nil}, {"status", nil}, {"logs", nil},
		{"snapshots", nil}, {"config", nil}, {"validate", nil},
		{"doctor", nil}, {"cert-check", []string{"example.com"}}, {"version", nil},
		// timeout/upstream-mode 无参时只读
		{"timeout", nil}, {"upstream-mode", nil},
	}
	for _, tc := range readOnly {
		if !readOnlyCommand(tc.cmd, tc.args) {
			t.Errorf("readOnlyCommand(%q,%v) = false, want true", tc.cmd, tc.args)
		}
	}
	write := []struct {
		cmd  string
		args []string
	}{
		{"timeout", []string{"30"}}, {"upstream-mode", []string{"strict"}},
		{"add", []string{"example.com", "3000"}}, {"rm", []string{"example.com"}},
		{"update", nil}, {"apply", nil},
	}
	for _, tc := range write {
		if readOnlyCommand(tc.cmd, tc.args) {
			t.Errorf("readOnlyCommand(%q,%v) = true, want false", tc.cmd, tc.args)
		}
	}
}

func TestCloudflareReadOnly(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want bool
	}{
		{nil, true}, {[]string{""}, true},
		{[]string{"status"}, true}, {[]string{"show"}, true}, {[]string{"check"}, true},
		{[]string{"set"}, false}, {[]string{"remove"}, false}, {[]string{"clear"}, false},
	} {
		if got := cloudflareReadOnly("cloudflare", tc.args); got != tc.want {
			t.Errorf("cloudflareReadOnly(%v) = %v, want %v", tc.args, got, tc.want)
		}
	}
	if cloudflareReadOnly("cf", []string{"status"}) != true {
		t.Error("cloudflareReadOnly(cf status) = false, want true")
	}
	if cloudflareReadOnly("add", []string{"x"}) != false {
		t.Error("cloudflareReadOnly(add) should be false")
	}
}

func TestAutoImportEligible(t *testing.T) {
	for _, tc := range []struct {
		cmd  string
		args []string
		want bool
	}{
		{"version", nil, false}, {"--version", nil, false},
		{"update", nil, false}, {"install", nil, false},
		{"install-self", nil, false}, {"cloudflare", nil, false}, {"cf", []string{"check"}, false},
		{"timeout", nil, false}, {"upstream-mode", nil, false},
		{"timeout", []string{"30"}, true}, {"upstream-mode", []string{"strict"}, true},
		{"list", nil, true}, {"add", []string{"example.com", "3000"}, true}, {"undo", nil, true},
	} {
		if got := autoImportEligible(tc.cmd, tc.args); got != tc.want {
			t.Errorf("autoImportEligible(%q,%v) = %v, want %v", tc.cmd, tc.args, got, tc.want)
		}
	}
}

func TestValidReleaseRefRejectsTraversal(t *testing.T) {
	if validReleaseRef("..") || validReleaseRef(".") {
		t.Fatal("validReleaseRef accepts traversal")
	}
}
