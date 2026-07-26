package caddyctl

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type restoreItem struct {
	destination string
	stage       string
	old         string
	hadOld      bool
	committed   bool
}

func (a *App) restoreSnapshotFiles(snapshot string, manifest map[string]string) error {
	sitesStage, err := stageDirectory(filepath.Join(snapshot, "sites"), filepath.Dir(a.Paths.Sites), ".caddyctl-sites-*")
	if err != nil {
		return fmt.Errorf("准备站点恢复: %w", err)
	}
	globalsStage, err := stageDirectory(filepath.Join(snapshot, "globals"), filepath.Dir(a.Paths.Globals), ".caddyctl-globals-*")
	if err != nil {
		os.RemoveAll(sitesStage)
		return fmt.Errorf("准备全局配置恢复: %w", err)
	}
	items := []*restoreItem{
		{destination: a.Paths.Sites, stage: sitesStage},
		{destination: a.Paths.Globals, stage: globalsStage},
	}
	if manifest["STATE_PRESENT"] == "1" {
		stateStage, stageErr := stageFile(filepath.Join(snapshot, "state.conf"), filepath.Dir(a.Paths.State))
		if stageErr != nil {
			cleanupRestoreItems(items)
			return fmt.Errorf("准备状态文件恢复: %w", stageErr)
		}
		items = append(items, &restoreItem{destination: a.Paths.State, stage: stateStage})
	} else {
		items = append(items, &restoreItem{destination: a.Paths.State})
	}
	defer cleanupRestoreItems(items)

	for _, item := range items {
		if err := commitRestoreItem(item); err != nil {
			rollbackErr := rollbackRestoreItems(items)
			if rollbackErr != nil {
				return fmt.Errorf("提交快照恢复: %v；且事务回滚失败: %w", err, rollbackErr)
			}
			return fmt.Errorf("提交快照恢复: %w", err)
		}
	}
	for _, item := range items {
		if item.hadOld {
			if err := os.RemoveAll(item.old); err != nil {
				return fmt.Errorf("清理恢复前文件 %s: %w", item.old, err)
			}
			item.old = ""
		}
	}
	return nil
}

func stageDirectory(source, parent, pattern string) (string, error) {
	stage, err := os.MkdirTemp(parent, pattern)
	if err != nil {
		return "", err
	}
	if err := copyDir(source, stage); err != nil {
		os.RemoveAll(stage)
		return "", err
	}
	return stage, nil
}

func stageFile(source, parent string) (string, error) {
	file, err := os.CreateTemp(parent, ".caddyctl-state-*")
	if err != nil {
		return "", err
	}
	stage := file.Name()
	if err := file.Close(); err != nil {
		os.Remove(stage)
		return "", err
	}
	if err := copyFile(source, stage, 0o644); err != nil {
		os.Remove(stage)
		return "", err
	}
	return stage, nil
}

func commitRestoreItem(item *restoreItem) error {
	old, err := reserveRestorePath(item.destination)
	if err != nil {
		return err
	}
	item.old = old
	if err := os.Rename(item.destination, item.old); err == nil {
		item.hadOld = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if item.stage != "" {
		if err := os.Rename(item.stage, item.destination); err != nil {
			if item.hadOld {
				if restoreErr := os.Rename(item.old, item.destination); restoreErr != nil {
					return fmt.Errorf("%v；且恢复原路径失败: %w（原文件保留在 %s）", err, restoreErr, item.old)
				}
				item.old, item.hadOld = "", false
			}
			return err
		}
		item.stage = ""
	}
	item.committed = true
	return nil
}

func reserveRestorePath(destination string) (string, error) {
	path, err := os.MkdirTemp(filepath.Dir(destination), ".caddyctl-restore-old-*")
	if err != nil {
		return "", err
	}
	if err := os.Remove(path); err != nil {
		return "", err
	}
	return path, nil
}

func rollbackRestoreItems(items []*restoreItem) error {
	var result error
	for i := len(items) - 1; i >= 0; i-- {
		item := items[i]
		if !item.committed {
			continue
		}
		if err := os.RemoveAll(item.destination); err != nil {
			result = errors.Join(result, err)
			continue
		}
		if item.hadOld {
			if err := os.Rename(item.old, item.destination); err != nil {
				result = errors.Join(result, err)
				continue
			}
			item.old, item.hadOld = "", false
		}
		item.committed = false
	}
	return result
}

func cleanupRestoreItems(items []*restoreItem) {
	for _, item := range items {
		if item.stage != "" {
			_ = os.RemoveAll(item.stage)
		}
	}
}
