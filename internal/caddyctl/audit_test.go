package caddyctl

import (
	"fmt"
	"strings"
	"testing"
)

func TestDirectInteractiveCommandsRejectUnexpectedEOF(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.Run([]string{"add"}); err == nil || !strings.Contains(err.Error(), "交互输入") {
		t.Fatalf("interactive add EOF error=%v", err)
	}

	app, _, _ = newTestApp(t, "")
	runOK(t, app, "add", "proxy.example.com", "3000", "--skip-dns-check")
	if err := app.Run([]string{"set", "proxy.example.com"}); err == nil || !strings.Contains(err.Error(), "交互输入") {
		t.Fatalf("interactive set EOF error=%v", err)
	}
}

func TestCommandsWithoutArgumentsRejectTrailingValues(t *testing.T) {
	commands := []string{"list", "list-emby", "validate", "apply", "config", "start", "restart", "stop", "status", "logs", "doctor", "version", "install-self"}
	for _, command := range commands {
		app, _, _ := newTestApp(t, "")
		if err := app.Run([]string{command, "unexpected"}); err == nil || !strings.Contains(err.Error(), "用法") {
			t.Errorf("%s accepted a trailing argument: %v", command, err)
		}
	}
	app, _, _ := newTestApp(t, "")
	if err := app.Run([]string{"menu", "unexpected"}); err == nil {
		t.Fatal("menu accepted a trailing argument")
	}
}

func TestCommandsRejectAmbiguousTrailingArguments(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	if err := app.Run([]string{"import", "one.Caddyfile", "two.Caddyfile"}); err == nil || !strings.Contains(err.Error(), "用法") {
		t.Fatalf("import accepted multiple sources: %v", err)
	}
	if err := app.Run([]string{"cert-check", "example.com", "extra"}); err == nil || !strings.Contains(err.Error(), "用法") {
		t.Fatalf("cert-check accepted trailing arguments: %v", err)
	}
	app.Cloudflare = true
	if err := app.Run([]string{"cloudflare", "check", "extra"}); err == nil || !strings.Contains(err.Error(), "用法") {
		t.Fatalf("cloudflare check accepted trailing arguments: %v", err)
	}
}

func TestFirstLinesLimitsGlobalFragmentOutput(t *testing.T) {
	var lines []string
	for i := 1; i <= 100; i++ {
		lines = append(lines, fmt.Sprintf("line-%03d", i))
	}
	result := firstLines(strings.Join(lines, "\n"), 80)
	if !strings.Contains(result, "line-080") || strings.Contains(result, "line-081") {
		t.Fatalf("firstLines did not enforce limit:\n%s", result)
	}
}

func TestAddSeparatorDoesNotBypassFlagConflicts(t *testing.T) {
	if _, err := parseAddFlags([]string{"--http", "--dns-only", "--", "app.example.com", "3000"}, "add"); err == nil {
		t.Fatal("-- bypassed HTTP/DNS-only conflict")
	}
	if _, err := parseAddFlags([]string{"--allow", "example.com:443", "--unsafe-open-proxy", "--", "gate.example.com"}, "add-gateway"); err == nil {
		t.Fatal("-- bypassed gateway allow/open conflict")
	}
}

func TestImportIgnoresLiteralBracesInsideQuotes(t *testing.T) {
	for _, source := range []string{
		"literal.example.com {\n    respond \"literal { brace\" 200\n}\n",
		"literal.example.com {\n    respond `literal { brace` 200\n}\n",
		"literal.example.com {\n    respond `line one\nliteral { brace\nline three` 200\n}\n",
	} {
		blocks, err := splitCaddyBlocks(source)
		if err != nil || len(blocks) != 1 || blocks[0].Text != source {
			t.Fatalf("quoted literal brace split failed: blocks=%v err=%v", blocks, err)
		}
	}
}
