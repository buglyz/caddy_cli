package caddyctl

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

func (a *App) listSites(embyOnly bool) error {
	sites, err := a.allSites()
	if err != nil {
		return err
	}
	if !embyOnly {
		fmt.Fprintln(a.Out, "===== 邮箱 =====")
		fmt.Fprintln(a.Out, valueOr(a.State.Email, "<未设置>"))
		fmt.Fprintln(a.Out, "\n===== 全局片段 =====")
		globals, globErr := matchingFiles(a.Paths.Globals, "*.inc")
		if globErr != nil {
			return globErr
		}
		if len(globals) == 0 {
			fmt.Fprintln(a.Out, "暂无")
		}
		for _, path := range globals {
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				return readErr
			}
			fmt.Fprintf(a.Out, "---- %s ----\n%s\n", filepath.Base(path), firstLines(string(data), 80))
		}
		fmt.Fprintln(a.Out, "\n===== 站点 =====")
	} else {
		fmt.Fprintln(a.Out, "===== Emby 配置 =====")
	}
	found, disabledFound := false, false
	for _, site := range sites {
		if embyOnly && site.Kind != SiteEmby && site.Kind != SiteGateway {
			continue
		}
		if !embyOnly && !site.Enabled {
			continue
		}
		status := map[bool]string{true: "启用", false: "禁用"}[site.Enabled]
		fmt.Fprintf(a.Out, "---- %s [%s / %s] ----\n%s\n", filepath.Base(site.Path), site.Kind, status, site.Data)
		found = true
	}
	if !found {
		fmt.Fprintln(a.Out, "暂无")
	}
	if !embyOnly {
		if a.Cloudflare {
			fmt.Fprintln(a.Out, "\n===== Cloudflare =====")
			if _, err := os.Stat(a.Paths.CloudflareEnv); err == nil {
				fmt.Fprintln(a.Out, "状态: 已配置")
			} else {
				fmt.Fprintln(a.Out, "状态: 未配置")
			}
		}
		fmt.Fprintln(a.Out, "\n===== 已禁用站点 =====")
		for _, site := range sites {
			if site.Enabled {
				continue
			}
			fmt.Fprintf(a.Out, "---- %s [%s / 禁用] ----\n%s\n", filepath.Base(site.Path), site.Kind, site.Data)
			disabledFound = true
		}
		if !disabledFound {
			fmt.Fprintln(a.Out, "暂无")
		}
	}
	return nil
}

func firstLines(data string, limit int) string {
	lines := strings.Split(strings.TrimRight(data, "\n"), "\n")
	if len(lines) > limit {
		lines = lines[:limit]
	}
	return strings.Join(lines, "\n")
}

func (a *App) removeSite(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("用法: c rm <域名>")
	}
	site, err := a.findSite(args[0])
	if err != nil {
		return err
	}
	if err := a.removeSiteFile(site); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "已删除: %s\n", args[0])
	return nil
}

func (a *App) removeEmbySite(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("用法: c rm-emby <域名>")
	}
	site, err := a.findSite(args[0])
	if err != nil {
		return err
	}
	if site.Kind != SiteEmby && site.Kind != SiteGateway {
		return fmt.Errorf("该配置不是 Emby 或网关: %s", args[0])
	}
	if err := a.removeSiteFile(site); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "已删除: %s\n", args[0])
	return nil
}

func (a *App) toggleSite(args []string, enable bool) error {
	if len(args) != 1 {
		return fmt.Errorf("用法: c %s <域名>", map[bool]string{true: "enable", false: "disable"}[enable])
	}
	site, err := a.findSite(args[0])
	if err != nil {
		return err
	}
	if site.Enabled == enable {
		return fmt.Errorf("该站点已经是%s状态", map[bool]string{true: "启用", false: "禁用"}[enable])
	}
	target := strings.TrimSuffix(site.Path, ".disabled")
	if !enable {
		target = site.Path + ".disabled"
	}
	if _, err := os.Stat(target); err == nil {
		return fmt.Errorf("目标文件已存在: %s", target)
	}
	if err := os.Rename(site.Path, target); err != nil {
		return err
	}
	if err := a.apply(); err != nil {
		_ = os.Rename(target, site.Path)
		return fmt.Errorf("应用失败，已回滚状态切换: %w", err)
	}
	fmt.Fprintf(a.Out, "已%s: %s\n", map[bool]string{true: "启用", false: "禁用"}[enable], args[0])
	return nil
}

type setFlags struct {
	query, port, path, root, target, allow string
	scheme, spa                            *string
	dnsTLS, open, allowSeen                bool
	portSeen, pathSeen, rootSeen           bool
	targetSeen                             bool
}

