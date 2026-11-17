# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号使用语义化版本（`MAJOR.MINOR.PATCH`）。

## Unreleased

### Added

- 纯文本诊断日志：主应用 `~/Library/Application Support/IClick/diagnostics.log`，
  扩展 `~/Library/Group Containers/group.33WRMMC62L.cn.anwen.IClick/diagnostics-extension.log`
  （统一日志默认脱敏，且本机曾出现日志库损坏，无法作为唯一排查手段）。
- App Group 配置快照：主应用每次落盘时同步写一份，扩展启动时立刻可读，
  不再依赖主应用正在运行或推送已经到达。
- `scripts/smoke-test.sh` 纯逻辑回归测试（消息解码、路径保护、模型编解码、消息去重）。
- `.github/workflows/ci.yml`：CI 构建 + smoke test。
- 动作消息可靠投递：`messageID` + 主应用 ack + 扩展重发 + 主应用去重。
- 扩展 → 主应用的动作通道改为 App Group 容器内的 Unix socket，主应用校验对端
  代码签名（bundle id + Team ID）；DNC 来的动作消息一律拒绝（DNC 不校验发送方）。
- 设置页把 Finder 扩展与完全磁盘访问合并为「权限与状态」，明确标出必需/可选，
  显示实时状态并支持重新检测；诊断采集包含主应用自报的 FDA 状态。
- 崩溃标记：信号/未捕获异常会先写入诊断日志，再交回系统生成崩溃报告。
- `scripts/collect-diagnostics.sh`：一键打包诊断信息到桌面。
- `ARCHITECTURE.md`、`CONTRIBUTING.md`、issue 模板。

### Changed

- 扩展启动时把群组容器快照转成内存配置，并按 mtime 缓存；主应用未运行时不再
  每读一个 key 都解析一遍 plist，也不再反复请求配置（实测启动心跳 10 次 → 1 次）。
- `AppState.load()` 一次读取整份配置后分段解码，避免重复解析 5 次；
  `showApps` getter 也只读一次配置。
- 右键建菜单前的快照版本检查改用缓存字典，只有快照 mtime 变化时才重新解析。

### Fixed

- 用户双击/重开应用时打开设置窗口；扩展或登录项拉起时不弹窗。
- 设置里的「在菜单栏显示」改用 App Group，修复开关不生效。
- 主应用找不到菜单 rid 时重读磁盘配置再匹配。
- 登录项自动重指到当前 `/Applications` bundle；开发副本不参与。
- 「常用 App」子菜单开关、子菜单开关回弹、文件类型后缀被改坏、重置图标无效、
  自定义图标同名覆盖等设置问题。
- 配置段解码失败后不再被 `save()` 覆盖。
- 打开应用/创建文件/登录项注册失败时发通知，不再静默。
- IPC 服务端的 accept 循环与客户端处理共用串行队列，导致连接被接受却永远不处理；
  已拆分为独立队列。
- 隐藏/取消隐藏、删除、粘贴、打开目录等失败写入诊断日志（含错误码），
  便于区分 TCC/权限问题与逻辑问题。
- 更新器错误不可见、错误状态残留、Release 可空字段导致解码失败等问题。

## 1.0.8 — 2026-07-04

- 当前安装版本。更早的变更未在仓库内维护。
