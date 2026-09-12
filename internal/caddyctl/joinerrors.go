package caddyctl

import "strings"

// joinErrors 拼接多个错误（兼容 Go < 1.20，替代 errors.Join）。
// 多个非 nil 错误以换行分隔；全为 nil 时返回 nil。
func joinErrors(errs ...error) error {
	var msgs []string
	for _, err := range errs {
		if err != nil {
			msgs = append(msgs, err.Error())
		}
	}
	if len(msgs) == 0 {
		return nil
	}
	return &joinedError{msgs: msgs}
}

type joinedError struct{ msgs []string }

func (e *joinedError) Error() string { return strings.Join(e.msgs, "\n") }
