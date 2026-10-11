package caddyctl

import (
	"embed"
	"fmt"
	"os"
	"path/filepath"
)

//go:embed skill/SKILL.md
var skillFS embed.FS

// skillCommand 打印或安装内嵌的 SKILL 文档。
// 文档随二进制发布，与当前安装版本的行为严格一致；
// install-self 与 install-go.sh 装完二进制后会自动安装到配置目录。
func (a *App) skillCommand(args []string) error {
	switch {
	case len(args) == 0:
		data, err := skillFS.ReadFile("skill/SKILL.md")
		if err != nil {
			return err
		}
		_, err = a.Out.Write(data)
		return err
	case len(args) == 1 && args[0] == "install":
		path, err := a.skillInstall()
		if err != nil {
			return err
		}
		fmt.Fprintf(a.Out, "已安装 skill 文档: %s\n", path)
		return nil
	default:
		return fmt.Errorf("用法: c skill [install]")
	}
}

func (a *App) skillInstall() (string, error) {
	data, err := skillFS.ReadFile("skill/SKILL.md")
	if err != nil {
		return "", err
	}
	dir := filepath.Dir(a.Paths.Caddyfile)
	target := filepath.Join(dir, "skill", "SKILL.md")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return "", fmt.Errorf("创建 skill 目录: %w", err)
	}
	if err := atomicWrite(target, data, 0o644); err != nil {
		return "", fmt.Errorf("写入 skill 文档: %w", err)
	}
	return target, nil
}
