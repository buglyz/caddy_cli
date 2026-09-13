package caddyctl

import "strings"

// joinErrors 拼接多个错误（兼容 Go < 1.20，替代 errors.Join）。
// 多个非 nil 错误以换行分隔；全为 nil 时返回 nil。
// 注: Go <1.20 的 errors.Is/As 不支持多错误解包（Unwrap() []error 需 1.20+），
// 当前调用点只读错误文本，升级工具链后可补 Unwrap。
func joinErrors(errs ...error) error {
	var nonNil []error
	for _, err := range errs {
		if err != nil {
			nonNil = append(nonNil, err)
		}
	}
	if len(nonNil) == 0 {
		return nil
	}
	return &joinedError{errs: nonNil}
}

type joinedError struct{ errs []error }

func (e *joinedError) Error() string {
	msgs := make([]string, len(e.errs))
	for i, err := range e.errs {
		msgs[i] = err.Error()
	}
	return strings.Join(msgs, "\n")
}
