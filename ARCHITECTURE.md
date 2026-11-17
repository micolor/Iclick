# IClick 架构与故障模型

这份文档解释 IClick 为什么是两个进程、数据放在哪里、哪些不变量不能破，以及出了问题该看哪里。

## 1. 两个进程

```
Finder.app
  └─ FinderSyncExt.appex（沙盒）  ── LocalIPC（签名校验） ──▶  Iclick.app（非沙盒，常驻）
        │                                                          │
        │ 读快照                                                    │ 写
        ▼                                                          ▼
  App Group 容器                                             ~/Library/Application Support/IClick/
  └─ SharedSettings-snapshot.plist (主应用写)                   └─ SharedSettings.plist（唯一真源，主应用写）
  └─ CustomIcons/（自定义图标）
  └─ ipc.sock（主应用监听）
```

| 进程 | 职责 | 能写什么 |
| --- | --- | --- |
| `Iclick.app` | 真正的文件操作、设置界面、配置持久化、登录项 | `SharedSettings.plist`、群组容器快照、自定义图标 |
| `FinderSyncExt.appex` | 在 Finder 右键菜单里展示菜单项，把点击转成 IPC 动作 | **什么都不写**（只读消费者） |

**关键不变量：配置只有一个写者。** 扩展是沙盒进程，只读 App Group 容器里的
`SharedSettings-snapshot.plist`（主应用每次落盘时同步写）。快照里带
`ICLICK_CONFIG_VERSION`；扩展每次建菜单前比较版本，发现更新就重新加载。
所以主应用没运行、或推送丢失，扩展也能立刻建出正确的菜单，而不是退回默认项。

## 2. 通信

**不再使用 DistributedNotificationCenter。** 它不校验发送方，任何本机进程都能伪造。

- 扩展 → 主应用：App Group 容器内的 Unix domain socket（`ipc.sock`），
  主应用用 `LOCAL_PEERPID` + `SecCodeCopyGuestWithAttributes` 校验对端代码签名
  （bundle id + Team ID），再处理 `open` / `actioning` / `Create File` /
  `common-dirs` / `authorize-dir` / `ping`。
- 主应用 → 扩展：配置通过快照传递。主应用写配置后递增 `configVersion`；
  扩展在 `menu(for:)` 里调用 `syncFromSnapshotIfNewer()`，版本更高才重新解析。
- 存活判断：扩展在发动作前用本机 `runningApplications` 查主应用是否在跑，
  不在就拉起并重试（最多约 6 秒），不再依赖心跳/退出通知。

**可靠性**：

- **动作消息带 `messageID` 并有 ack**：主应用收到后先回 ack，扩展没收到就重发；
  主应用用 `MessageDeduplicator` 按 ID 去重，删除/移动这类非幂等操作不会重复执行。
- `MessagePayload` 手写了解码，缺字段只影响该字段，不会整条丢弃。
- ack 在动作执行**之前**发出：确认“收到了”，不确认“执行成功了”。

## 3. 用户入口（不能再丢）

应用是 `.accessory`（默认无 Dock 图标）。设置窗口是 `.defaultLaunchBehavior(.suppressed)`，所以窗口不会被自动弹出。入口由以下几条保证：

- 菜单栏图标（可被用户在设置里关掉）
- 程序坞图标（可被关掉）
- **双击 / 重开应用**：`AppDelegate.applicationShouldHandleReopen` 经 `SettingsCommands` 的 Cmd+, 菜单项调用 `openWindow(id:)`
- 扩展拉起主应用时带 `--launched-by-extension`，这时不弹窗；登录项拉起时也不弹窗

改窗口/场景相关代码时，必须保住“双击应用能打开设置窗口”这条。`windowResizability`、`Window`/`Settings` 场景类型、`defaultLaunchBehavior` 都会影响它。

## 4. 生命周期与副本

- 主应用常驻：`disableAutomaticTermination` + `applicationShouldTerminateAfterLastWindowClosed == false`。
- 扩展由 Finder 按需拉起/回收；安装后可能短暂出现两个实例，`scripts/build-local.sh` 会在结束时清掉，Finder 下次右键再拉起一个。
- 登录项按**注册时的 bundle 路径**记录。应用从 DerivedData 搬到 /Applications 后，系统仍显示 enabled 但登录时拉起旧路径。主应用启动时会检查并重指到当前路径（只在 `/Applications` 副本上做，开发副本不参与）。
- LaunchServices 里存在多个同 bundle id 副本时，可能拉起旧副本。诊断与清理命令见第 6 节。

## 5. 数据安全

- 删除走废纸篓（`trashItem`），失败再尝试 Finder；受保护目录（`Utils.isProtectedFolder`）直接拒绝。
- 新建文件名会清洗 `/`、`:`，并校验最终路径仍在目标目录内。
- `AppState.load()` 对每个配置段独立解码。某段失败时：
  - 不做“首次落盘”；
  - 把该键记进 `failedKeys`，后续 `save()` 跳过它，避免用空数组覆盖磁盘上的原始数据。
- 迁移只补缺失键，不覆盖已有值。

## 6. 出问题时看哪里

最快的办法：

```bash
./scripts/collect-diagnostics.sh
```

它会把两份诊断日志、配置、扩展注册状态、旧副本、登录项和进程状态打包到桌面。
注意日志里会包含你操作过的文件路径。

手工命令：

```bash
# 主应用诊断日志（纯文本，2MB 轮转）
~/Library/Application Support/IClick/diagnostics.log

# 扩展诊断日志（在群组容器）
~/Library/Group Containers/group.33WRMMC62L.cn.anwen.IClick/diagnostics-extension.log

# 崩溃：诊断日志里会有一行 "IClick crashed (signal)"；
# 完整崩溃报告在 ~/Library/Logs/DiagnosticReports/

# 扩展注册状态（+ 表示已启用）
pluginkit -m -v -p com.apple.FinderSync | grep -i iclick

# 是否注册了多个应用副本
lsregister -dump | grep -E "^path:.*Iclick.app"

# 登录项实际指向哪里
sfltool dumpbtm | grep -B7 -A2 "Bundle Identifier: cn.anwen.IClick"

# 共享配置
plutil -p ~/Library/Application\ Support/IClick/SharedSettings.plist
```

## 7. 开发与测试

现成的做法（也是开源项目的常规配置）：

- `scripts/build-local.sh`：本机没有 Xcode 许可时的手工构建/安装（必须链接 MacOSX26.5.sdk，否则外观退化）。
- `scripts/smoke-test.sh`：纯逻辑回归测试（消息解码、路径保护、模型编解码），不依赖界面。
- `.github/workflows/ci.yml`：CI 上跑 `xcodebuild` 构建 + smoke test。
- `CHANGELOG.md`：记录用户可见的修复。
- `.github/ISSUE_TEMPLATE/bug_report.md`：报问题时要求附诊断日志。

### 为什么没有 AppState 单测

`AppState` 混合了持久化、迁移、IPC 和 UI 状态，直接单测成本高。当前策略是先测纯函数/模型，再把 `AppState` 拆成 `SettingsStore`（持久化）和 `ConfigSync`（IPC）之后补集成测试。不要在没有测试的情况下对它做大重构。
