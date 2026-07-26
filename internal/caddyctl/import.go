package caddyctl

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type caddyBlock struct {
	Header string
	Text   string
}

func (a *App) importCommand(args []string) error {
	merge, force, source := false, false, a.Paths.Caddyfile
	var positional []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--merge":
			merge = true
		case "--force":
			force = true
		case "--":
			positional = append(positional, args[i+1:]...)
			i = len(args)
		default:
			if strings.HasPrefix(args[i], "--") {
				return fmt.Errorf("未知 import 参数: %s", args[i])
			}
			positional = append(positional, args[i])
		}
	}
	if len(positional) > 1 {
		return fmt.Errorf("用法: c import [--merge] [--force] [Caddyfile路径]")
	}
	if len(positional) == 1 {
		source = positional[0]
	}
	data, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("读取导入源: %w", err)
	}
	blocks, err := splitCaddyBlocks(string(data))
	if err != nil {
		return err
	}
	existing, err := a.allSites()
	if err != nil {
		return err
	}
	if len(existing) > 0 && !merge && !force && !truthy(os.Getenv("CADDYCTL_IMPORT_FORCE")) {
		return fmt.Errorf("已有 managed 站点；覆盖请加 --force，合并请加 --merge")
	}
	action := "import"
	if merge {
		action = "import-merge"
	}
	return a.mutate(action, func() error {
		return a.applyImportedBlocks(blocks, merge)
	})
}

func splitCaddyBlocks(text string) ([]caddyBlock, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	var result []caddyBlock
	var current, currentCode []string
	var lexer caddyLexer
	depth, started := 0, false
	for _, line := range lines {
		clean := lexer.code(line)
		if !started && strings.TrimSpace(clean) == "" {
			continue
		}
		if !started {
			started = true
		}
		current = append(current, line)
		currentCode = append(currentCode, clean)
		depth += strings.Count(clean, "{") - strings.Count(clean, "}")
		if depth < 0 {
			return nil, fmt.Errorf("Caddyfile 大括号不匹配")
		}
		if depth == 0 && !lexer.quoted() {
			header := ""
			for _, candidate := range currentCode {
				if trimmed := strings.TrimSpace(candidate); trimmed != "" {
					header = trimmed
					break
				}
			}
			result = append(result, caddyBlock{Header: header, Text: strings.TrimRight(strings.Join(current, "\n"), "\n") + "\n"})
			current, currentCode, started = nil, nil, false
		}
	}
	if started || depth != 0 || lexer.quoted() {
		return nil, fmt.Errorf("Caddyfile 引号或大括号不完整")
	}
	return result, nil
}

type caddyLexer struct {
	inBacktick bool
	inDouble   bool
	escaped    bool
}

func (l *caddyLexer) code(line string) string {
	var out strings.Builder
	for _, char := range line {
		if char == '#' && !l.inBacktick && !l.inDouble {
			break
		}
		if !l.inBacktick && !l.inDouble && char != '`' && char != '"' {
			out.WriteRune(char)
		}
		if char == '"' && !l.inBacktick && !l.escaped {
			l.inDouble = !l.inDouble
		} else if char == '`' && !l.inDouble {
			l.inBacktick = !l.inBacktick
		}
		l.escaped = char == '\\' && !l.escaped
		if char != '\\' {
			l.escaped = false
		}
	}
	l.escaped = false
	return out.String()
}

func (l caddyLexer) quoted() bool {
	return l.inBacktick || l.inDouble
}

func (a *App) applyImportedBlocks(blocks []caddyBlock, merge bool) error {
	stage, err := os.MkdirTemp(a.Paths.Backup, "import-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	sitesStage, globalsStage := filepath.Join(stage, "sites"), filepath.Join(stage, "globals")
	if err := os.MkdirAll(sitesStage, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(globalsStage, 0o755); err != nil {
		return err
	}
	if merge {
		if err := copyDir(a.Paths.Sites, sitesStage); err != nil {
			return err
		}
		if err := copyDir(a.Paths.Globals, globalsStage); err != nil {
			return err
		}
	}
	email := a.State.Email
	var globalLines []string
	for _, block := range blocks {
		if strings.HasPrefix(strings.TrimSpace(block.Header), "{") {
			body := strings.Split(block.Text, "\n")
			if len(body) >= 2 {
				body = body[1 : len(body)-2]
			}
			for _, line := range body {
				trimmed := strings.TrimSpace(line)
				if strings.HasPrefix(trimmed, "email ") {
					email = strings.TrimSpace(strings.TrimPrefix(trimmed, "email "))
					continue
				}
				globalLines = append(globalLines, strings.TrimPrefix(line, "    "))
			}
			continue
		}
		name := slugHeader(block.Header)
		path := uniqueImportPath(sitesStage, name, block.Text)
		if err := os.WriteFile(path, []byte(block.Text), 0o644); err != nil {
			return err
		}
	}
	if !validEmail(email) {
		return fmt.Errorf("导入的全局 email 不合法: %s", email)
	}
	if len(globalLines) > 0 {
		content := strings.TrimRight(strings.Join(globalLines, "\n"), "\n") + "\n"
		if err := os.WriteFile(filepath.Join(globalsStage, "00-imported.inc"), []byte(content), 0o644); err != nil {
			return err
		}
	}
	oldEmail := a.State.Email
	a.State.Email = email
	if err := replaceDir(sitesStage, a.Paths.Sites); err != nil {
		return err
	}
	if err := replaceDir(globalsStage, a.Paths.Globals); err != nil {
		return err
	}
	if err := a.saveState(); err != nil {
		return err
	}
	if err := a.apply(); err != nil {
		a.State.Email = oldEmail
		return err
	}
	fmt.Fprintln(a.Out, "导入完成")
	return nil
}

var importSlugRE = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

func slugHeader(header string) string {
	header = strings.TrimSpace(strings.Split(header, "{")[0])
	header = strings.ReplaceAll(header, ",", "_")
	header = strings.Trim(importSlugRE.ReplaceAllString(header, "_"), "_")
	if header == "" {
		return "site"
	}
	return header
}

func uniqueImportPath(dir, name, content string) string {
	for i := 0; ; i++ {
		base := name
		if i > 0 {
			base = fmt.Sprintf("%s-%d", name, i)
		}
		path := filepath.Join(dir, base+".conf")
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) || (err == nil && strings.TrimSpace(string(data)) == strings.TrimSpace(content)) {
			return path
		}
	}
}
