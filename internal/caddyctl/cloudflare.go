package caddyctl

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

type cloudflareVerify struct {
	Success bool `json:"success"`
	Result  struct {
		Status string `json:"status"`
	} `json:"result"`
}

func (a *App) cloudflareCommand(args []string) error {
	if !a.Cloudflare {
		return fmt.Errorf("当前不是 Cloudflare 版 CLI")
	}
	action := "status"
	if len(args) > 0 && args[0] != "" {
		action = args[0]
	}
	if len(args) > 1 {
		return fmt.Errorf("用法: c cloudflare set|check|remove")
	}
	switch action {
	case "status", "show":
		if _, err := os.Stat(a.Paths.CloudflareEnv); err == nil {
			fmt.Fprintln(a.Out, "Cloudflare API Token 已配置")
			return nil
		}
		fmt.Fprintln(a.Out, "Cloudflare API Token 未配置")
		return nil
	case "check":
		token, err := readCloudflareToken(a.Paths.CloudflareEnv)
		if err != nil {
			return fmt.Errorf("Cloudflare API Token 未配置")
		}
		if err := verifyCloudflareToken(token); err != nil {
			return err
		}
		fmt.Fprintln(a.Out, "Cloudflare API Token 有效")
		return nil
	case "set":
		if len(args) > 1 {
			return fmt.Errorf("请不要把 Token 作为命令参数传入；使用 c cloudflare set 后从 stdin 输入")
		}
		return a.mutate("cloudflare", func() error {
			token, err := readTokenInput(a.In)
			if err != nil {
				return err
			}
			if err := verifyCloudflareToken(token); err != nil {
				return err
			}
			content := fmt.Sprintf("CLOUDFLARE_API_TOKEN=\"%s\"\n", escapeEnv(token))
			if err := a.changeCloudflareEnv([]byte(content)); err != nil {
				return err
			}
			fmt.Fprintln(a.Out, "Cloudflare API Token 已保存")
			return nil
		})
	case "remove", "clear", "disable", "off", "none":
		return a.mutate("cloudflare", func() error {
			if err := a.changeCloudflareEnv(nil); err != nil {
				return err
			}
			fmt.Fprintln(a.Out, "Cloudflare 配置已删除")
			return nil
		})
	default:
		return fmt.Errorf("未知 cloudflare 子命令: %s", action)
	}
}

func (a *App) changeCloudflareEnv(content []byte) error {
	old, readErr := os.ReadFile(a.Paths.CloudflareEnv)
	hadOld := readErr == nil
	if readErr != nil && !os.IsNotExist(readErr) {
		return readErr
	}
	if content == nil {
		if err := os.Remove(a.Paths.CloudflareEnv); err != nil && !os.IsNotExist(err) {
			return err
		}
	} else if err := atomicWrite(a.Paths.CloudflareEnv, content, 0o600); err != nil {
		return err
	}
	if err := a.apply(); err != nil {
		if hadOld {
			_ = atomicWrite(a.Paths.CloudflareEnv, old, 0o600)
		} else {
			_ = os.Remove(a.Paths.CloudflareEnv)
		}
		return fmt.Errorf("应用 Cloudflare 设置失败，已恢复环境文件: %w", err)
	}
	return nil
}

func readTokenInput(reader io.Reader) (string, error) {
	scanner := bufio.NewScanner(reader)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return "", err
		}
		return "", fmt.Errorf("未读取到 Cloudflare Token")
	}
	token := strings.TrimSpace(scanner.Text())
	if token == "" || strings.ContainsAny(token, "\r\n \t") {
		return "", fmt.Errorf("Cloudflare Token 格式不合法")
	}
	return token, nil
}

func verifyCloudflareToken(token string) error {
	endpoint := getenv("CADDYCTL_CLOUDFLARE_VERIFY_URL", "https://api.cloudflare.com/client/v4/user/tokens/verify")
	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	client := http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("验证 Cloudflare Token: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	var result cloudflareVerify
	if resp.StatusCode != http.StatusOK || json.Unmarshal(body, &result) != nil || !result.Success || result.Result.Status != "active" {
		return fmt.Errorf("Cloudflare Token 无效或无权访问（HTTP %d）", resp.StatusCode)
	}
	return nil
}

func readCloudflareToken(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	for _, line := range bytes.Split(data, []byte{'\n'}) {
		text := strings.TrimSpace(string(line))
		if strings.HasPrefix(text, "CLOUDFLARE_API_TOKEN=") {
			return strings.Trim(strings.TrimPrefix(text, "CLOUDFLARE_API_TOKEN="), "\"'"), nil
		}
	}
	return "", fmt.Errorf("Token 字段不存在")
}

func escapeEnv(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	return strings.ReplaceAll(value, `"`, `\"`)
}
