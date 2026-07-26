package caddyctl

import "fmt"

func (m *menuSession) modifySitesMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 修改普通站点 ======
1. 修改反代 / 路径反代
2. 修改静态网站
0. 返回上一级
==========================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			m.modifyProxy()
		case "2":
			m.modifyStatic()
		default:
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) modifyEmbyMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 修改 Emby / 网关 ======
1. 修改 Emby 固定反代
2. 修改通用反代网关
0. 返回上一级
==============================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			m.modifyEmby()
		case "2":
			m.modifyGateway()
		default:
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) modifyProxy() {
	label, ok := m.required("要修改的站点地址: ")
	if !ok {
		return
	}
	m.modifyProxyLabel(label)
}

func (m *menuSession) modifyProxyLabel(label string) {
	args := []string{"set", label}
	port, ok := m.read("新端口（留空保持）: ")
	if !ok {
		return
	}
	if port != "" {
		args = append(args, "--port", port)
	}
	path, ok := m.read("新路径前缀（留空保持，off 关闭路径反代）: ")
	if !ok {
		return
	}
	if path != "" {
		args = append(args, "--path", path)
	}
	args = append(args, m.optionalProtocolFlags()...)
	m.appendOptionalDNSOnly(&args)
	m.runChanges(args)
}

func (m *menuSession) modifyStatic() {
	label, ok := m.required("要修改的静态站点地址: ")
	if !ok {
		return
	}
	m.modifyStaticLabel(label)
}

func (m *menuSession) modifyStaticLabel(label string) {
	args := []string{"set-static", label}
	root, ok := m.read("新静态目录（留空保持）: ")
	if !ok {
		return
	}
	if root != "" {
		args = append(args, "--root", root)
	}
	for {
		spa, readOK := m.read("SPA 模式 [0=保持, 1=启用, 2=关闭]（默认 0）: ")
		if !readOK {
			return
		}
		if spa == "" || spa == "0" {
			break
		}
		if spa == "1" {
			args = append(args, "--spa")
			break
		}
		if spa == "2" {
			args = append(args, "--no-spa")
			break
		}
		m.invalid()
	}
	args = append(args, m.optionalProtocolFlags()...)
	m.appendOptionalDNSOnly(&args)
	m.runChanges(args)
}

func (m *menuSession) modifyEmby() {
	label, ok := m.required("要修改的 Emby 站点地址: ")
	if !ok {
		return
	}
	m.modifyEmbyLabel(label)
}

func (m *menuSession) modifyEmbyLabel(label string) {
	args := []string{"set-emby", label}
	target, ok := m.read("新目标地址（留空保持）: ")
	if !ok {
		return
	}
	if target != "" {
		args = append(args, "--target", target)
	}
	args = append(args, m.optionalProtocolFlags()...)
	m.appendOptionalDNSOnly(&args)
	m.runChanges(args)
}

func (m *menuSession) modifyGateway() {
	label, ok := m.required("要修改的网关地址: ")
	if !ok {
		return
	}
	m.modifyGatewayLabel(label)
}

func (m *menuSession) modifyGatewayLabel(label string) {
	args := []string{"set-gateway", label}
	allow, ok := m.read("新 allow-list（留空保持，输入 open 改为开放代理）: ")
	if !ok {
		return
	}
	if allow == "open" {
		confirmed, answered := m.yesNo("开放代理风险很高，确认继续？", false)
		if !answered || !confirmed {
			fmt.Fprintln(m.app.Err, "错误: 已取消开放代理修改")
			return
		}
		args = append(args, "--unsafe-open-proxy")
	} else if allow != "" {
		args = append(args, "--allow", allow)
	}
	args = append(args, m.optionalProtocolFlags()...)
	m.appendOptionalDNSOnly(&args)
	m.runChanges(args)
}

func (m *menuSession) runChanges(args []string) {
	if len(args) == 2 {
		fmt.Fprintln(m.app.Out, "未提供修改，已取消")
		return
	}
	m.run(args...)
}

func (m *menuSession) toggleSite() {
	label, ok := m.required("站点地址: ")
	if !ok {
		return
	}
	for {
		action, readOK := m.read("操作 [1=启用, 2=禁用]: ")
		if !readOK {
			return
		}
		switch action {
		case "1":
			m.run("enable", label)
			return
		case "2":
			m.run("disable", label)
			return
		default:
			m.invalid()
		}
	}
}

func (m *menuSession) removeSite(command string) {
	label, ok := m.required("要删除的站点地址: ")
	if !ok {
		return
	}
	confirmed, ok := m.yesNo("确认删除 "+label+"？", false)
	if ok && confirmed {
		m.run(command, label)
	} else if ok {
		fmt.Fprintln(m.app.Out, "已取消删除")
	}
}

func (m *menuSession) optionalProtocolFlags() []string {
	for {
		value, ok := m.read("访问协议 [0=保持, 1=HTTPS, 2=HTTP]（默认 0）: ")
		if !ok || value == "" || value == "0" {
			return nil
		}
		switch value {
		case "1", "https", "HTTPS":
			return []string{"--https"}
		case "2", "http", "HTTP":
			return []string{"--http"}
		default:
			m.invalid()
		}
	}
}

func (m *menuSession) appendOptionalDNSOnly(args *[]string) {
	if !m.app.Cloudflare || containsArg(*args, "--http") {
		return
	}
	dnsOnly, ok := m.yesNo("是否启用 Cloudflare DNS-01？（否=保持当前设置）", false)
	if ok && dnsOnly {
		*args = append(*args, "--dns-only")
	}
}
