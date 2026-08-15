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
			m.run("list")
			m.pause()
		case "2":
			m.run("restart")
			m.pause()
		case "3":
			m.run("logs")
			m.pause()
		case "4":
			m.sitesMenu()
		case "5":
			m.embyMenu()
		case "6":
			m.configMenu()
		case "7":
			m.diagnosticsMenu()
		case "8":
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

【快速操作】
1. 查看所有站点状态
2. 重启 Caddy 服务
3. 查看最近日志

【站点管理】
4. 站点管理
5. Emby 专用管理

【系统管理】
6. 服务与配置
7. 诊断与维护
8. 安装与更新

0. 退出
============================
`)
}

func (m *menuSession) sitesMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 站点管理 ======
【查看】
1. 查看所有站点

【添加站点】
2. 添加反向代理
3. 添加静态网站

【管理站点】
4. 修改站点配置
5. 启用/禁用站点
6. 删除站点
0. 返回上一级
======================
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
====== Emby 专用管理 ======
【查看】
1. 查看 Emby 配置

【添加】
2. 添加固定反代
3. 添加通用网关

【管理】
4. 修改配置
5. 删除配置
0. 返回上一级
======================
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
