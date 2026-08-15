package caddyctl

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

func (a *App) assertManaged() error {
	live, err := os.ReadFile(a.Paths.Caddyfile)
	if errors.Is(err, os.ErrNotExist) || len(bytes.TrimSpace(live)) == 0 {
		return nil
	}
	if err != nil {
		return err
	}
	rendered, err := a.renderManaged()
	if err != nil {
		return err
	}
	if !bytes.Equal(live, rendered) {
		return fmt.Errorf("live Caddyfile 与 sites.d/globals.d 的 managed 渲染不一致，已拒绝覆盖；请先执行 c import --merge %s", a.Paths.Caddyfile)
	}
	return nil
}

func (a *App) validate(data []byte) error {
	tmp, err := os.CreateTemp("", "caddyctl-validate-*.Caddyfile")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	cmd := exec.Command(a.CaddyBin, "validate", "--config", name, "--adapter", "caddyfile")
	cmd.Env = append(os.Environ(), readEnvFile(a.Paths.CloudflareEnv)...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("配置校验失败: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

func readEnvFile(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var result []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		key, value, _ := strings.Cut(line, "=")
		// 与 escapeEnv 对称解析,避免把转义后的值原样注入环境。
		if unescaped, parseErr := unescapeEnv(value); parseErr == nil {
			value = unescaped
		}
		result = append(result, strings.TrimSpace(key)+"="+value)
	}
	return result
}

func (a *App) apply() error {
	rendered, err := a.renderManaged()
	if err != nil {
		return fmt.Errorf("生成配置: %w", err)
	}
	if err := a.checkLocalUpstreams(rendered); err != nil {
		return err
	}
	if err := a.validate(rendered); err != nil {
		return err
	}
	old, readErr := os.ReadFile(a.Paths.Caddyfile)
	hadOld := readErr == nil
	if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
		return readErr
	}
	if err := atomicWrite(a.Paths.Caddyfile, rendered, 0o644); err != nil {
		return fmt.Errorf("应用配置: %w", err)
	}
	if err := a.reload(); err != nil {
		if hadOld {
			_ = atomicWrite(a.Paths.Caddyfile, old, 0o644)
		} else {
			_ = os.Remove(a.Paths.Caddyfile)
		}
		return fmt.Errorf("重载失败，已恢复 live Caddyfile: %w", err)
	}
	return nil
}

var reverseProxyRE = regexp.MustCompile(`(?m)^\s*reverse_proxy\s+(?:http://|https://)?(?:127\.0\.0\.1|localhost|\[::1\]):([0-9]+)`)

func (a *App) checkLocalUpstreams(data []byte) error {
	mode := getenv("CADDYCTL_UPSTREAM_CHECK_MODE", a.State.UpstreamMode)
	seen := map[string]bool{}
	for _, match := range reverseProxyRE.FindAllSubmatch(data, -1) {
		port := string(match[1])
		if seen[port] {
			continue
		}
		seen[port] = true
		conn, err := net.DialTimeout("tcp", "127.0.0.1:"+port, 300*time.Millisecond)
		if err == nil {
			conn.Close()
			continue
		}
		fmt.Fprintf(a.Err, "警告: localhost:%s 未监听\n", port)
		if mode == "strict" {
			return fmt.Errorf("上游健康检查失败（strict 模式）")
		}
	}
	return nil
}

func (a *App) reload() error {
	if a.NoReload {
		return nil
	}
	backend := serviceBackend()
	if backend == "" {
		fmt.Fprintf(a.Out, "未检测到 service manager，配置已写入 %s，请手动重载 Caddy。\n", a.Paths.Caddyfile)
		return nil
	}
	active := runServiceCommand(a.State.Timeout, backend, "is-active") == nil
	if !active {
		return runServiceCommand(a.State.Timeout, backend, "start")
	}
	if err := runServiceCommand(a.State.Timeout, backend, "reload"); err != nil {
		return runServiceCommand(a.State.Timeout, backend, "restart")
	}
	return nil
}

func serviceBackend() string {
	if _, err := exec.LookPath("systemctl"); err == nil {
		return "systemd"
	}
	if _, err := exec.LookPath("rc-service"); err == nil {
		return "openrc"
	}
	return ""
}

func runServiceCommand(timeout int, backend, action string) error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()
	var cmd *exec.Cmd
	if backend == "systemd" {
		args := []string{action, "caddy"}
		if action == "is-active" {
			args = append(args, "--quiet")
		}
		cmd = exec.CommandContext(ctx, "systemctl", args...)
	} else {
		if action == "is-active" {
			action = "status"
		}
		cmd = exec.CommandContext(ctx, "rc-service", "caddy", action)
	}
	output, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return fmt.Errorf("服务操作超时（%ds）", timeout)
	}
	if err != nil {
		return fmt.Errorf("%s: %s", action, strings.TrimSpace(string(output)))
	}
	return nil
}

func (a *App) caddyExists() error {
	if strings.ContainsRune(a.CaddyBin, filepath.Separator) {
		if info, err := os.Stat(a.CaddyBin); err != nil || info.Mode()&0o111 == 0 {
			return fmt.Errorf("未找到可执行 caddy: %s", a.CaddyBin)
		}
		return nil
	}
	_, err := exec.LookPath(a.CaddyBin)
	return err
}
