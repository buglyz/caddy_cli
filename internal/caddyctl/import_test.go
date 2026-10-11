package caddyctl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSplitCaddyBlocksBasics 覆盖基本分块、全局块与多站点。
func TestSplitCaddyBlocksBasics(t *testing.T) {
	input := `
{
    email admin@example.com
}

app.example.com {
    reverse_proxy 127.0.0.1:3000
}

static.example.com {
    root * /srv/site
}
`
	blocks, err := splitCaddyBlocks(input)
	if err != nil {
		t.Fatalf("splitCaddyBlocks: %v", err)
	}
	if len(blocks) != 3 {
		t.Fatalf("expected 3 blocks, got %d: %+v", len(blocks), blocks)
	}
	if blocks[0].Header != "{" || !strings.Contains(blocks[0].Text, "admin@example.com") {
		t.Fatalf("global block mismatch: %+v", blocks[0])
	}
	if blocks[1].Header != "app.example.com {" {
		t.Fatalf("site header mismatch: %q", blocks[1].Header)
	}
	if !strings.Contains(blocks[2].Text, "/srv/site") {
		t.Fatalf("static block text mismatch: %+v", blocks[2])
	}
}

// TestSplitCaddyBlocksQuotedBracesAndComments 覆盖引号内大括号与行内注释不干扰深度计数。
func TestSplitCaddyBlocksQuotedBracesAndComments(t *testing.T) {
	input := `api.example.com {
    respond "{\"json\": true}" 200
    handle {
        respond "ok" 200
    }
    # comment with } brace
    redir /old /new 308
}
`
	blocks, err := splitCaddyBlocks(input)
	if err != nil {
		t.Fatalf("splitCaddyBlocks: %v", err)
	}
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block (quoted braces must not split), got %d", len(blocks))
	}
	if !strings.Contains(blocks[0].Text, "redir /old /new 308") {
		t.Fatalf("block text missing trailing directive: %+v", blocks[0])
	}
}

// TestSplitCaddyBlocksBacktick 覆盖反引号字符串内的大括号。
func TestSplitCaddyBlocksBacktick(t *testing.T) {
	input := "tpl.example.com {\n    respond `{ \"a\": 1 }` 200\n}\n"
	blocks, err := splitCaddyBlocks(input)
	if err != nil {
		t.Fatalf("splitCaddyBlocks: %v", err)
	}
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
}

// TestSplitCaddyBlocksErrors 覆盖不完整与不匹配的错误路径。
func TestSplitCaddyBlocksErrors(t *testing.T) {
	cases := map[string]string{
		"unbalanced":    "a.example.com {\n    respond \"ok\"\n}\n}\n",
		"unclosed":      "a.example.com {\n    respond \"ok\"\n",
		"unclosedQuote": "a.example.com {\n    respond \"unterminated 200\n}\n",
	}
	for name, input := range cases {
		if _, err := splitCaddyBlocks(input); err == nil {
			t.Errorf("%s: expected error, got nil", name)
		}
	}
}

// TestSplitCaddyBlocksCRLF 覆盖 CRLF 归一化。
func TestSplitCaddyBlocksCRLF(t *testing.T) {
	input := "a.example.com {\r\n    respond \"ok\" 200\r\n}\r\n"
	blocks, err := splitCaddyBlocks(input)
	if err != nil {
		t.Fatalf("splitCaddyBlocks: %v", err)
	}
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	if strings.Contains(blocks[0].Text, "\r") {
		t.Fatalf("CR not normalized: %+v", blocks[0])
	}
}

// TestSlugHeaderStripsScheme 回归：带 scheme 的站点头（如 https://auto.fleey.de）
// 必须与已有裸域名 conf 命中同一文件名，否则 merge 生成重复站点导致
// ambiguous site definition。
func TestSlugHeaderStripsScheme(t *testing.T) {
	cases := map[string]string{
		"https://auto.fleey.de": "auto.fleey.de",
		"http://a.example.com":  "a.example.com",
		"app.example.com":       "app.example.com",
	}
	for header, want := range cases {
		if got := slugHeader(header); got != want {
			t.Errorf("slugHeader(%q) = %q, want %q", header, got, want)
		}
	}
}

// TestImportAcceptsRenderedEmail 回归：renderManaged 输出的 email 带 quoteCaddy
// 引号，import 必须反转义，否则 caddyctl config 的输出无法被 import --merge 回吃。
func TestImportAcceptsRenderedEmail(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	source := filepath.Join(app.Paths.Root, "rendered.Caddyfile")
	content := "# managed by caddyctl\n\n{\n    email \"admin@example.com\"\n}\n\napp.example.com {\n    reverse_proxy 127.0.0.1:3000\n}\n"
	if err := os.WriteFile(source, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := app.importCommand([]string{"--force", source}); err != nil {
		t.Fatalf("import rendered config: %v", err)
	}
	if app.State.Email != "admin@example.com" {
		t.Errorf("email = %q, want admin@example.com", app.State.Email)
	}
}

// TestImportMergePreservesBlockComments 锁定行为：import 回吃 caddyctl config
// 输出时，站点块前的注释（如网关说明）必须跟随块写回 sites.d conf。
func TestImportMergePreservesBlockComments(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	source := filepath.Join(app.Paths.Root, "comments.Caddyfile")
	content := "{\n    email admin@example.com\n}\n\n# gateway 说明注释\nauto.example.com {\n    @m path_regexp up ^/https:/*([A-Za-z0-9.\\-_]+)(/.*)\n    handle @m {\n        reverse_proxy 127.0.0.1:8998\n    }\n}\n"
	if err := os.WriteFile(source, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := app.importCommand([]string{"--force", source}); err != nil {
		t.Fatalf("import: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(app.Paths.Sites, "auto.example.com.conf"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "# gateway 说明注释") {
		t.Errorf("block comment lost after import:\n%s", data)
	}
}
