package caddyctl

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

func (a *App) Run(args []string) error {
	cmd := ""
	if len(args) > 0 {
		cmd = args[0]
		args = args[1:]
	}
	if cmd == "help" || cmd == "-h" || cmd == "--help" {
		a.help()
		return nil
	}
	if cmd == "" || cmd == "menu" {
		if os.Geteuid() != 0 && a.Paths.Root == "" {
			return fmt.Errorf("请用 root 或 sudo 运行，例如: sudo c")
		}
		if err := a.preparePendingImport(); err != nil {
			fmt.Fprintf(a.Err, "警告: 首次自动导入失败: %v\n", err)
		}
		return a.interactiveMenu()
	}
	if !knownCommand(cmd) {
		return fmt.Errorf("未知命令: %s", cmd)
	}
	readOnly := readOnlyCommand(cmd, args) || cloudflareReadOnly(cmd, args)
	if !readOnly && os.Geteuid() != 0 && a.Paths.Root == "" {
		return fmt.Errorf("请用 root 或 sudo 运行，例如: sudo c")
	}
	if !readOnly {
		if err := a.ensureDirs(); err != nil {
			return err
		}
	}
	if err := a.loadState(); err != nil {
		return err
	}
	if autoImportEligible(cmd, args) {
		if err := a.maybeAutoImportExistingConfig(); err != nil {
			fmt.Fprintf(a.Err, "警告: 首次自动导入失败: %v\n", err)
		}
	}
	switch cmd {
	case "list", "ls":
		return a.listSites(false)
	case "list-emby", "emby-list":
		return a.listSites(true)
	case "add":
		if len(args) == 0 {
			return a.interactiveAddCommand("proxy")
		}
		return a.mutate("add", func() error { return a.addProxy(args) })
	case "add-static", "static":
		if len(args) == 0 {
			return a.interactiveAddCommand("static")
		}
		return a.mutate("add-static", func() error { return a.addStatic(args) })
	case "add-emby", "emby":
		if len(args) == 0 {
			return a.interactiveAddCommand("emby")
		}
		return a.mutate("add-emby", func() error { return a.addEmby(args) })
	case "add-gateway", "gateway":
		if len(args) == 0 {
			return a.interactiveAddCommand("gateway")
		}
		return a.mutate("add-gateway", func() error { return a.addGateway(args) })
	case "set":
		return a.mutate("set", func() error { return a.setSite(args) })
	case "set-static":
		return a.mutate("set-static", func() error { return a.setStatic(args) })
	case "set-emby":
		return a.mutate("set-emby", func() error { return a.setEmby(args) })
	case "set-gateway":
		return a.mutate("set-gateway", func() error { return a.setGateway(args) })
	case "rm", "del", "delete", "rm-emby", "del-emby", "delete-emby":
		return a.mutate("rm", func() error { return a.removeSite(args) })
	case "enable", "disable":
		return a.mutate(cmd, func() error { return a.toggleSite(args, cmd == "enable") })
	case "email":
		return a.mutate("email", func() error { return a.setEmail(args) })
	case "timeout":
		if len(args) == 0 {
			return a.setTimeout(args)
		}
		return a.mutate("timeout", func() error { return a.setTimeout(args) })
	case "upstream-mode":
		if len(args) == 0 {
			return a.setUpstreamMode(args)
		}
		return a.mutate("upstream-mode", func() error { return a.setUpstreamMode(args) })
	case "validate", "check":
		data, err := a.renderManaged()
		if err != nil {
			return err
		}
		if err := a.validate(data); err != nil {
			return err
		}
		fmt.Fprintln(a.Out, "配置校验通过")
		return nil
	case "apply", "reload":
		return a.mutate("apply", a.apply)
	case "config", "cat":
		data, err := os.ReadFile(a.Paths.Caddyfile)
		if err != nil {
			return err
		}
		_, err = a.Out.Write(data)
		return err
	case "snapshots", "snapshot":
		if len(args) > 1 {
			return fmt.Errorf("用法: c snapshots [数量|all]")
		}
		limit := ""
		if len(args) > 0 {
			limit = args[0]
		}
		return a.listSnapshots(limit)
	case "undo":
		if len(args) > 1 {
			return fmt.Errorf("用法: c undo [快照ID]")
		}
		requested := "latest"
		if len(args) > 0 {
			requested = args[0]
		}
		return a.undo(requested)
	case "start", "restart", "stop":
		return a.serviceCommand(cmd)
	case "status":
		return a.serviceCommand("status")
	case "logs":
		return a.logs()
	case "doctor", "check-env":
		return a.doctor()
	case "cert-check":
		return a.certCheck(args)
	case "import":
		return a.importCommand(args)
	case "cloudflare", "cf":
		return a.cloudflareCommand(args)
	case "update":
		return a.withLock(func() error { return a.updateCommand(args) })
	case "install-self", "self-install":
		return a.withLock(func() error { return a.selfInstallCommand(args) })
	case "install":
		return a.withLock(func() error { return a.installCommand(args) })
	case "version", "--version":
		fmt.Fprintln(a.Out, Version)
		return nil
	}
	return nil
}

