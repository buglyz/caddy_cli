package caddyctl

import (
	"fmt"
	"os"
	"strings"
)

type addFlags struct {
	positional                 []string
	scheme, path, allow        string
	spa, dnsTLS, skipDNS, open bool
}

func parseAddFlags(args []string, command string) (addFlags, error) {
	result := addFlags{scheme: "https"}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--http", "--no-ssl":
			result.scheme = "http"
		case "--https":
			result.scheme = "https"
		case "--dns-only":
			result.dnsTLS = true
		case "--skip-dns-check":
			result.skipDNS = true
		case "--spa":
			result.spa = true
		case "--unsafe-open-proxy":
			result.open = true
		case "--path", "--allow":
			if i+1 >= len(args) {
				return result, fmt.Errorf("%s 需要参数", args[i])
			}
			i++
			if args[i-1] == "--path" {
				result.path = args[i]
			} else {
				result.allow = args[i]
			}
		case "--":
			result.positional = append(result.positional, args[i+1:]...)
			return result, nil
		default:
			if strings.HasPrefix(args[i], "--") {
				return result, fmt.Errorf("未知 %s 参数: %s", command, args[i])
			}
			result.positional = append(result.positional, args[i])
		}
	}
	if result.scheme == "http" {
		result.dnsTLS = false
	}
	if result.allow != "" && result.open {
		return result, fmt.Errorf("--allow 与 --unsafe-open-proxy 不能同时使用")
	}
	return result, nil
}

func (a *App) addProxy(args []string) error {
	flags, err := parseAddFlags(args, "add")
	if err != nil {
		return err
	}
	if len(flags.positional) < 2 {
		return fmt.Errorf("用法: c add <域名> <端口> [--path <前缀>]")
	}
	label, port := strings.TrimSpace(flags.positional[0]), flags.positional[1]
	if !validSiteLabel(label) {
		return fmt.Errorf("站点地址不合法")
	}
	if !validPort(port) {
		return fmt.Errorf("端口不合法")
	}
	kind := SiteProxy
	if flags.path != "" {
		flags.path = normalizePathPrefix(flags.path)
		if !validPathPrefix(flags.path) {
			return fmt.Errorf("路径前缀不合法，请使用类似 /api 的形式")
		}
		kind = SitePath
	}
	if !flags.skipDNS {
		if err := a.checkDNS(label); err != nil {
			return err
		}
	}
	return a.createSite(label, kind, SiteOptions{Label: label, Port: port, Path: flags.path, Scheme: flags.scheme, DNSTLS: flags.dnsTLS})
}

func (a *App) addStatic(args []string) error {
	flags, err := parseAddFlags(args, "add-static")
	if err != nil {
		return err
	}
	if len(flags.positional) < 2 {
		return fmt.Errorf("用法: c add-static <域名> <目录> [--spa]")
	}
	label, root := strings.TrimSpace(flags.positional[0]), strings.TrimSpace(flags.positional[1])
	if !validSiteLabel(label) || root == "" || strings.ContainsAny(root, "\r\n") {
		return fmt.Errorf("站点地址或静态目录不合法")
	}
	if !flags.skipDNS {
		if err := a.checkDNS(label); err != nil {
			return err
		}
	}
	return a.createSite(label, SiteStatic, SiteOptions{Label: label, Root: root, SPA: flags.spa, Scheme: flags.scheme, DNSTLS: flags.dnsTLS})
}

func (a *App) addEmby(args []string) error {
	flags, err := parseAddFlags(args, "add-emby")
	if err != nil {
		return err
	}
	if len(flags.positional) < 2 {
		return fmt.Errorf("用法: c add-emby <域名> <目标>")
	}
	label, target := strings.TrimSpace(flags.positional[0]), strings.TrimSpace(flags.positional[1])
	if !validDomain(label) {
		return fmt.Errorf("域名不合法")
	}
	if !strings.Contains(target, "://") {
		target = "https://" + target
	}
	if !validProxyTarget(target) {
		return fmt.Errorf("目标地址不合法")
	}
	if !flags.skipDNS {
		if err := a.checkDNS(label); err != nil {
			return err
		}
	}
	return a.createSite(label, SiteEmby, SiteOptions{Label: label, Target: target, Scheme: flags.scheme, DNSTLS: flags.dnsTLS})
}

func (a *App) addGateway(args []string) error {
	flags, err := parseAddFlags(args, "add-gateway")
	if err != nil {
		return err
	}
	if len(flags.positional) < 1 {
		return fmt.Errorf("用法: c add-gateway <域名> --allow <host:port,...>")
	}
	label := strings.TrimSpace(flags.positional[0])
	if !validDomain(label) {
		return fmt.Errorf("域名不合法")
	}
	var allow []string
	if flags.allow != "" {
		allow, err = parseGatewayAllow(flags.allow)
		if err != nil {
			return err
		}
	} else if !flags.open {
		return fmt.Errorf("add-gateway 默认需要 --allow；确需开放任意上游时使用 --unsafe-open-proxy")
	}
	if !flags.skipDNS {
		if err := a.checkDNS(label); err != nil {
			return err
		}
	}
	return a.createSite(label, SiteGateway, SiteOptions{Label: label, Scheme: flags.scheme, DNSTLS: flags.dnsTLS, Allow: allow, UnsafeGateway: flags.open})
}

func (a *App) createSite(label string, kind SiteKind, opts SiteOptions) error {
	sites, err := a.allSites()
	if err != nil {
		return err
	}
	for _, site := range sites {
		if containsAllLabels(site.Labels, label) {
			return fmt.Errorf("配置已存在，请使用 c set 修改")
		}
	}
	path, err := a.sitePath(label)
	if err != nil {
		return err
	}
	if _, err := os.Stat(path + ".disabled"); err == nil {
		return fmt.Errorf("禁用配置已存在: %s", path+".disabled")
	}
	if !a.Cloudflare {
		opts.DNSTLS = false
	}
	data, err := renderSite(opts, kind)
	if err != nil {
		return err
	}
	if err := a.commitSite(path, []byte(data)); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "已添加%s: %s\n", kind, label)
	return nil
}
