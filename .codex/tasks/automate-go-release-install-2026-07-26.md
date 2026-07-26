# 自动构建与默认安装滚动最新版

日期：2026-07-26
分支：`refactor/go`

## 目标

每次推送到 `refactor/go` 后，GitHub Actions 自动验证并构建 linux/amd64、linux/arm64 二进制，更新滚动预发布 `go-latest`；安装器和原生更新命令默认使用该滚动最新版。

## 边界

- 固定 `v*` Release 保持不可变。
- 显式指定 `CADDYCTL_GO_VERSION=vX.Y.Z` 或 `c update --ref vX.Y.Z` 时仍安装固定版本。
- 不修改线上 Caddy 或系统服务。

## TODO

- [x] 核对当前工作流、Release 资产和安装默认值。
- [x] 加固自动构建、发布后校验和 Release 元数据。
- [x] 将安装器与 `c update` 默认值统一为 `go-latest`。
- [x] 更新 README、帮助和安全说明。
- [x] 完成本地验证并推送，确认 Actions 和远端资产。

## 状态

已完成：Release 质量门禁、双架构构建、发布后复验及完整 CI 均通过；默认安装已验证获得对应提交的 `go-latest` 二进制。
