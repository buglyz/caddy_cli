package caddyctl

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	defaultTimeout      = 30
	defaultLockWait     = 30
	defaultSnapshotKeep = 30
)

type Paths struct {
	Root             string
	Caddyfile        string
	Sites            string
	Globals          string
	State            string
	Backup           string
	Snapshots        string
	AccessLog        string
	Lock             string
	CloudflareEnv    string
	CloudflareMarker string
}

type State struct {
	Email        string
	Timeout      int
	UpstreamMode string
}

type App struct {
	In         io.Reader
	Out        io.Writer
	Err        io.Writer
	Paths      Paths
	State      State
	CaddyBin   string
	Cloudflare bool
	NoReload   bool
}

func New(in io.Reader, out, errOut io.Writer) (*App, error) {
	root := strings.TrimSuffix(os.Getenv("CADDYCTL_ROOT"), "/")
	under := func(path string) string {
		if root == "" {
			return path
		}
		return filepath.Join(root, strings.TrimPrefix(path, "/"))
	}
	app := &App{
		In: in, Out: out, Err: errOut,
		Paths: Paths{
			Root: root, Caddyfile: under("/etc/caddy/Caddyfile"),
			Sites: under("/etc/caddy/sites.d"), Globals: under("/etc/caddy/globals.d"),
			State: under("/etc/caddy/caddyctl.conf"), Backup: under("/etc/caddy/backup"),
			Snapshots: under("/etc/caddy/backup/snapshots"), AccessLog: under("/var/log/caddy"),
			Lock:             under("/run/lock/caddyctl/caddyctl.lock"),
			CloudflareEnv:    under("/etc/caddy/cloudflare.env"),
			CloudflareMarker: under("/etc/caddy/.caddyctl-cloudflare"),
		},
		State:      State{Timeout: defaultTimeout, UpstreamMode: "warn"},
		Cloudflare: truthy(os.Getenv("CADDYCTL_CLOUDFLARE")),
		NoReload:   root != "" || truthy(os.Getenv("CADDYCTL_NO_RELOAD")),
	}
	if strings.Contains(strings.ToLower(filepath.Base(os.Args[0])), "cloudflare") {
		app.Cloudflare = true
	}
	if _, err := os.Stat(app.Paths.CloudflareMarker); err == nil {
		app.Cloudflare = true
	}
	app.CaddyBin = os.Getenv("CADDY_BIN")
	if app.CaddyBin == "" {
		app.CaddyBin = "caddy"
	}
	return app, nil
}

func (a *App) ensureDirs() error {
	for _, dir := range []string{a.Paths.Sites, a.Paths.Globals, a.Paths.Backup, a.Paths.Snapshots, a.Paths.AccessLog, filepath.Dir(a.Paths.Lock)} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("创建目录 %s: %w", dir, err)
		}
	}
	if _, err := os.Stat(a.Paths.State); os.IsNotExist(err) {
		if err := os.WriteFile(a.Paths.State, nil, 0o644); err != nil {
			return fmt.Errorf("创建状态文件: %w", err)
		}
	}
	return nil
}

func (a *App) loadState() error {
	a.State = State{Timeout: defaultTimeout, UpstreamMode: "warn"}
	f, err := os.Open(a.Paths.State)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("读取状态文件: %w", err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		value = strings.Trim(strings.TrimSpace(value), "\"'")
		switch strings.TrimSpace(key) {
		case "EMAIL":
			if validEmail(value) {
				a.State.Email = value
			}
		case "SYSTEMCTL_TIMEOUT_SECONDS":
			n, parseErr := strconv.Atoi(value)
			if parseErr == nil && n >= 1 && n <= 600 {
				a.State.Timeout = n
			}
		case "UPSTREAM_CHECK_MODE":
			if value == "warn" || value == "strict" {
				a.State.UpstreamMode = value
			}
		}
	}
	if err := s.Err(); err != nil {
		return fmt.Errorf("解析状态文件: %w", err)
	}
	return nil
}

func (a *App) saveState() error {
	if !validEmail(a.State.Email) {
		return fmt.Errorf("邮箱格式不合法")
	}
	if a.State.Timeout < 1 || a.State.Timeout > 600 {
		return fmt.Errorf("服务超时不合法")
	}
	if a.State.UpstreamMode != "warn" && a.State.UpstreamMode != "strict" {
		return fmt.Errorf("上游检查模式不合法")
	}
	data := fmt.Sprintf("EMAIL=\"%s\"\nSYSTEMCTL_TIMEOUT_SECONDS=\"%d\"\nUPSTREAM_CHECK_MODE=\"%s\"\n", a.State.Email, a.State.Timeout, a.State.UpstreamMode)
	return atomicWrite(a.Paths.State, []byte(data), 0o644)
}

func truthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
