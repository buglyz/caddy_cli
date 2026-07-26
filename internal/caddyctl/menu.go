package caddyctl

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strings"
)

type menuSession struct {
	app     *App
	reader  *bufio.Reader
	lastErr error
	silent  bool
	ended   bool
}

func (a *App) interactiveMenu() error {
	m := &menuSession{app: a, reader: bufio.NewReader(a.In)}
	for {
		m.printMain()
		choice, ok := m.read("选择: ")
		if !ok {
			return nil
		}
		switch choice {
		case "1":
			m.sitesMenu()
		case "2":
			m.embyMenu()
		case "3":
			m.run("list")
			m.pause()
		case "4":
			m.serviceMenu()
		case "5":
			m.run("status")
			m.pause()
		case "6":
			m.run("logs")
			m.pause()
		case "7":
			m.configMenu()
		case "8":
			m.diagnosticsMenu()
		case "9":
			m.installMenu()
		case "0", "q", "quit", "exit":
			return nil
		default:
			m.invalid()
			m.pause()
		}
	}
}

func (m *menuSession) printMain() {
	m.clearScreen()
	fmt.Fprint(m.app.Out, `
====== Caddy CLI 管理面板 ======

【站点】
1. 普通站点（反代 / 静态）
2. Emby / 网关
3. 查看所有站点

【服务】
4. 启动 / 重启 / 停止
5. 服务状态
6. 实时日志

【配置】
7. 配置 / 导入 / 全局设置
8. 诊断 / 证书 / 备份回滚

【系统】
9. 安装与更新

0. 退出
============================
`)
}

func (m *menuSession) sitesMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 普通站点 · 反代 / 静态 ======
1. 查看所有站点
2. 添加反向代理
3. 添加静态网站
4. 修改站点
5. 启用 / 禁用站点
6. 删除站点
0. 返回上一级
===================================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			m.run("list")
		case "2":
			m.addProxy()
		case "3":
			m.addStatic()
		case "4":
			m.modifySitesMenu()
			continue
		case "5":
			m.toggleSite()
		case "6":
			m.removeSite("rm")
		default:
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) embyMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== Emby / 通用网关 ======
1. 查看 Emby 与网关
2. 添加 Emby 固定反代
3. 添加通用反代网关
4. 修改 Emby / 网关
5. 删除 Emby / 网关
0. 返回上一级
============================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			m.run("list-emby")
		case "2":
			m.addEmby()
		case "3":
			m.addGateway()
		case "4":
			m.modifyEmbyMenu()
			continue
		case "5":
			m.removeSite("rm-emby")
		default:
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) serviceMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 服务控制 ======
1. 启动 Caddy
2. 重启 Caddy
3. 停止 Caddy
4. 查看服务状态
5. 实时日志
0. 返回上一级
======================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		commands := map[string]string{"1": "start", "2": "restart", "3": "stop", "4": "status", "5": "logs"}
		if command, exists := commands[choice]; exists {
			m.run(command)
		} else {
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) run(args ...string) bool {
	if err := m.app.Run(args); err != nil {
		m.lastErr = err
		if !m.silent {
			fmt.Fprintf(m.app.Err, "错误: %v\n", err)
		}
		return false
	}
	m.lastErr = nil
	return true
}

func (m *menuSession) read(prompt string) (string, bool) {
	fmt.Fprint(m.app.Out, prompt)
	line, err := m.reader.ReadString('\n')
	line = strings.TrimSpace(line)
	if err == nil {
		return line, true
	}
	if errors.Is(err, io.EOF) {
		if line == "" {
			m.ended = true
		}
		return line, line != ""
	}
	m.ended = true
	fmt.Fprintf(m.app.Err, "错误: 读取输入: %v\n", err)
	return "", false
}

func (m *menuSession) required(prompt string) (string, bool) {
	for {
		value, ok := m.read(prompt)
		if !ok {
			return "", false
		}
		if value != "" {
			return value, true
		}
		fmt.Fprintln(m.app.Err, "错误: 输入不能为空")
	}
}

func (m *menuSession) yesNo(prompt string, defaultYes bool) (bool, bool) {
	hint := "[y/N]"
	if defaultYes {
		hint = "[Y/n]"
	}
	for {
		value, ok := m.read(prompt + " " + hint + ": ")
		if !ok {
			return false, false
		}
		switch strings.ToLower(value) {
		case "":
			return defaultYes, true
		case "y", "yes", "是":
			return true, true
		case "n", "no", "否":
			return false, true
		default:
			fmt.Fprintln(m.app.Err, "错误: 请输入 y 或 n")
		}
	}
}

func (m *menuSession) pause() {
	_, _ = m.read("\n按回车继续...")
}

func (m *menuSession) invalid() {
	fmt.Fprintln(m.app.Err, "错误: 无效输入")
}

func (m *menuSession) clearScreen() {
	if m.app.interactive {
		fmt.Fprint(m.app.Out, clearScreenSequence)
	}
}
