package caddyctl

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

func (a *App) preparePendingImport() error {
	if os.Geteuid() != 0 && a.Paths.Root == "" {
		return nil
	}
	if _, err := os.Stat(a.Paths.PendingImport); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	if err := a.ensureDirs(); err != nil {
		return err
	}
	if err := a.loadState(); err != nil {
		return err
	}
	return a.maybeAutoImportExistingConfig()
}

func (a *App) maybeAutoImportExistingConfig() error {
	if truthy(os.Getenv("CADDYCTL_SKIP_AUTO_IMPORT")) || (os.Geteuid() != 0 && a.Paths.Root == "") {
		return nil
	}
	if _, err := os.Stat(a.Paths.PendingImport); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	live, err := os.ReadFile(a.Paths.Caddyfile)
	if errors.Is(err, os.ErrNotExist) || len(strings.TrimSpace(string(live))) == 0 {
		return os.Remove(a.Paths.PendingImport)
	}
	if err != nil {
		return err
	}
	sites, err := a.allSites()
	if err != nil {
		return err
	}
	if len(sites) > 0 {
		fmt.Fprintln(a.Out, "检测到首次导入标记，但 sites.d 已有站点；已取消自动导入，请按需使用 c import --merge。")
		return os.Remove(a.Paths.PendingImport)
	}
	fmt.Fprintf(a.Out, "首次运行：正在导入已有 Caddyfile → sites.d（源: %s）\n", a.Paths.Caddyfile)
	if err := a.importCommand([]string{"--force", a.Paths.Caddyfile}); err != nil {
		failed := a.Paths.PendingImport + ".failed"
		if renameErr := os.Rename(a.Paths.PendingImport, failed); renameErr != nil {
			return fmt.Errorf("%v；记录失败标记: %w", err, renameErr)
		}
		return err
	}
	if err := os.Remove(a.Paths.PendingImport); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	fmt.Fprintln(a.Out, "首次自动导入完成")
	return nil
}
