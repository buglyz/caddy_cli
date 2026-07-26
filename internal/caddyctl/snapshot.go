package caddyctl

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func (a *App) withLock(fn func() error) error {
	if err := a.ensureDirs(); err != nil {
		return err
	}
	info, err := os.Lstat(filepath.Dir(a.Paths.Lock))
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("锁目录不安全: %s", filepath.Dir(a.Paths.Lock))
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("锁目录属主不安全: %s", filepath.Dir(a.Paths.Lock))
	}
	fd, err := syscall.Open(a.Paths.Lock, syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return fmt.Errorf("打开操作锁: %w", err)
	}
	file := os.NewFile(uintptr(fd), a.Paths.Lock)
	defer file.Close()
	var lockStat syscall.Stat_t
	if err := syscall.Fstat(fd, &lockStat); err != nil || lockStat.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("锁文件属主不安全: %s", a.Paths.Lock)
	}
	if err := syscall.Fchmod(fd, 0o600); err != nil {
		return fmt.Errorf("设置锁文件权限: %w", err)
	}
	wait, _ := strconv.Atoi(getenv("CADDYCTL_LOCK_WAIT_SECONDS", strconv.Itoa(defaultLockWait)))
	if wait < 1 || wait > 600 {
		wait = defaultLockWait
	}
	deadline := time.Now().Add(time.Duration(wait) * time.Second)
	for {
		err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) || time.Now().After(deadline) {
			return fmt.Errorf("获取全局操作锁超时（%ds）", wait)
		}
		time.Sleep(100 * time.Millisecond)
	}
	defer syscall.Flock(fd, syscall.LOCK_UN)
	return fn()
}

func (a *App) mutate(action string, fn func() error) error {
	return a.withLock(func() error {
		if action != "import" && action != "import-merge" {
			if err := a.assertManaged(); err != nil {
				return err
			}
		}
		snapshot, err := a.createSnapshot(action)
		if err != nil {
			return fmt.Errorf("创建回滚快照失败: %w", err)
		}
		if err := fn(); err != nil {
			if restoreErr := a.restoreSnapshot(snapshot); restoreErr != nil {
				return fmt.Errorf("%v；且自动恢复快照失败: %w", err, restoreErr)
			}
			return err
		}
		fmt.Fprintf(a.Out, "已保存回滚快照: %s\n", filepath.Base(snapshot))
		return nil
	})
}

func (a *App) createSnapshot(action string) (string, error) {
	if err := os.MkdirAll(a.Paths.Snapshots, 0o755); err != nil {
		return "", err
	}
	stage, err := os.MkdirTemp(a.Paths.Snapshots, ".partial-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stage)
	for _, item := range []struct{ src, dst string }{{a.Paths.Sites, "sites"}, {a.Paths.Globals, "globals"}} {
		if err := os.MkdirAll(filepath.Join(stage, item.dst), 0o755); err != nil {
			return "", err
		}
		if err := copyDir(item.src, filepath.Join(stage, item.dst)); err != nil {
			return "", err
		}
	}
	statePresent, caddyPresent := 0, 0
	if _, err := os.Stat(a.Paths.State); err == nil {
		if err := copyFile(a.Paths.State, filepath.Join(stage, "state.conf"), 0o644); err != nil {
			return "", err
		}
		statePresent = 1
	}
	if _, err := os.Stat(a.Paths.Caddyfile); err == nil {
		if err := copyFile(a.Paths.Caddyfile, filepath.Join(stage, "Caddyfile"), 0o644); err != nil {
			return "", err
		}
		caddyPresent = 1
	}
	meta := fmt.Sprintf("ACTION=%s\nCREATED_AT=%s\n", action, time.Now().Format("2006-01-02 15:04:05"))
	manifest := fmt.Sprintf("FORMAT=1\nSTATE_PRESENT=%d\nCADDYFILE_PRESENT=%d\n", statePresent, caddyPresent)
	if err := os.WriteFile(filepath.Join(stage, "meta"), []byte(meta), 0o644); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(stage, "manifest"), []byte(manifest), 0o644); err != nil {
		return "", err
	}
	id := fmt.Sprintf("%s-%d", time.Now().Format("20060102-150405.000000000"), os.Getpid())
	destination := filepath.Join(a.Paths.Snapshots, id)
	if err := os.Rename(stage, destination); err != nil {
		return "", err
	}
	a.pruneSnapshots(defaultSnapshotKeep)
	return destination, nil
}

func (a *App) pruneSnapshots(keep int) {
	entries, _ := os.ReadDir(a.Paths.Snapshots)
	var names []string
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	for len(names) > keep {
		_ = os.RemoveAll(filepath.Join(a.Paths.Snapshots, names[0]))
		names = names[1:]
	}
}

