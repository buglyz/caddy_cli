package caddyctl

import (
	"bufio"
	"fmt"
)

func (a *App) interactiveSetCommand(command, query string) error {
	m := &menuSession{app: a, reader: bufio.NewReader(a.In), silent: true}
	if query == "" {
		var ok bool
		query, ok = m.required("输入要编辑的站点地址: ")
		if !ok {
			return nil
		}
	}
	if command == "set" {
		site, err := a.findSite(query)
		if err != nil {
			return err
		}
		switch site.Kind {
		case SiteStatic:
			m.modifyStaticLabel(query)
		case SiteEmby:
			m.modifyEmbyLabel(query)
		case SiteGateway:
			m.modifyGatewayLabel(query)
		case SiteProxy, SitePath:
			m.modifyProxyLabel(query)
		default:
			return fmt.Errorf("无法修改未知类型站点")
		}
	} else {
		switch command {
		case "set-static":
			m.modifyStaticLabel(query)
		case "set-emby":
			m.modifyEmbyLabel(query)
		case "set-gateway":
			m.modifyGatewayLabel(query)
		default:
			return fmt.Errorf("未知交互修改命令: %s", command)
		}
	}
	return m.lastErr
}

func (a *App) readRequiredInput(prompt string) (string, error) {
	m := &menuSession{app: a, reader: bufio.NewReader(a.In), silent: true}
	value, ok := m.required(prompt)
	if !ok {
		return "", fmt.Errorf("未读取到输入")
	}
	return value, nil
}