func autoImportEligible(cmd string, args []string) bool {
	switch cmd {
	case "version", "--version", "update", "install", "install-self", "self-install", "cloudflare", "cf":
		return false
	case "timeout", "upstream-mode":
		return len(args) > 0
	default:
		return true
	}
}

func cloudflareReadOnly(cmd string, args []string) bool {
	if cmd != "cloudflare" && cmd != "cf" {
		return false
	}
	return len(args) == 0 || args[0] == "" || args[0] == "status" || args[0] == "show" || args[0] == "check"
}

func readOnlyCommand(cmd string, args []string) bool {
	switch cmd {
	case "list", "ls", "list-emby", "emby-list", "status", "logs", "snapshots", "snapshot", "config", "cat", "validate", "check", "doctor", "check-env", "cert-check", "version", "--version":
		return true
	case "timeout", "upstream-mode":
		return len(args) == 0
	default:
		return false
	}
}

func knownCommand(cmd string) bool {
	switch cmd {
	case "list", "ls", "list-emby", "emby-list",
		"add", "add-static", "static", "add-emby", "emby", "add-gateway", "gateway",
		"set", "set-static", "set-emby", "set-gateway",
		"rm", "del", "delete", "rm-emby", "del-emby", "delete-emby", "enable", "disable",
		"email", "timeout", "upstream-mode", "validate", "check", "apply", "reload",
		"config", "cat", "snapshots", "snapshot", "undo", "start", "restart", "stop", "status", "logs",
		"doctor", "check-env", "cert-check", "import", "cloudflare", "cf", "update",
		"install", "install-self", "self-install", "version", "--version":
		return true
	default:
		return false
	}
}

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

func (a *App) setTimeout(args []string) error {
	if len(args) > 1 {
		return fmt.Errorf("用法: c timeout [秒|default]")
	}
	if len(args) == 0 {
		fmt.Fprintf(a.Out, "当前服务超时: %ds\n", a.State.Timeout)
		return nil
	}
	value := args[0]
	if value == "default" {
		value = strconv.Itoa(defaultTimeout)
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < 1 || n > 600 {
		return fmt.Errorf("超时必须是 1-600 秒内的整数")
	}
	a.State.Timeout = n
	return a.saveState()
}

func (a *App) setUpstreamMode(args []string) error {
	if len(args) > 1 {
		return fmt.Errorf("用法: c upstream-mode [warn|strict]")
	}
	if len(args) == 0 {
		fmt.Fprintf(a.Out, "当前上游健康检查模式: %s\n", a.State.UpstreamMode)
		return nil
	}
	if args[0] != "warn" && args[0] != "strict" {
		return fmt.Errorf("模式仅支持 warn 或 strict")
	}
	a.State.UpstreamMode = args[0]
	return a.saveState()
}

func (a *App) setEmail(args []string) error {
	if len(args) > 1 {
		return fmt.Errorf("用法: c email [邮箱]")
	}
	email := ""
	if len(args) > 0 {
		email = strings.TrimSpace(args[0])
	} else {
		fmt.Fprint(a.Out, "请输入邮箱（回车清空）: ")
		scanner := bufio.NewScanner(a.In)
		if !scanner.Scan() {
			if err := scanner.Err(); err != nil {
				return fmt.Errorf("读取邮箱: %w", err)
			}
			return fmt.Errorf("未读取到邮箱输入")
		}
		email = strings.TrimSpace(scanner.Text())
	}
	if !validEmail(email) {
		return fmt.Errorf("邮箱格式不合法")
	}
	old := a.State.Email
	a.State.Email = email
	if err := a.saveState(); err != nil {
		return err
	}
	if err := a.apply(); err != nil {
		a.State.Email = old
		_ = a.saveState()
		return err
	}
	return nil
}