func parseSetFlags(args []string, command string) (setFlags, error) {
	var result setFlags
	if len(args) == 0 {
		return result, fmt.Errorf("用法: c %s <域名> [参数]", command)
	}
	result.query = args[0]
	for i := 1; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--http", "--no-ssl":
			v := "http"
			result.scheme = &v
		case "--https":
			v := "https"
			result.scheme = &v
		case "--spa":
			v := "on"
			result.spa = &v
		case "--no-spa":
			v := "off"
			result.spa = &v
		case "--dns-only":
			result.dnsTLS = true
		case "--unsafe-open-proxy":
			result.open = true
		case "--port", "--path", "--root", "--target", "--allow":
			if i+1 >= len(args) {
				return result, fmt.Errorf("%s 需要参数", arg)
			}
			i++
			switch arg {
			case "--port":
				result.port, result.portSeen = args[i], true
			case "--path":
				result.path, result.pathSeen = args[i], true
			case "--root":
				result.root, result.rootSeen = args[i], true
			case "--target":
				result.target, result.targetSeen = args[i], true
			case "--allow":
				result.allow, result.allowSeen = args[i], true
			}
		default:
			return result, fmt.Errorf("未知 %s 参数: %s", command, arg)
		}
	}
	if result.open && result.allowSeen {
		return result, fmt.Errorf("--allow 与 --unsafe-open-proxy 不能同时使用")
	}
	if result.dnsTLS && result.scheme != nil && *result.scheme == "http" {
		return result, fmt.Errorf("--dns-only 不能与 --http 或 --no-ssl 同时使用")
	}
	return result, nil
}

func (flags setFlags) hasChanges() bool {
	return flags.scheme != nil || flags.spa != nil || flags.dnsTLS || flags.open || flags.allowSeen ||
		flags.portSeen || flags.pathSeen || flags.rootSeen || flags.targetSeen
}

func optionsFromSite(site siteFile) (SiteOptions, error) {
	opts := SiteOptions{Scheme: siteScheme(site.Data), DNSTLS: strings.Contains(site.Data, "dns cloudflare")}
	if len(site.Labels) == 0 {
		return opts, fmt.Errorf("无法解析站点标签")
	}
	opts.Label = strings.Join(site.Labels, ", ")
	if opts.Scheme == "http" {
		opts.Scheme, opts.DNSTLS = "http", false
	}
	reverseRE := regexp.MustCompile(`(?m)^\s*reverse_proxy\s+([^\s{]+)`)
	if match := reverseRE.FindStringSubmatch(site.Data); len(match) > 1 {
		opts.Target = match[1]
		hostport := strings.TrimPrefix(strings.TrimPrefix(opts.Target, "http://"), "https://")
		hostport = strings.Split(hostport, "/")[0]
		if index := strings.LastIndex(hostport, ":"); index >= 0 {
			opts.Port = hostport[index+1:]
		}
	}
	if match := regexp.MustCompile(`(?m)^\s*uri strip_prefix\s+(\S+)`).FindStringSubmatch(site.Data); len(match) > 1 {
		opts.Path = match[1]
	}
	if match := regexp.MustCompile(`(?m)^\s*root \*\s+(?:"((?:\\.|[^"])*)"|(\S+))`).FindStringSubmatch(site.Data); len(match) > 2 {
		opts.Root = match[1]
		if opts.Root == "" {
			opts.Root = match[2]
		}
		opts.Root = strings.ReplaceAll(strings.ReplaceAll(opts.Root, `\"`, `"`), `\\`, `\`)
	}
	opts.SPA = strings.Contains(site.Data, "try_files {path} /index.html")
	if site.Kind == SiteGateway {
		if match := regexp.MustCompile(`(?m)^# 上游限制: 仅允许: (.+)$`).FindStringSubmatch(site.Data); len(match) > 1 {
			opts.Allow, _ = parseGatewayAllow(strings.TrimSpace(match[1]))
		} else {
			opts.UnsafeGateway = true
		}
	}
	return opts, nil
}

func siteScheme(data string) string {
	match := siteHeaderRE.FindStringSubmatch(data)
	if len(match) > 1 {
		for _, label := range strings.Split(match[1], ",") {
			if strings.HasPrefix(strings.TrimSpace(label), "http://") {
				return "http"
			}
		}
	}
	return "https"
}

func mergeSetFlags(opts SiteOptions, flags setFlags) (SiteOptions, error) {
	if flags.scheme != nil {
		opts.Scheme = *flags.scheme
	}
	if opts.Scheme == "http" {
		opts.DNSTLS = false
	} else if flags.dnsTLS {
		opts.DNSTLS = true
	}
	if flags.portSeen {
		if !validPort(flags.port) {
			return opts, fmt.Errorf("端口不合法")
		}
		opts.Port = flags.port
	}
	if flags.pathSeen {
		switch flags.path {
		case "none", "off", "disable":
			opts.Path = ""
		default:
			flags.path = normalizePathPrefix(flags.path)
			if !validPathPrefix(flags.path) {
				return opts, fmt.Errorf("路径前缀不合法")
			}
			opts.Path = flags.path
		}
	}
	if flags.rootSeen {
		if !validStaticRoot(flags.root) {
			return opts, fmt.Errorf("静态目录不合法")
		}
		opts.Root = flags.root
	}
	if flags.targetSeen {
		if !strings.Contains(flags.target, "://") {
			flags.target = opts.Scheme + "://" + flags.target
		}
		if !validProxyTarget(flags.target) {
			return opts, fmt.Errorf("目标地址不合法")
		}
		opts.Target = flags.target
	}
	if flags.spa != nil {
		opts.SPA = *flags.spa == "on"
	}
	if flags.allowSeen {
		allow, err := parseGatewayAllow(flags.allow)
		if err != nil {
			return opts, err
		}
		opts.Allow, opts.UnsafeGateway = allow, false
	}
	if flags.open {
		opts.Allow, opts.UnsafeGateway = nil, true
	}
	return opts, nil
}
