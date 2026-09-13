package caddyctl

import (
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
