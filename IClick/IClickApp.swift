//
//  IClickApp.swift
//  IClick
//
//  Created by 李旭 on 2024/4/4.
//
import AppKit
import Foundation
import SwiftUI

import FinderSync
import os.log
import UserNotifications

@main
struct IClickApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    // 必须读 App Group：GROUP 里该键为 1（显示菜单栏图标），standard 里为 0。
    // 改成 standard 会让菜单栏图标消失 —— 这就是之前「UI 变掉了」的真正原因。
    @AppStorage(Key.showMenuBarExtra, store: UserDefaults.group) private var showMenuBarExtra = true

    @AppLog(category: "main")
    private var logger

    @StateObject var appState = AppState.shared

    @StateObject private var updateManager = UpdateManager(
        // 与 README 里的发布页一致；之前写成个人账号 anwen，API 永远 404
        owner: "micolor",
        repo: "IClick",
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    )

    var body: some Scene {
        SettingsWindow(appState: appState, onAppear: {})
            .defaultAppStorage(UserDefaults.group)
            .environmentObject(updateManager)
            .commands { SettingsCommands() }

        // showMenuBarExtra 为 true 时显示菜单条
        MenuBarExtra(
            "Iclick", image: "MenuBar", isInserted: $showMenuBarExtra
        ) {
            MenuBarView()
        }.defaultAppStorage(UserDefaults.group)
    }
}

