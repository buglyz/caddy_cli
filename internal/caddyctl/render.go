package caddyctl

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type SiteKind string

const (
	SiteProxy   SiteKind = "反代站点"
	SitePath    SiteKind = "路径反代"
	SiteStatic  SiteKind = "静态站点"
	SiteEmby    SiteKind = "Emby反代"
	SiteGateway SiteKind = "网关"
	SiteUnknown SiteKind = "未知类型"
)

type SiteOptions struct {
	Label, Scheme, Port, Path, Root, Target string
	SPA, DNSTLS                             bool
	Allow                                   []string
	UnsafeGateway                           bool
}

func (a *App) renderManaged() ([]byte, error) {
	var out bytes.Buffer
	out.WriteString("# managed by caddyctl\n\n")
	globals, err := matchingFiles(a.Paths.Globals, "*.inc")
	if err != nil {
		return nil, err
	}
	if a.State.Email != "" || len(globals) > 0 {
		out.WriteString("{\n")
		if a.State.Email != "" {
			fmt.Fprintf(&out, "    email %s\n", a.State.Email)
		}
		for _, path := range globals {
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				return nil, readErr
			}
			for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
				if strings.TrimSpace(line) == "" {
					out.WriteByte('\n')
				} else {
					fmt.Fprintf(&out, "    %s\n", line)
				}
			}
		}
		out.WriteString("}\n\n")
	}
	sites, err := matchingFiles(a.Paths.Sites, "*.conf")
	if err != nil {
		return nil, err
	}
	for _, path := range sites {
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil, readErr
		}
		out.Write(bytes.TrimRight(data, "\n"))
		out.WriteString("\n\n")
	}
	return out.Bytes(), nil
}

func matchingFiles(dir, pattern string) ([]string, error) {
	files, err := filepath.Glob(filepath.Join(dir, pattern))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
}

func renderSite(opts SiteOptions, kind SiteKind) (string, error) {
	label := formatLabels(opts.Label, opts.Scheme)
	tls := ""
	if opts.Scheme != "http" && opts.DNSTLS {
		tls = "    tls {\n        dns cloudflare {env.CLOUDFLARE_API_TOKEN}\n    }\n"
	}
	switch kind {
	case SiteProxy:
		target := "127.0.0.1:" + opts.Port
		if opts.Scheme == "http" {
			target = "http://" + target
		}
		return fmt.Sprintf("%s {\n    encode zstd gzip\n%s    reverse_proxy %s\n}\n", label, tls, target), nil
	case SitePath:
		matcher := "@path_" + sanitizeName(primaryLabel(opts.Label)) + "_" + sanitizeName(opts.Path)
		target := "127.0.0.1:" + opts.Port
		if opts.Scheme == "http" {
			target = "http://" + target
		}
		return fmt.Sprintf("%s {\n    encode zstd gzip\n%s    %s path %s %s/*\n    handle %s {\n        uri strip_prefix %s\n        reverse_proxy %s\n    }\n    handle {\n        respond \"Not Found\" 404\n    }\n}\n", label, tls, matcher, opts.Path, opts.Path, matcher, opts.Path, target), nil
	case SiteStatic:
		spa := ""
		if opts.SPA {
			spa = "    try_files {path} /index.html\n"
		}
		return fmt.Sprintf("%s {\n    encode zstd gzip\n%s    root * %s\n%s    file_server\n}\n", label, tls, quoteCaddy(opts.Root), spa), nil
	case SiteEmby:
		return fmt.Sprintf("%s {\n%s    reverse_proxy %s {\n        header_up Host {upstream_hostport}\n    }\n}\n", label, tls, opts.Target), nil
	case SiteGateway:
		return renderGateway(opts, tls)
	default:
		return "", fmt.Errorf("未知站点类型: %s", kind)
	}
}

func formatLabels(label, scheme string) string {
	parts := strings.Split(label, ",")
	for i, part := range parts {
		part = strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(part), "http://"), "https://"))
		if scheme == "http" {
			part = "http://" + part
		}
		parts[i] = part
	}
	return strings.Join(parts, ", ")
}

func primaryLabel(label string) string {
	first, _, _ := strings.Cut(label, ",")
	return strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(first, "http://"), "https://"))
}

func sanitizeName(value string) string {
	replacer := strings.NewReplacer("/", "_", ":", "_", " ", "_", ",", "_")
	value = replacer.Replace(value)
	return regexp.MustCompile(`[^A-Za-z0-9._-]`).ReplaceAllString(value, "")
}

func quoteCaddy(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	return `"` + value + `"`
}

func detectSite(data string) SiteKind {
	switch {
	case strings.Contains(data, "通用反代网关"):
		return SiteGateway
	case regexp.MustCompile(`(?m)^\s*file_server(?:\s|$)`).MatchString(data):
		return SiteStatic
	case strings.Contains(data, "uri strip_prefix") && regexp.MustCompile(`(?m)^\s*@path_.* path `).MatchString(data):
		return SitePath
	case strings.Contains(data, "header_up Host {upstream_hostport}"):
		return SiteEmby
	case regexp.MustCompile(`(?m)^\s*reverse_proxy `).MatchString(data):
		return SiteProxy
	default:
		return SiteUnknown
	}
}
