package caddyctl

import (
	"bufio"
	"fmt"
)

func (a *App) interactiveAddCommand(kind string) error {
	m := &menuSession{app: a, reader: bufio.NewReader(a.In), silent: true}
	switch kind {
	case "proxy":
		m.addProxy()
	case "static":
		m.addStatic()
	case "emby":
		m.addEmby()
	case "gateway":
		m.addGateway()
	default:
		return fmt.Errorf("未知交互添加类型: %s", kind)
	}
	return m.actionError()
}

func (m *menuSession) addProxy() {
	label, ok := m.required("站点地址（如 example.com）: ")
	if !ok {
		return
	}
	port, ok := m.required("本地端口: ")
	if !ok {
		return
	}
	path, ok := m.read("路径前缀（留空为整站反代，如 /api）: ")
	if !ok {
		return
	}
	args := []string{"add", label, port}
	if path != "" {
		args = append(args, "--path", path)
	}
	args = append(args, m.protocolFlags()...)
	args, ok = m.addTLSAndDNSFlags(args)
	if ok {
		m.run(args...)
	}
}

func (m *menuSession) addStatic() {
	label, ok := m.required("站点地址（如 static.example.com）: ")
	if !ok {
		return
	}
	root, ok := m.required("静态目录路径: ")
	if !ok {
		return
	}
	args := []string{"add-static", label, root}
	spa, ok := m.yesNo("是否按单页应用启用 try_files /index.html？", false)
	if !ok {
		return
	}
	if spa {
		args = append(args, "--spa")
	}
	args = append(args, m.protocolFlags()...)
	args, ok = m.addTLSAndDNSFlags(args)
	if ok {
		m.run(args...)
	}
}

func (m *menuSession) addEmby() {
	label, ok := m.required("请输入你的域名: ")
	if !ok {
		return
	}
	target, ok := m.required("目标 Emby 地址（如 https://emby.example.com:443）: ")
	if !ok {
		return
	}
	args := append([]string{"add-emby", label, target}, m.protocolFlags()...)
	args, ok = m.addTLSAndDNSFlags(args)
	if ok {
		m.run(args...)
	}
}

func (m *menuSession) addGateway() {
	label, ok := m.required("请输入网关域名: ")
	if !ok {
		return
	}
	allow, ok := m.read("允许的上游 host:port 列表（多个用逗号分隔）: ")
	if !ok {
		return
	}
	args := []string{"add-gateway", label}
	if allow == "" {
		open, answered := m.yesNo("未配置 allow-list 会创建开放代理，确认继续？", false)
		if !answered || !open {
			fmt.Fprintln(m.app.Err, "错误: 已取消；网关默认必须配置 allow-list")
			return
		}
		args = append(args, "--unsafe-open-proxy")
	} else {
		args = append(args, "--allow", allow)
	}
	args = append(args, m.protocolFlags()...)
	args, ok = m.addTLSAndDNSFlags(args)
	if ok {
		m.run(args...)
	}
}

func (m *menuSession) protocolFlags() []string {
	for {
		value, ok := m.read("访问协议 [1=HTTPS, 2=HTTP]（默认 1）: ")
		if !ok {
			return nil
		}
		switch value {
		case "", "1", "https", "HTTPS":
			return []string{"--https"}
		case "2", "http", "HTTP":
			return []string{"--http"}
		default:
			m.invalid()
		}
	}
}

func (m *menuSession) addTLSAndDNSFlags(args []string) ([]string, bool) {
	if m.app.Cloudflare && !containsArg(args, "--http") {
		dnsOnly, ok := m.yesNo("是否为此站点使用 Cloudflare DNS-01？", false)
		if !ok {
			return nil, false
		}
		if dnsOnly {
			args = append(args, "--dns-only")
		}
	}
	skip, ok := m.yesNo("是否跳过域名指向本机的 DNS 检查？", false)
	if !ok {
		return nil, false
	}
	if skip {
		args = append(args, "--skip-dns-check")
	}
	return args, true
}

func containsArg(args []string, wanted string) bool {
	for _, arg := range args {
		if arg == wanted {
			return true
		}
	}
	return false
}
