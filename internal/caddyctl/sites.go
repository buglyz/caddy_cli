package caddyctl

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type siteFile struct {
	Path    string
	Data    string
	Kind    SiteKind
	Enabled bool
	Labels  []string
}

var siteHeaderRE = regexp.MustCompile(`(?m)^([^\s#][^{}]*)\s*\{\s*$`)

func (a *App) allSites() ([]siteFile, error) {
	patterns := []string{"*.conf", "*.conf.disabled"}
	var paths []string
	for _, pattern := range patterns {
		matches, err := matchingFiles(a.Paths.Sites, pattern)
		if err != nil {
			return nil, err
		}
		paths = append(paths, matches...)
	}
	sort.Strings(paths)
	result := make([]siteFile, 0, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		if len(strings.TrimSpace(string(data))) == 0 {
			continue
		}
		result = append(result, siteFile{Path: path, Data: string(data), Kind: detectSite(string(data)), Enabled: strings.HasSuffix(path, ".conf"), Labels: extractLabels(string(data))})
	}
	return result, nil
}

func extractLabels(data string) []string {
	match := siteHeaderRE.FindStringSubmatch(data)
	if len(match) < 2 {
		return nil
	}
	var labels []string
	for _, raw := range strings.Split(strings.TrimSpace(match[1]), ",") {
		label := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(raw), "http://"), "https://"))
		if label != "" {
			labels = append(labels, label)
		}
	}
	return labels
}

func (a *App) findSite(query string) (siteFile, error) {
	query = strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(query, "http://"), "https://"))
	if query == "" {
		return siteFile{}, fmt.Errorf("站点地址不能为空")
	}
	sites, err := a.allSites()
	if err != nil {
		return siteFile{}, err
	}
	normalized := sanitizeName(query)
	var fuzzy []siteFile
	for _, site := range sites {
		base := strings.TrimSuffix(strings.TrimSuffix(filepath.Base(site.Path), ".disabled"), ".conf")
		if strings.EqualFold(base, normalized) || containsAllLabels(site.Labels, query) {
			return site, nil
		}
		if strings.Contains(site.Data, query) {
			fuzzy = append(fuzzy, site)
		}
	}
	if len(fuzzy) == 1 {
		fmt.Fprintf(a.Err, "警告: 自动采用唯一模糊匹配: %s\n", filepath.Base(fuzzy[0].Path))
		return fuzzy[0], nil
	}
	if len(fuzzy) > 1 {
		return siteFile{}, fmt.Errorf("匹配到多个站点，请使用更精确的站点标识")
	}
	return siteFile{}, fmt.Errorf("未找到该站点")
}

func containsAllLabels(labels []string, query string) bool {
	set := map[string]bool{}
	for _, label := range labels {
		set[strings.ToLower(label)] = true
	}
	found := false
	for _, raw := range strings.Split(query, ",") {
		label := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(raw, "http://"), "https://"))
		if label == "" || !set[strings.ToLower(label)] {
			return false
		}
		found = true
	}
	return found
}

func extractQueryLabels(query string) []string {
	var labels []string
	for _, raw := range strings.Split(query, ",") {
		label := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(raw, "http://"), "https://"))
		if label != "" {
			labels = append(labels, strings.ToLower(label))
		}
	}
	return labels
}

func labelsOverlap(existing, requested []string) bool {
	set := make(map[string]bool, len(existing))
	for _, label := range existing {
		set[strings.ToLower(label)] = true
	}
	for _, label := range requested {
		if set[strings.ToLower(label)] {
			return true
		}
	}
	return false
}

func (a *App) sitePath(label string) (string, error) {
	base := sanitizeName(label)
	if base == "" {
		base = "site"
	}
	for i := 0; i <= 1000; i++ {
		name := base + ".conf"
		if i > 0 {
			name = fmt.Sprintf("%s-%d.conf", base, i)
		}
		path := filepath.Join(a.Paths.Sites, name)
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			if _, disabledErr := os.Stat(path + ".disabled"); errors.Is(disabledErr, os.ErrNotExist) {
				return path, nil
			}
		}
		if err == nil && containsAllLabels(extractLabels(string(data)), label) {
			return path, nil
		}
	}
	return "", fmt.Errorf("无法生成唯一文件名")
}

func (a *App) commitSite(path string, data []byte) error {
	old, oldErr := os.ReadFile(path)
	hadOld := oldErr == nil
	if oldErr != nil && !errors.Is(oldErr, os.ErrNotExist) {
		return oldErr
	}
	if err := atomicWrite(path, data, 0o644); err != nil {
		return err
	}
	if strings.HasSuffix(path, ".disabled") {
		return nil
	}
	if err := a.apply(); err != nil {
		if hadOld {
			_ = atomicWrite(path, old, 0o644)
		} else {
			_ = os.Remove(path)
		}
		return fmt.Errorf("配置应用失败，已回滚站点文件: %w", err)
	}
	return nil
}

func (a *App) removeSiteFile(site siteFile) error {
	old := []byte(site.Data)
	if err := os.Remove(site.Path); err != nil {
		return err
	}
	if !site.Enabled {
		return nil
	}
	if err := a.apply(); err != nil {
		_ = atomicWrite(site.Path, old, 0o644)
		return fmt.Errorf("配置应用失败，已回滚删除操作: %w", err)
	}
	return nil
}