/// 只为了给 `AppDelegate` 一个「按 id 打开设置窗口」的入口。
///
/// SwiftUI 的 `Window` 场景不向 AppKit 暴露 `openWindow(id:)`；`showSettingsWindow:`
/// 选择器只对 `Settings` 场景有效。`Commands` 里的按钮能拿到 `@Environment(\.openWindow)`，
/// 并且会在主菜单里生成一条带 Cmd+, 的菜单项 —— `AppDelegate` 在启动/重开时
/// 触发这条菜单项即可（见 `openSettingsWindowFromMenu()`）。
struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: Constants.settingsWindowID)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    @AppLog(category: "AppDelegate")
    var logger

    var appState: AppState = .shared
    var isProcessingDelete = false
    /// 粘贴（复制/移动）在后台队列执行：同一时间只允许一个，避免连点把同一个
    /// 剪切缓冲区移动两次、或两个操作互相看到对方写了一半的文件。
    var isProcessingPaste = false
    /// 可靠投递去重：扩展在没收到 ack 时会重发同一条动作消息。
    private var processedMessages = MessageDeduplicator()
    /// 扩展 → 主应用的认证 IPC 服务。
    private var ipcServer: LocalIPCServer?

    var showInDock = SharedSettings.bool(forKey: Key.showInDock)

    /// 发送用户通知。
    /// NSUserNotification / NSUserNotificationCenter 自 macOS 11 起废弃，在新系统上投递已不可靠，
    /// 统一改走 UserNotifications。标题与正文字面量沿用旧实现，用户看到的内容不变。
    func deliverNotification(title: String, informativeText: String) {
        Self.postUserNotification(title: title, informativeText: informativeText)
    }

    /// 不依赖实例状态的版本，供 NSWorkspace 之类的后台回调直接调用
    /// （那些回调不在主线程，也不该为了发一条通知去捕获 @MainActor 的 self）。
    nonisolated static func postUserNotification(title: String, informativeText: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = informativeText

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger(subsystem: subsystem, category: "AppDelegate")
                    .error("发送通知失败: \(error.localizedDescription)")
            }
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 在 app 启动后执行的函数

        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        // 常驻：无窗口的进程会被 macOS 的自动终止（automatic termination）回收，
        // 于是又退回「每次右键冷启动一次」的老路。主应用是 Finder 扩展的后端，
        // 必须一直活着，显式关掉自动终止。
        // 与 applicationShouldTerminateAfterLastWindowClosed 返回 false 是两件事：
        // 那个只管「关掉最后一个窗口」，这个管「系统在空闲时把无窗口进程收走」。
        ProcessInfo.processInfo.disableAutomaticTermination("IClick 需要常驻以服务 Finder 扩展")
        DiagnosticLog.shared.installCrashHandlers()

        // 通知权限：UserNotifications 必须显式授权，否则投递会被静默丢弃。
        // 只在启动时请求一次，系统自身会记住用户的决定。
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let log = Logger(subsystem: subsystem, category: "AppDelegate")
            if let error {
                log.warning("通知授权请求失败: \(error.localizedDescription)")
            } else if !granted {
                log.info("用户未授予通知权限，操作结果将只记录到日志")
            }
        }

        // 首次启动时引导用户启用扩展
        checkAndGuideExtension()

        // 诊断：登录项状态与当前 bundle 路径。
        let currentBundlePath = Bundle.main.bundleURL.path
        logger.info("登录项: enabled=\(LaunchAtLogin.isEnabled), bundle=\(currentBundlePath)")
        DiagnosticLog.shared.write(
            "app launch version=\(Constants.appVersion) bundle=\(currentBundlePath) "
            + "extensionLaunch=\(Self.launchedByExtension) loginLaunch=\(LaunchAtLogin.wasLaunchedAtLogin) "
            + "showInDock=\(showInDock) fda=\(Constants.hasFullDiskAccess)"
        )

        // 登录项按「注册时的 bundle 路径」保存。应用从 DerivedData 挪到 /Applications
        // （或反过来）后，系统仍报告「已启用」，但登录时拉起的是旧路径。旧副本会写同一份
        // SharedSettings.plist，让扩展菜单和主应用内存对不上——表现为「菜单里有、点了没反应」。
        // 这里把登录项重新注册到当前 bundle；哨兵保证只修一次。
        //
        // 只在 /Applications 的副本上做：从 Xcode/DerivedData 直接跑的开发副本绝不能
        // 把开机启动项指到构建目录 —— 那正是这次故障的来源。
        let isInstalledCopy = currentBundlePath.hasPrefix("/Applications/")
        if isInstalledCopy,
           LaunchAtLogin.isEnabled,
           SharedSettings.string(forKey: "loginItemBundlePath") != currentBundlePath {
            LaunchAtLogin.isEnabled = false
            LaunchAtLogin.isEnabled = true
            if LaunchAtLogin.isEnabled {
                SharedSettings.set(currentBundlePath, forKey: "loginItemBundlePath")
                logger.info("登录项已重新注册到当前 bundle")
            } else {
                logger.warning("登录项重新注册失败，登录时将不会自动启动")
                deliverNotification(
                    title: "登录项设置失败",
                    informativeText: "IClick 无法更新开机启动项。请打开设置，把「登录时启动」关掉再重新打开。"
                )
            }
        }

        // 动作与配置都不再走 DNC：动作用认证的本机 socket，配置由扩展直接读快照。
        // DNC 不校验发送方，保留监听只会给伪造消息留入口。
        let server = LocalIPCServer { [weak self] payload in
            Task { @MainActor in
                self?.handleActionPayload(payload)
            }
        }
        server.start()
        ipcServer = server

        // 用户自己启动（Finder 双击 / 启动台 / open）时把设置窗口打开。
        //
        // 设置窗口是 `.defaultLaunchBehavior(.suppressed)` —— 那是为了让扩展的
        // 冷启动不要弹窗。但 suppressed 同时也会让「双击应用」什么都不发生，
        // 而菜单栏图标和程序坞图标都可以被用户关掉；两者叠加就再也没有入口了
        // （实测 `open /Applications/Iclick.app` 后窗口数为 0）。
        //
        // 扩展拉起时带 --launched-by-extension，登录项拉起时识别 wasLaunchedAtLogin，
        // 这两种情况保持不弹窗。异步一拍是为了等 SwiftUI 把主菜单建出来。
        if !Self.launchedByExtension && !LaunchAtLogin.wasLaunchedAtLogin {
            DispatchQueue.main.async { [weak self] in
                self?.openSettingsWindowFromMenu()
            }
        }
    }

    /// 处理经认证 socket 送来的动作。
    /// DNC 通道不处理这些动作：它不校验发送方。
    @MainActor
    private func handleActionPayload(_ payload: MessagePayload) {
        DiagnosticLog.shared.write("ipc action=\(payload.action) rid=\(payload.rid) targets=\(payload.target.count)")
        if !payload.messageID.isEmpty, !processedMessages.accept(payload.messageID) {
            DiagnosticLog.shared.write("duplicate \(payload.messageID) action=\(payload.action)")
            return
        }
        switch payload.action {
        case "open":
            openApp(rid: payload.rid, target: payload.target)
        case "actioning":
            actionHandler(rid: payload.rid, target: payload.target, trigger: payload.trigger)
        case "Create File":
            createFile(rid: payload.rid, target: payload.target)
        case "common-dirs":
            openCommonDirs(target: payload.target)
        case "authorize-dir":
            authorizeDir(target: payload.target)
        case "ping":
            DiagnosticLog.shared.write("ipc ping received")
        default:
            logger.warning("ipc action no matched: \(payload.action)")
        }
    }

    /// 扩展拉起主应用时传的启动参数（见 FinderSyncExt.launchHostApp）。
    static let launchedByExtension = CommandLine.arguments.contains("--launched-by-extension")

    /// 双击已在运行的 Iclick.app、或点程序坞图标时，系统会调用这里。
    /// 应用被扩展冷启动过（窗口是 suppressed 的）也一样要能打开设置窗口。
    ///
    /// 不按 hasVisibleWindows 提前返回：窗口存在但被最小化 / 在别的桌面时，
    /// flag 仍可能是 true，用户看到的就是「双击了没反应」。openWindow(id:)
    /// 对已存在的窗口是幂等的，统一走一遍再把它抬到前面。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindowFromMenu()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// SwiftUI 的 Window 场景没有 AppKit 侧的公开打开接口（`showSettingsWindow:`
    /// 只对 `Settings` 场景有效）。主菜单里那条带 Cmd+, 的「设置」项背后就是
    /// `openWindow(id:)`（见 SettingsCommands），直接触发它的 action。
    ///
    /// Commands 菜单项是 SwiftUI 在启动过程中装进主菜单的，冷启动/重开有可能
    /// 赶在它前面；找不到时重试几次，避免「双击了但没反应」。
    private func openSettingsWindowFromMenu(attempt: Int = 0) {
        if let item = Self.findSettingsMenuItem(in: NSApp.mainMenu),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            bringSettingsWindowFront()
            return
        }

        guard attempt < 10 else {
            logger.warning("找不到设置菜单项，无法打开设置窗口")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.openSettingsWindowFromMenu(attempt: attempt + 1)
        }
    }

    /// 窗口已存在但被最小化、或压在别的窗口后面时，openWindow 不一定把它抬起来。
    private func bringSettingsWindowFront() {
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == Constants.settingsWindowID
            }) {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func findSettingsMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            // 按快捷键而不是标题找：标题会随系统语言变化，Cmd+, 是固定的。
            if item.keyEquivalent == ",", item.keyEquivalentModifierMask.contains(.command) {
                return item
            }
            if let submenu = item.submenu, let found = findSettingsMenuItem(in: submenu) {
                return found
            }
        }
        return nil
    }

    /// 扩展请求授权目录时，弹窗确认后添加
    /// 扩展请求注册目录（无沙盒：直接添加到列表，无需 bookmark）
    func authorizeDir(target: [String], completion: ((Bool) -> Void)? = nil) {
        guard let dirPath = target.first else { return }
        let path = dirPath.removingPercentEncoding ?? dirPath
        let url = URL(fileURLWithPath: path, isDirectory: true)

        if appState.dirs.contains(where: { $0.url.path == path || path.hasPrefix($0.url.path + "/") }) {
            logger.info("目录已注册: \(path)")
            completion?(true)
            return
        }

        let folderName = url.lastPathComponent
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "注册文件夹"
            alert.informativeText = "是否将「\(folderName)」添加到右键菜单监控？\n\n路径：\(path)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "注册")
            alert.addButton(withTitle: "取消")

            if alert.runModal() == .alertFirstButtonReturn {
                self.appState.dirs.append(PermissiveDir(permUrl: url))
                try? self.appState.savePermissiveDir()

                self.logger.info("已注册目录: \(path)")
                completion?(true)
            } else {
                completion?(false)
            }
        }
    }

    func actionHandler(rid: String, target: [String], trigger: String) {
        guard let rcitem = appState.getActionItem(rid: rid) else {
            logger.warning("actionHandler: action not found for rid \(rid)")
            return
        }

        switch rcitem.id {
        case "copy-path":
            copyPath(target)
        case "delete-direct":
            deleteFolderFile(target, trigger)
        case "unhide":
            unhideFilesAndDirs(target, trigger)
        case "hide":
            hideFilesAndDirs(target, trigger)
        case "airdrop":
            showAirDrop(target, trigger)
        case "cut-files":
            cutToPasteboard(target)
        case "paste-files":
            pasteFromClipboard(target, trigger)
        default:
            logger.warning("no action id matched")
        }
    }

    /// 关闭设置窗口不再退出应用。
    ///
    /// 原来返回 true。它的后果不只是「关窗就退出」：应用一旦不在运行，扩展每次
    /// 右键点击都得把它冷启动一次。统一日志实测（2026-09-23 21:42）：30 秒内被拉起
    /// 三次（PID 99506/99509/99517），每次干完活 1~3 秒又自己消失，下一次点击
    /// 扩展再拉一次 —— 用户看到的就是「每点一次右键，应用的界面就弹出来一次」。
    ///
    /// 主应用必须常驻：它是 Finder 扩展的后端，扩展只在它活着时才有得可问
    /// （见 FinderSyncExt.isHostReady —— 标志为 false 时走 launchHostApp + 重试）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 把 80ms 防抖里的配置版本号立刻落盘，否则「改完设置马上退出」时
        // 数据已写入但版本号没递增，扩展会一直认为配置没变。
        AppState.shared.flushPendingConfigChange()
        ipcServer?.stop()
        logger.info("applicationWillTerminate")
    }

    /// 通过 pluginkit 查询扩展状态（FIFinderSyncController 报 false 时的辅助检测）。
    ///
    /// 放在 `nonisolated static` 里是为了能挪到后台队列执行：`Process.waitUntilExit()`
    /// 没有超时，pluginkit 一旦卡住就会把主线程（连同启动路径）一起钉住。
    nonisolated private static func pluginkitReportsExtensionEnabled() -> Bool {
        let extBundleID = "cn.anwen.IClick.FinderSyncExt"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        task.arguments = ["-m", "-v", "-i", extBundleID]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // 检查是否包含 +（已启用）
            return output.contains("+")
        } catch {
            // 归档打包后，沙盒/Hardened Runtime 会限制 Process 执行系统工具
            // Process 执行失败 ≠ 扩展未启用，应乐观假设已启用以避免误报
            Logger(subsystem: subsystem, category: "AppDelegate")
                .warning("pluginkit 执行失败(沙盒限制): \(error.localizedDescription)，跳过检测")
            return true
        }
    }

    /// 每次启动时检查扩展是否已启用，未启用则提醒一次。
    ///
    /// 不要在主线程上同步跑 pluginkit：这条路径紧挨着「打开设置窗口」，
    /// 一旦 pluginkit 卡住，用户看到的就是双击应用没反应。
    private func checkAndGuideExtension() {
        // 登录项启动 / 扩展拉起时不要弹模态框：前者会把用户登录后的第一屏拦住，
        // 后者根本不可能发生在扩展未启用的情况下。
        guard !Self.launchedByExtension, !LaunchAtLogin.wasLaunchedAtLogin else { return }
        // 主检测：FIFinderSyncController 是本地状态查询，很快
        guard !FIFinderSyncController.isExtensionEnabled else { return }

        Task.detached(priority: .utility) { [weak self] in
            let enabled = Self.pluginkitReportsExtensionEnabled()
            guard !enabled else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                self?.showExtensionGuide()
            }
        }
    }

    /// 显示扩展启用引导弹窗（只提醒一次，不循环）
    @MainActor
    private func showExtensionGuide() {
        let alert = NSAlert()
        alert.messageText = "请启用 IClick 扩展"
        alert.informativeText = """
        IClick 需要启用 Finder 扩展才能正常工作。

        请点击下方按钮前往系统设置，找到 IClick 扩展并启用。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        let result = alert.runModal()

        if result == .alertFirstButtonReturn {
            // 打开系统设置（只打开一次，不再检查）
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }
}
