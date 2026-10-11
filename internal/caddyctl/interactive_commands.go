package caddyctl

import (
	"bufio"
	"fmt"
	"strings"
)

// readRequiredInput 单行提示读取（rm/enable 等命令无参时的回退交互）。
// 完整交互菜单已移除；复杂流程请使用带参数的命令形式。
func (a *App) readRequiredInput(prompt string) (string, error) {
	fmt.Fprint(a.Out, prompt)
	scanner := bufio.NewScanner(a.In)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return "", fmt.Errorf("读取输入: %w", err)
		}
		return "", fmt.Errorf("未读取到输入")
	}
	value := strings.TrimSpace(scanner.Text())
	if value == "" {
		return "", fmt.Errorf("输入为空")
	}
	return value, nil
}
