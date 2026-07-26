package caddyctl

import (
	"fmt"
	"strings"
)

func (m *menuSession) configMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 配置 / 导入 / 全局设置 ======
【配置】
1. 查看当前 Caddyfile
2. 校验配置
3. 应用配置（reload）
4. 校验并应用

【导入】
5. 替换导入（清空 sites.d）
6. 合并导入（--merge）

【全局设置】
7. 邮箱 / 超时 / 上游检查
`)
		if m.app.Cloudflare {
			fmt.Fprintln(m.app.Out, "\n【DNS】")
			fmt.Fprintln(m.app.Out, "8. Cloudflare DNS 管理")
		}
		fmt.Fprint(m.app.Out, "0. 返回上一级\n===================================\n")
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			m.run("config")
		case "2":
			m.run("validate")
		case "3":
			m.run("apply")
		case "4":
			if m.run("validate") {
				m.run("apply")
			}
		case "5":
			m.importConfig(false)
		case "6":
			m.importConfig(true)
		case "7":
			m.settingsMenu()
			continue
		case "8":
			if m.app.Cloudflare {
				m.cloudflareMenu()
				continue
			}
			m.invalid()
		default:
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) settingsMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 全局设置 ======
1. 设置 ACME 邮箱
2. 设置服务超时
3. 设置上游检查模式
0. 返回上一级
======================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			value, readOK := m.read("邮箱（回车清空）: ")
			if readOK {
				m.run("email", value)
			}
		case "2":
			value, readOK := m.required("超时秒数（1-600，default 恢复默认）: ")
			if readOK {
				m.run("timeout", value)
			}
		case "3":
			value, readOK := m.required("模式（warn 或 strict）: ")
			if readOK {
				m.run("upstream-mode", value)
			}
		default:
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) importConfig(merge bool) {
	path, ok := m.read("Caddyfile 路径（留空使用当前 Caddyfile）: ")
	if !ok {
		return
	}
	args := []string{"import"}
	if merge {
		args = append(args, "--merge")
	} else {
		confirmed, answered := m.yesNo("替换导入会重建 managed 目录，确认继续？", false)
		if !answered || !confirmed {
			fmt.Fprintln(m.app.Out, "已取消导入")
			return
		}
		args = append(args, "--force")
	}
	if path != "" {
		args = append(args, path)
	}
	m.run(args...)
}

func (m *menuSession) diagnosticsMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 诊断 / 证书 / 备份回滚 ======
【诊断】
1. 环境检查（doctor）
2. 实时日志
3. 证书诊断

【备份回滚】
4. 查看回滚快照
5. 回滚（上一步 / 指定快照）
0. 返回上一级
===================================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			m.run("doctor")
		case "2":
			m.run("logs")
		case "3":
			domain, readOK := m.required("要诊断的域名: ")
			if readOK {
				m.run("cert-check", domain)
			}
		case "4":
			limit, readOK := m.read("数量（默认 20，all 为全部）: ")
			if readOK && limit != "" {
				m.run("snapshots", limit)
			} else if readOK {
				m.run("snapshots", "20")
			}
		case "5":
			m.undoSnapshot()
		default:
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) undoSnapshot() {
	id, ok := m.read("快照 ID（留空为 latest）: ")
	if !ok {
		return
	}
	confirmed, ok := m.yesNo("回滚会替换当前 managed 配置，确认继续？", false)
	if !ok || !confirmed {
		fmt.Fprintln(m.app.Out, "已取消回滚")
		return
	}
	if id == "" {
		id = "latest"
	}
	m.run("undo", id)
}

func (m *menuSession) installMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== 安装与更新 ======
【安装】
1. 安装 / 初始化 Caddy
2. 安装本机 CLI（install-self）

【更新】
3. 更新 CLI 到滚动版 go-latest
4. 更新到指定固定版本
5. 更新 CLI 与 Caddy 二进制
0. 返回上一级
========================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			m.run("install")
		case "2":
			m.run("install-self")
		case "3":
			m.run("update", "--latest")
		case "4":
			version, readOK := m.required("Release tag（如 v0.1.0）: ")
			if readOK {
				m.run("update", "--ref", version)
			}
		case "5":
			confirmed, answered := m.yesNo("将更新 Caddy 二进制但不自动重启服务，确认继续？", false)
			if answered && confirmed {
				m.run("update", "--latest", "--binary")
			}
		default:
			m.invalid()
		}
		m.pause()
	}
}

func (m *menuSession) cloudflareMenu() {
	for {
		m.clearScreen()
		fmt.Fprint(m.app.Out, `
====== Cloudflare DNS 管理 ======
【状态】
1. 查看状态
2. 检查 Token

【凭据】
3. 设置 Token
4. 删除配置
0. 返回上一级
================================
`)
		choice, ok := m.read("选择: ")
		if !ok || choice == "0" {
			return
		}
		switch choice {
		case "1":
			m.run("cloudflare", "status")
		case "2":
			m.run("cloudflare", "check")
		case "3":
			token, readOK := m.required("Cloudflare API Token: ")
			if readOK {
				original := m.app.In
				m.app.In = strings.NewReader(token + "\n")
				m.run("cloudflare", "set")
				m.app.In = original
			}
		case "4":
			confirmed, answered := m.yesNo("确认删除 Cloudflare Token？", false)
			if answered && confirmed {
				m.run("cloudflare", "remove")
			}
		default:
			m.invalid()
		}
		m.pause()
	}
}
