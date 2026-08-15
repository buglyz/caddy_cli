package caddyctl

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestCloudflareTokenRoundTrip(t *testing.T) {
	for _, token := range []string{
		"abc123DEF-_xyz",
		`abc"def`,
		`abc\def`,
		`abc"def\ghi`,
	} {
		raw := `CLOUDFLARE_API_TOKEN="` + escapeEnv(token) + `"`
		got, err := unescapeEnv(strings.TrimPrefix(raw, "CLOUDFLARE_API_TOKEN="))
		if err != nil {
			t.Fatalf("token %q unescape: %v", token, err)
		}
		if got != token {
			t.Fatalf("round-trip mismatch: wrote %q got %q", token, got)
		}
	}
}

func TestReadCloudflareTokenFile(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/cloudflare.env"
	content := "CLOUDFLARE_API_TOKEN=\"token-123\"\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readCloudflareToken(path)
	if err != nil || got != "token-123" {
		t.Fatalf("readCloudflareToken got=%q err=%v", got, err)
	}
}

func TestReadTokenInputSpan(t *testing.T) {
	// 注意:bufio.Scanner 按行分割,含换行的输入会被当作多行处理,
	// 因此 "a\nb" 不在本用例范围内(换行是分隔符而非 token 内容)。
	for _, bad := range []string{`a"b`, `a'b`, `a\b`, "a b"} {
		if _, err := readTokenInput(strings.NewReader(bad)); err == nil {
			t.Fatalf("token %q should be rejected", bad)
		}
	}
	if token, err := readTokenInput(strings.NewReader("normal-token-123\n")); err != nil || token != "normal-token-123" {
		t.Fatalf("valid token rejected: token=%q err=%v", token, err)
	}
}

func TestVerifyCloudflareTokenRejectsCrossHostRedirect(t *testing.T) {
	evil := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer evil.Close()
	victim := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, evil.URL, http.StatusFound)
	}))
	defer victim.Close()

	t.Setenv("CADDYCTL_CLOUDFLARE_VERIFY_URL", victim.URL)
	if err := verifyCloudflareToken("token"); err == nil {
		t.Fatal("cross-host redirect should fail")
	}
}

func TestVerifyCloudflareTokenAcceptsValidToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"success":true,"result":{"status":"active"}}`))
	}))
	defer server.Close()

	t.Setenv("CADDYCTL_CLOUDFLARE_VERIFY_URL", server.URL)
	if err := verifyCloudflareToken("token"); err != nil {
		t.Fatalf("valid token verification should pass: %v", err)
	}
}

func TestVerifyCloudflareTokenRejectsInactive(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"success":true,"result":{"status":"disabled"}}`))
	}))
	defer server.Close()

	t.Setenv("CADDYCTL_CLOUDFLARE_VERIFY_URL", server.URL)
	if err := verifyCloudflareToken("token"); err == nil {
		t.Fatal("inactive token should fail")
	}
}
