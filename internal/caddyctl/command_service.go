package caddyctl

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func (a *App) serviceCommand(action string) error {
	if a.Paths.Root != "" {
		return fmt.Errorf("CADDYCTL_ROOT 隔离模式不执行 Caddy 服务操作")
	}
	backend := serviceBackend()
	if backend == "" {
		return fmt.Errorf("未检测到 service manager")
	}
	if action == "status" {
		if backend == "systemd" {
			cmd := exec.Command("systemctl", "status", "caddy", "--no-pager")
			cmd.Stdout, cmd.Stderr = a.Out, a.Err
			return cmd.Run()
		}
		return runServiceCommand(a.State.Timeout, backend, "is-active")
	}
	return a.withLock(func() error { return runServiceCommand(a.State.Timeout, backend, action) })
}

func (a *App) logs() error {
	if a.Paths.Root == "" {
		if _, err := exec.LookPath("journalctl"); err == nil {
			cmd := exec.Command("journalctl", "-u", "caddy", "-n", "120", "--no-pager")
			cmd.Stdout, cmd.Stderr = a.Out, a.Err
			if err := cmd.Run(); err == nil {
				return nil
			}
		}
	}
	paths := []string{"/var/log/caddy.log", "/var/log/caddy/caddy.log"}
	for _, path := range paths {
		if a.Paths.Root != "" {
			path = filepath.Join(a.Paths.Root, strings.TrimPrefix(path, "/"))
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
		if len(lines) > 120 {
			lines = lines[len(lines)-120:]
		}
		_, err = fmt.Fprintln(a.Out, strings.Join(lines, "\n"))
		return err
	}
	return fmt.Errorf("未检测到 Caddy 日志（无可用 journalctl 或日志文件）")
}
