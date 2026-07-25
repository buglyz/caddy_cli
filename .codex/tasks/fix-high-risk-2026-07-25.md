# 修复高危审查项

日期：2026-07-25

## TODO

- [x] 增加 apply 前配置所有权门禁，阻断 inline-only/明显漂移站点被覆盖
- [x] 使用安全锁目录与安全文件校验，拒绝 symlink、异常类型和异常所有者
- [x] 强化快照创建、完整性校验与安全恢复，禁止吞掉复制错误
- [x] 为三项高危问题增加隔离回归测试
- [x] 运行 Bash 语法、ShellCheck、smoke 与 functional 验证

## 约束

- 不访问或修改 `/etc/caddy`、生产 Caddy、服务和远端仓库
- 测试必须先 source `caddy-lib.sh`，再覆盖所有路径到 `mktemp` 隔离目录
- 不修改或删除既有测试来掩盖问题

## 状态

已完成。

## 验证结果

- Bash 语法检查：通过
- ShellCheck：通过
- `tests/smoke.sh`：通过
- `tests/functional.sh`：209 PASS / 0 FAIL / 1 SKIP
- `checksums.txt`：仓库内文件全部匹配