func (a *App) snapshotPath(requested string) (string, error) {
	if requested != "" && requested != "latest" {
		if filepath.Base(requested) != requested || strings.Contains(requested, string(filepath.Separator)) {
			return "", fmt.Errorf("快照ID格式不合法")
		}
		path := filepath.Join(a.Paths.Snapshots, requested)
		if err := a.validateSnapshot(path); err != nil {
			return "", err
		}
		return path, nil
	}
	entries, _ := os.ReadDir(a.Paths.Snapshots)
	var names []string
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	if len(names) == 0 {
		return "", fmt.Errorf("没有可回滚的快照")
	}
	path := filepath.Join(a.Paths.Snapshots, names[len(names)-1])
	return path, a.validateSnapshot(path)
}

func (a *App) validateSnapshot(path string) error {
	clean := filepath.Clean(path)
	rel, err := filepath.Rel(a.Paths.Snapshots, clean)
	if err != nil || strings.HasPrefix(rel, "..") || rel == "." {
		return fmt.Errorf("快照路径不合法")
	}
	for _, name := range []string{"sites", "globals", "meta", "manifest"} {
		info, statErr := os.Lstat(filepath.Join(clean, name))
		if statErr != nil || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("快照结构不完整: %s", filepath.Base(clean))
		}
	}
	values, err := readKeyValues(filepath.Join(clean, "manifest"))
	if err != nil || values["FORMAT"] != "1" {
		return fmt.Errorf("快照 manifest 不合法")
	}
	return nil
}

func readKeyValues(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	result := map[string]string{}
	s := bufio.NewScanner(f)
	for s.Scan() {
		key, value, ok := strings.Cut(s.Text(), "=")
		if ok {
			result[key] = value
		}
	}
	return result, s.Err()
}

func (a *App) restoreSnapshot(path string) error {
	if err := a.validateSnapshot(path); err != nil {
		return err
	}
	manifest, err := readKeyValues(filepath.Join(path, "manifest"))
	if err != nil {
		return err
	}
	if err := replaceDir(filepath.Join(path, "sites"), a.Paths.Sites); err != nil {
		return fmt.Errorf("恢复站点目录: %w", err)
	}
	if err := replaceDir(filepath.Join(path, "globals"), a.Paths.Globals); err != nil {
		return fmt.Errorf("恢复全局目录: %w", err)
	}
	if manifest["STATE_PRESENT"] == "1" {
		if err := copyFile(filepath.Join(path, "state.conf"), a.Paths.State, 0o644); err != nil {
			return fmt.Errorf("恢复状态文件: %w", err)
		}
	} else if err := os.Remove(a.Paths.State); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return a.loadState()
}

func (a *App) undo(requested string) error {
	return a.withLock(func() error {
		target, err := a.snapshotPath(requested)
		if err != nil {
			return err
		}
		guard, err := a.createSnapshot("undo-guard")
		if err != nil {
			return fmt.Errorf("创建回滚保护快照: %w", err)
		}
		if err := a.restoreSnapshot(target); err != nil {
			_ = os.RemoveAll(guard)
			return err
		}
		if err := a.apply(); err != nil {
			_ = a.restoreSnapshot(guard)
			_ = a.apply()
			_ = os.RemoveAll(guard)
			return fmt.Errorf("回滚后应用失败，已恢复回滚前状态: %w", err)
		}
		_ = os.RemoveAll(target)
		_ = os.RemoveAll(guard)
		fmt.Fprintf(a.Out, "已回滚到快照: %s\n", filepath.Base(target))
		return nil
	})
}

func (a *App) listSnapshots(limitArg string) error {
	limit := 20
	if limitArg == "all" {
		limit = 0
	} else if limitArg != "" {
		n, err := strconv.Atoi(limitArg)
		if err != nil || n < 0 {
			return fmt.Errorf("快照数量必须是整数或 all")
		}
		limit = n
	}
	entries, err := os.ReadDir(a.Paths.Snapshots)
	if errors.Is(err, os.ErrNotExist) {
		fmt.Fprintln(a.Out, "暂无回滚快照")
		return nil
	}
	if err != nil {
		return err
	}
	var names []string
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
			names = append(names, entry.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	if len(names) == 0 {
		fmt.Fprintln(a.Out, "暂无回滚快照")
		return nil
	}
	fmt.Fprintf(a.Out, "%-34s  %-18s  %s\n", "快照ID", "操作", "创建时间")
	shown := 0
	for _, name := range names {
		if limit > 0 && shown >= limit {
			break
		}
		meta, _ := readKeyValues(filepath.Join(a.Paths.Snapshots, name, "meta"))
		fmt.Fprintf(a.Out, "%-34s  %-18s  %s\n", name, valueOr(meta["ACTION"], "unknown"), valueOr(meta["CREATED_AT"], "unknown"))
		shown++
	}
	return nil
}

func valueOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
