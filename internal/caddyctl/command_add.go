package caddyctl

import (
	"fmt"
	"net/url"
	"os"
	"strings"
)

type addFlags struct {
	positional                 []string
	scheme, path, allow        string
	spa, dnsTLS, skipDNS, open bool
	pathSeen, allowSeen        bool
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
				result.path, result.pathSeen = args[i], true
			} else {
				result.allow, result.allowSeen = args[i], true
			}
		case "--":
			result.positional = append(result.positional, args[i+1:]...)
			i = len(args)
		default:
			if strings.HasPrefix(args[i], "--") {
				return result, fmt.Errorf("未知 %s 参数: %s", command, args[i])
			}
			result.positional = append(result.positional, args[i])
		}
	}
	if result.scheme == "http" {
		if result.dnsTLS {
			return result, fmt.Errorf("--dns-only 不能与 --http 或 --no-ssl 同时使用")
		}
	}
	if result.allowSeen && result.open {
		return result, fmt.Errorf("--allow 与 --unsafe-open-proxy 不能同时使用")
	}
	return result, nil
}

// preAdd 统一 add 系列的公共前置：参数解析、arity、不支持 flag 拒绝、DNS 校验。
type preAddResult struct {
	flags addFlags
	label string
}

func (a *App) preAdd(args []string, command string, arity int, validLabel func(string) bool) (preAddResult, error) {
	var res preAddResult
	flags, err := parseAddFlags(args, command)
	if err != nil {
		return res, err
	}
	if len(flags.positional) != arity {
		return res, fmt.Errorf("参数数量不正确")
	}
	res.flags = flags
	res.label = strings.TrimSpace(flags.positional[0])
	if !validLabel(res.label) {
		return res, fmt.Errorf("站点地址不合法")
	}
	if !flags.skipDNS {
		if err := a.checkDNS(res.label); err != nil {
			return res, err
		}
	}
	return res, nil
}

func (a *App) addProxy(args []string) error {
	pre, err := a.preAdd(args, "add", 2, validSiteLabel)
	if err != nil {
		return err
	}
	flags := pre.flags
	if flags.spa || flags.allowSeen || flags.open {
		return fmt.Errorf("add 不支持 --spa、--allow 或 --unsafe-open-proxy")
	}
	if err := a.validateDNSFlag(flags.dnsTLS); err != nil {
		return err
	}
	label, port := pre.label, flags.positional[1]
	if !validPort(port) {
		return fmt.Errorf("端口不合法")
	}
	kind := SiteProxy
	if flags.pathSeen {
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
	pre, err := a.preAdd(args, "add-static", 2, validSiteLabel)
	if err != nil {
		return err
	}
	flags := pre.flags
	if flags.pathSeen || flags.allowSeen || flags.open {
		return fmt.Errorf("add-static 不支持 --path、--allow 或 --unsafe-open-proxy")
	}
	if err := a.validateDNSFlag(flags.dnsTLS); err != nil {
		return err
	}
	root := strings.TrimSpace(flags.positional[1])
	if !validStaticRoot(root) {
		return fmt.Errorf("静态目录不合法")
	}
	return a.createSite(pre.label, SiteStatic, SiteOptions{Label: pre.label, Root: root, SPA: flags.spa, Scheme: flags.scheme, DNSTLS: flags.dnsTLS})
}

func (a *App) addEmby(args []string) error {
	pre, err := a.preAdd(args, "add-emby", 2, validDomain)
	if err != nil {
		return err
	}
	flags := pre.flags
	if flags.pathSeen || flags.spa || flags.allowSeen || flags.open {
		return fmt.Errorf("add-emby 不支持 --path、--spa、--allow 或 --unsafe-open-proxy")
	}
	if err := a.validateDNSFlag(flags.dnsTLS); err != nil {
		return err
	}
	label, target := pre.label, strings.TrimSpace(flags.positional[1])
	if !strings.Contains(target, "://") {
		target = "https://" + target
	}
	if !validProxyTarget(target) {
		return fmt.Errorf("目标地址不合法")
	}
	u, _ := url.Parse(target)
	if u != nil && isPrivateHost(u.Host) {
		fmt.Fprintf(a.Err, "警告: 目标 %s 是内网/保留地址，请确保配置可信\n", target)
	}
	if !flags.skipDNS {
		if err := a.checkDNS(label); err != nil {
			return err
		}
	}
	return a.createSite(label, SiteEmby, SiteOptions{Label: label, Target: target, Scheme: flags.scheme, DNSTLS: flags.dnsTLS})
}

func (a *App) addGateway(args []string) error {
	pre, err := a.preAdd(args, "add-gateway", 1, validDomain)
	if err != nil {
		return err
	}
	flags := pre.flags
	if flags.pathSeen || flags.spa {
		return fmt.Errorf("add-gateway 不支持 --path 或 --spa")
	}
	if err := a.validateDNSFlag(flags.dnsTLS); err != nil {
		return err
	}
	label := pre.label
	var allow []string
	if flags.allowSeen {
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
	if err := a.validateDNSFlag(opts.DNSTLS); err != nil {
		return err
	}
	sites, err := a.allSites()
	if err != nil {
		return err
	}
	for _, site := range sites {
		if labelsOverlap(site.Labels, extractQueryLabels(label)) {
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

func (a *App) validateDNSFlag(enabled bool) error {
	if enabled && !a.Cloudflare {
		return fmt.Errorf("--dns-only 需要安装包含 dns.providers.cloudflare 的 Cloudflare 版 Caddy")
	}
	return nil
}
