package caddyctl

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

var Version = "dev"

const defaultReleaseRef = "go-latest"

var (
	releaseRefRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`)
	repositoryRE = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
)

func (a *App) updateCommand(args []string) error {
	version, err := updateVersion(args)
	if err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("定位当前二进制: %w", err)
	}
	if resolved, resolveErr := filepath.EvalSymlinks(executable); resolveErr == nil {
		executable = resolved
	}
	if err := updateBinary(executable, version); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "Go CLI 已更新；备份: %s.bak\n", executable)
	return nil
}

func updateVersion(args []string) (string, error) {
	version := getenv("CADDYCTL_GO_VERSION", defaultReleaseRef)
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--ref":
			if i+1 >= len(args) {
				return "", fmt.Errorf("--ref 需要 release tag、go-latest 或 latest")
			}
			i++
			version = args[i]
		case "--latest":
			version = defaultReleaseRef
		case "--binary":
			return "", fmt.Errorf("Go 版 update 不更新 Caddy 服务二进制；请单独运行 caddy 的安装器")
		default:
			return "", fmt.Errorf("未知 update 参数: %s", args[i])
		}
	}
	if !validReleaseRef(version) {
		return "", fmt.Errorf("release tag 不合法")
	}
	return version, nil
}

func updateBinary(destination, version string) error {
	if runtime.GOOS != "linux" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		return fmt.Errorf("暂不支持更新平台: %s/%s", runtime.GOOS, runtime.GOARCH)
	}
	if !validReleaseRef(version) {
		return fmt.Errorf("release tag 不合法")
	}
	repository := getenv("CADDYCTL_GO_REPOSITORY", "buglyz/caddy_cli")
	base := strings.TrimSuffix(os.Getenv("CADDYCTL_GO_RELEASE_BASE_URL"), "/")
	if base == "" {
		if !validRepository(repository) {
			return fmt.Errorf("GitHub 仓库名不合法")
		}
		if version == "latest" {
			base = "https://github.com/" + repository + "/releases/latest/download"
		} else {
			base = "https://github.com/" + repository + "/releases/download/" + version
		}
	}
	asset := "caddyctl-linux-" + runtime.GOARCH
	binary, err := downloadReleaseFile(base+"/"+asset, 100<<20)
	if err != nil {
		return fmt.Errorf("下载 %s: %w", asset, err)
	}
	sums, err := downloadReleaseFile(base+"/caddyctl-checksums.txt", 1<<20)
	if err != nil {
		return fmt.Errorf("下载校验文件: %w", err)
	}
	expected := checksumEntry(string(sums), asset)
	if expected == "" {
		return fmt.Errorf("校验文件缺少条目: %s", asset)
	}
	actualBytes := sha256.Sum256(binary)
	actual := hex.EncodeToString(actualBytes[:])
	if actual != expected {
		return fmt.Errorf("SHA256 校验失败: %s", asset)
	}
	dir := filepath.Dir(destination)
	tmp, err := os.CreateTemp(dir, ".caddyctl-update-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o755); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(binary); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if output, err := exec.Command(tmpPath, "--help").CombinedOutput(); err != nil {
		return fmt.Errorf("新二进制自检失败: %s", strings.TrimSpace(string(output)))
	}
	if _, err := os.Stat(destination); err == nil {
		if err := copyFile(destination, destination+".bak", 0o755); err != nil {
			return fmt.Errorf("备份当前二进制: %w", err)
		}
	}
	if err := os.Rename(tmpPath, destination); err != nil {
		return fmt.Errorf("替换当前二进制: %w", err)
	}
	return nil
}

func validReleaseRef(value string) bool {
	return value != "." && value != ".." && releaseRefRE.MatchString(value)
}

func validRepository(value string) bool {
	if !repositoryRE.MatchString(value) {
		return false
	}
	owner, name, _ := strings.Cut(value, "/")
	return owner != "." && owner != ".." && name != "." && name != ".."
}

func downloadReleaseFile(url string, limit int64) ([]byte, error) {
	client := http.Client{Timeout: 2 * time.Minute}
	response, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	reader := io.LimitReader(response.Body, limit+1)
	data, err := io.ReadAll(reader)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("文件超过 %d 字节限制", limit)
	}
	return data, nil
}

func checksumEntry(data, asset string) string {
	for _, line := range strings.Split(data, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == asset {
			if len(fields[0]) == sha256.Size*2 {
				return strings.ToLower(fields[0])
			}
		}
	}
	return ""
}
