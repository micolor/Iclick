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

- 扩展的动作投递不再占用 Finder 主线程：阻塞式 socket 往返（最长 1 秒/次）移到
  后台队列，重试调度仍在主线程；存活判断改为按 bundle id 直接查询 `NSRunningApplication`。
- 主应用保存配置从「每个段一次读-改-写」（5 段 ≈ 10 次文件写）合并为一次原子写；
  `ICLICK_CONFIG_VERSION` 的自增与读取合并到同一把锁内，退出前立即落盘防抖中的版本号。
- 多选文件「打开方式」只解析应用并启动一次，用单个 `open` 进程传递全部路径，
  不再为每个文件做一次 LaunchServices 查询 / Info.plist 读取 / 进程启动。
- 粘贴的复制/移动循环移到后台队列，多选大文件时不再让主线程无响应；
  同一时间只允许一个粘贴。
- 「隐藏/取消隐藏该目录下全部内容」的枚举与逐项写入移到后台队列，
  大目录不再阻塞主线程。
- Xcode 工程与手构建脚本对齐：补上 `LocalIPC.swift` / `DiagnosticLog.swift` /
  `MessageDeduplicator.swift`，扩展 target 移除 `Updater` / `UpdaterView` /
  `Extension+`（此前 Xcode 构建缺文件，扩展也会多链接 SwiftUI/ServiceManagement/CryptoKit）。
- 设置页与 Finder 菜单的着色 SF Symbol、应用图标加入进程内缓存；图标选择器的
  分类去重排序改为预计算一次，不再在每次视图刷新 / 每次搜索输入时重算。
- FDA 检测不再在每次视图结构体重建时触发（`@State` 默认表达式的求值时机所致），
  只在进入页面与从系统设置返回时探测。
- 诊断日志的日期格式化器改为复用，不再每写一行都新建 `DateFormatter`。
- `AppState` 初始化时给子菜单顺序赋值不再触发落盘与版本号自增。
- 配置同步彻底改为快照版本号：主应用只递增 `ICLICK_CONFIG_VERSION`（80ms 防抖），
  扩展在下一次建菜单时自行比较版本并重载快照；DistributedNotificationCenter 的
  心跳/配置推送/退出通知全部删除（不校验发送方，且每次启动都会重复请求）。
- 扩展启动时把群组容器快照转成内存配置，并按 mtime 缓存；主应用未运行时不再
  每读一个 key 都解析一遍 plist。
- `AppState.load()` 一次读取整份配置后分段解码，避免重复解析 5 次；
  `showApps` getter 也只读一次配置。
- 主应用读取 `SharedSettings.plist` 同样按 mtime 缓存，设置页一屏多次读取只解析一次；
  写入成功后直接更新缓存。
- 右键建菜单前的快照版本检查改用缓存字典，只有快照 mtime 变化时才重新解析。
- 扩展菜单缓存加了 LRU 上限（16 个目录），避免长时间运行后无限增长；
  菜单项 tag 改为按 `rid` 稳定映射，不再随菜单顺序变化。
- 扩展缩放后的图标按「路径 + mtime」缓存，重复右键同一批文件不再反复重绘。
- 扩展不再编译/链接主应用专用的 `Shared` 文件（更新器、登录项等）以及
  SwiftUI/ServiceManagement/CryptoKit；扩展二进制约 953KB，常驻内存明显下降。
- 扩展的编译单元彻底不再引用 SwiftUI：设置页专用的 `Color` 辅助函数移到主应用
  文件，`remove(atOffsets:)`（SwiftUI 扩展）换成标准库等价写法。扩展对象里只剩
  AppKit 自身自动链接的 `SwiftUICore`。

### Fixed

- 家目录本身加入受保护目录：右键家目录「删除」会被拦截。此前只保护 `~/Desktop`、
  `~/Applications` 与系统目录，家目录会直接走到 trash / Finder 删除路径。
  子目录不受影响（判断只做精确匹配），冒烟测试补了两条断言。
- 剪切之后又用 Finder/其它 App 复制了别的内容，「粘贴」不再移动之前的旧文件：
  剪切时记录剪贴板序号，粘贴时序号变了就把剪切列表判为过期、改用系统剪贴板。
  移动部分失败时只把失败项留在剪切列表里，可直接再粘贴重试（此前不论成败都清空）。
- 文件类型的自定义图标（SF Symbol）真正生效：设置列表、编辑弹窗与 Finder「新建文件」
  子菜单统一按存储的 `icon` 渲染，只有图标为空或不是有效符号时才回退到按扩展名推导的
  默认符号。此前三处都忽略存储值，「选择图标」保存后不显示，「重置图标」也看起来无效。
- 「新建文件」的 DOCX/PPTX 不再生成 0 字节文件：`IClick/Resources/` 新增最小合法
  `template.docx` / `template.pptx` 并加入两个 target，手构建脚本同步复制仓库模板。
  TXT/MD/JSON 仍为空文件（文本格式本身合法）。
- 更新器仓库地址：`anwen/IClick` 恒 404，改为 README 里的 `micolor/IClick`
  （「打开发布页」链接与 README 徽章同步修正）。
- 「下载并安装」不再只认 `.app.zip`：仓库实际只发布 `.dmg`，现在优先用
  `.app.zip`，没有则挂载 `.dmg`、复制其中的 `.app`、卸载映像后再走原有校验与安装。
- 「常用 App」打开目标项只发一次 open 事件（`NSWorkspace.open(_:withApplicationAt:)`）。
  原来是先 `openApplication` 启动应用、0.5 秒后再单独把路径交给它：Terminal 这类
  「启动就开一个窗口」的应用在自身没有窗口时，第一步的 reopen 先开一个空白窗口，
  第二步再开一个目标目录窗口——用户看到的就是「点一次，打开两次」。启动/交付失败时
  仍回退 `/usr/bin/open`。
- 扩展的「主应用存活」标志改为双向校正：扩展启动时主应用没在运行，标志会永久停在
  false，之后即使主应用被拉起，所有点击也会在重试耗尽后静默失败，直到 Finder 重启扩展。
- 子菜单顺序随配置快照一起刷新：调整顺序 / 「重置」后，扩展不需要重启进程就能生效。
- 「重置右键菜单」同时恢复「常用 App」子菜单开关，并去掉一次重复的整份配置保存。
- 设置页「仅选中文件」开关现在能持久化：原来 `load()` 每次都用默认值覆盖。
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
