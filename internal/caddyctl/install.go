package caddyctl

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

const defaultInstallerRef = "refactor/go"

var installerRefRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$`)

func (a *App) installCommand(args []string) error {
	cloudflare := false
	for _, arg := range args {
		switch arg {
		case "--cloudflare":
			cloudflare = true
		case "-h", "--help":
			fmt.Fprintln(a.Out, "用法: c install [--cloudflare]")
			return nil
		default:
			return fmt.Errorf("未知 install 参数: %s", arg)
		}
	}
	installerURL, err := goInstallerURL()
	if err != nil {
		return err
	}
	script, err := downloadReleaseFile(installerURL, 1<<20)
	if err != nil {
		return fmt.Errorf("下载安装器: %w", err)
	}
	tmp, err := os.CreateTemp("", "caddyctl-install-*.sh")
	if err != nil {
		return err
	}
	path := tmp.Name()
	defer os.Remove(path)
	if err := tmp.Chmod(0o700); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(script); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	cmdArgs := []string{path}
	if cloudflare {
		cmdArgs = append(cmdArgs, "--cloudflare")
	}
	cmd := exec.Command("bash", cmdArgs...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = a.In, a.Out, a.Err
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("install-go.sh 执行失败: %w", err)
	}
	return nil
}

func (a *App) selfInstallCommand(args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("用法: c install-self")
	}
	source, err := os.Executable()
	if err != nil {
		return fmt.Errorf("定位当前二进制: %w", err)
	}
	if resolved, resolveErr := filepath.EvalSymlinks(source); resolveErr == nil {
		source = resolved
	}
	binDir := getenv("CADDYCTL_GO_BIN_DIR", "/usr/local/bin")
	if !filepath.IsAbs(binDir) {
		return fmt.Errorf("CADDYCTL_GO_BIN_DIR 必须是绝对路径")
	}
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return fmt.Errorf("创建安装目录: %w", err)
	}
	destination := filepath.Join(binDir, "caddyctl")
	same := false
	if sourceInfo, sourceErr := os.Stat(source); sourceErr == nil {
		if destinationInfo, destinationErr := os.Stat(destination); destinationErr == nil {
			same = os.SameFile(sourceInfo, destinationInfo)
		}
	}
	if !same {
		if _, err := os.Stat(destination); err == nil {
			if err := copyFile(destination, destination+".bak", 0o755); err != nil {
				return fmt.Errorf("备份当前二进制: %w", err)
			}
		}
		if err := copyFile(source, destination, 0o755); err != nil {
			return fmt.Errorf("安装当前二进制: %w", err)
		}
	}
	alias := filepath.Join(binDir, "c")
	if err := replaceSymlink(destination, alias); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "已安装本机 CLI: %s\n别名: %s -> %s\n", destination, alias, destination)
	return nil
}

func replaceSymlink(target, link string) error {
	info, err := os.Lstat(link)
	if err == nil && info.IsDir() {
		return fmt.Errorf("CLI 别名目标是目录: %s", link)
	}
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	tmp := link + ".new"
	if err := os.Remove(tmp); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.Symlink(target, tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, link); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func goInstallerURL() (string, error) {
	if override := strings.TrimSpace(os.Getenv("CADDYCTL_GO_INSTALLER_URL")); override != "" {
		if !strings.HasPrefix(override, "https://") && !strings.HasPrefix(override, "http://") {
			return "", fmt.Errorf("安装器 URL 仅支持 HTTP(S)")
		}
		return override, nil
	}
	repository := getenv("CADDYCTL_GO_REPOSITORY", "buglyz/caddy_cli")
	if !validRepository(repository) {
		return "", fmt.Errorf("GitHub 仓库名不合法")
	}
	ref := getenv("CADDYCTL_GO_INSTALLER_REF", defaultInstallerRef)
	if !validInstallerRef(ref) {
		return "", fmt.Errorf("安装器 ref 不合法")
	}
	return "https://raw.githubusercontent.com/" + repository + "/" + ref + "/install-go.sh", nil
}

func validInstallerRef(ref string) bool {
	if !installerRefRE.MatchString(ref) || strings.Contains(ref, "//") {
		return false
	}
	for _, part := range strings.Split(filepath.ToSlash(ref), "/") {
		if part == "." || part == ".." || part == "" {
			return false
		}
	}
	return true
}
