package caddyctl

import (
	"fmt"
	"regexp"
	"strings"
)

func (a *App) setSite(args []string) error {
	flags, err := parseSetFlags(args, "set")
	if err != nil {
		return err
	}
	site, err := a.findSite(flags.query)
	if err != nil {
		return err
	}
	switch site.Kind {
	case SiteStatic:
		return a.updateSite(site, flags, SiteStatic)
	case SiteEmby:
		return a.updateSite(site, flags, SiteEmby)
	case SiteGateway:
		return fmt.Errorf("该配置是通用反代网关，请使用 c set-gateway")
	case SiteProxy, SitePath:
		kind := site.Kind
		if flags.path != "" {
			if flags.path == "none" || flags.path == "off" || flags.path == "disable" {
				kind = SiteProxy
			} else {
				kind = SitePath
			}
		}
		return a.updateSite(site, flags, kind)
	default:
		return fmt.Errorf("无法修改未知类型站点")
	}
}

func (a *App) setStatic(args []string) error {
	flags, err := parseSetFlags(args, "set-static")
	if err != nil {
		return err
	}
	site, err := a.findSite(flags.query)
	if err != nil {
		return err
	}
	if site.Kind != SiteStatic {
		return fmt.Errorf("该配置不是静态站点: %s", flags.query)
	}
	return a.updateSite(site, flags, SiteStatic)
}

func (a *App) setEmby(args []string) error {
	flags, err := parseSetFlags(args, "set-emby")
	if err != nil {
		return err
	}
	site, err := a.findSite(flags.query)
	if err != nil {
		return err
	}
	if site.Kind != SiteEmby {
		return fmt.Errorf("该配置不是 Emby 固定反代: %s", flags.query)
	}
	return a.updateSite(site, flags, SiteEmby)
}

func (a *App) setGateway(args []string) error {
	flags, err := parseSetFlags(args, "set-gateway")
	if err != nil {
		return err
	}
	site, err := a.findSite(flags.query)
	if err != nil {
		return err
	}
	if site.Kind != SiteGateway {
		return fmt.Errorf("该配置不是通用反代网关: %s", flags.query)
	}
	return a.updateSite(site, flags, SiteGateway)
}

func (a *App) updateSite(site siteFile, flags setFlags, kind SiteKind) error {
	if !flags.hasChanges() {
		return fmt.Errorf("未提供任何修改参数")
	}
	if err := validateSetFlags(flags, kind); err != nil {
		return err
	}
	if flags.dnsTLS && !a.Cloudflare {
		return fmt.Errorf("--dns-only 需要安装包含 dns.providers.cloudflare 的 Cloudflare 版 Caddy")
	}
	opts, err := optionsFromSite(site)
	if err != nil {
		return err
	}
	opts, err = mergeSetFlags(opts, flags)
	if err != nil {
		return err
	}
	if kind == SiteProxy || kind == SitePath {
		if !validPort(opts.Port) {
			return fmt.Errorf("无法解析反代端口，请手工检查站点文件")
		}
	}
	if kind == SiteStatic && opts.Root == "" {
		return fmt.Errorf("无法解析静态目录")
	}
	if kind == SiteEmby && !validProxyTarget(opts.Target) {
		return fmt.Errorf("无法解析 Emby 目标")
	}
	if kind == SiteGateway && len(opts.Allow) == 0 && !opts.UnsafeGateway {
		return fmt.Errorf("网关必须配置 allow-list 或显式开放代理")
	}
	block, err := renderSite(opts, kind)
	if err != nil {
		return err
	}
	extras := extractCustomDirectives(site.Data)
	if kind == SiteEmby || kind == SiteGateway {
		extras = whitelistCustomDirectives(extras)
	}
	if strings.TrimSpace(extras) != "" {
		block = injectCustomDirectives(block, extras)
		fmt.Fprintln(a.Out, "已保留站点自定义指令（header/basic_auth/log）")
	}
	if err := a.commitSite(site.Path, []byte(block)); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "已更新站点: %s\n", opts.Label)
	return nil
}

func validateSetFlags(flags setFlags, kind SiteKind) error {
	switch kind {
	case SiteProxy, SitePath:
		if flags.rootSeen || flags.targetSeen || flags.spa != nil || flags.allowSeen || flags.open {
			return fmt.Errorf("反代站点仅支持 --port、--path、--http、--https 和 --dns-only")
		}
	case SiteStatic:
		if flags.portSeen || flags.pathSeen || flags.targetSeen || flags.allowSeen || flags.open {
			return fmt.Errorf("静态站点仅支持 --root、--spa、--no-spa、--http、--https 和 --dns-only")
		}
	case SiteEmby:
		if flags.portSeen || flags.pathSeen || flags.rootSeen || flags.spa != nil || flags.allowSeen || flags.open {
			return fmt.Errorf("Emby 站点仅支持 --target、--http、--https 和 --dns-only")
		}
	case SiteGateway:
		if flags.portSeen || flags.pathSeen || flags.rootSeen || flags.targetSeen || flags.spa != nil {
			return fmt.Errorf("网关仅支持 --allow、--unsafe-open-proxy、--http、--https 和 --dns-only")
		}
	}
	return nil
}

var templateDirectiveRE = regexp.MustCompile(`^(?:encode\b|reverse_proxy\b|uri\s+strip_prefix\b|tls\b|file_server\b|try_files\b|root\s+\*|request_body\b|route\b|respond\b|@path_|handle\b|rewrite\b|transport\b|header_up\s+(?:Host|X-Real-IP)\b|header_down\b|flush_interval\b|to\b|#)`)

func extractCustomDirectives(data string) string {
	lines := strings.Split(data, "\n")
	if len(lines) < 3 {
		return ""
	}
	depth := 0
	var out []string
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		trimmed := strings.TrimSpace(line)
		if i == 0 || trimmed == "" {
			depth += strings.Count(line, "{") - strings.Count(line, "}")
			continue
		}
		before := depth
		delta := strings.Count(line, "{") - strings.Count(line, "}")
		depth += delta
		if before != 1 || trimmed == "}" || templateDirectiveRE.MatchString(trimmed) {
			continue
		}
		out = append(out, line)
		if delta > 0 {
			blockDepth := delta
			for blockDepth > 0 && i+1 < len(lines) {
				i++
				nested := lines[i]
				out = append(out, nested)
				nestedDelta := strings.Count(nested, "{") - strings.Count(nested, "}")
				blockDepth += nestedDelta
				depth += nestedDelta
			}
		}
	}
	return strings.Join(out, "\n")
}

func whitelistCustomDirectives(extras string) string {
	var out []string
	lines := strings.Split(extras, "\n")
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "header ") || strings.HasPrefix(trimmed, "basic_auth ") ||
			strings.HasPrefix(trimmed, "basicauth ") || strings.HasPrefix(trimmed, "log ") {
			out = append(out, line)
			depth := strings.Count(line, "{") - strings.Count(line, "}")
			for depth > 0 && i+1 < len(lines) {
				i++
				out = append(out, lines[i])
				depth += strings.Count(lines[i], "{") - strings.Count(lines[i], "}")
			}
		}
	}
	return strings.Join(out, "\n")
}

func injectCustomDirectives(block, extras string) string {
	trimmed := strings.TrimRight(block, "\n")
	index := strings.LastIndex(trimmed, "}")
	if index < 0 {
		return block
	}
	return trimmed[:index] + strings.TrimRight(extras, "\n") + "\n" + trimmed[index:] + "\n"
}
