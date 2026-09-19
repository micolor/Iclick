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
    let messager = Messager.shared

    @StateObject var appState = AppState.shared

    @StateObject private var updateManager = UpdateManager(
        owner: "anwen",
        repo: "IClick",
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    )

    var body: some Scene {
        SettingsWindow(appState: appState, onAppear: {})
            .defaultAppStorage(UserDefaults.group)
            .environmentObject(updateManager)

        // showMenuBarExtra 为 true 时显示菜单条
        MenuBarExtra(
            "Iclick", image: "MenuBar", isInserted: $showMenuBarExtra
        ) {
            MenuBarView()
        }.defaultAppStorage(UserDefaults.group)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    @AppLog(category: "AppDelegate")
    private var logger

    var appState: AppState = .shared
    private var isProcessingDelete = false

    /// 扩展进程的 bundle id（扩展是独立进程，可以用本地查询判断存活）
    private static let extensionBundleID = "cn.anwen.IClick.FinderSyncExt"

    /// 扩展进程当前是否在运行。
    ///
    /// 这里原本判断的是「最后一次收到扩展心跳是否在 10 秒内」。但扩展现在只在
    /// 启动握手时发心跳（`requestConfigFromApp` 一旦拿到配置就停），所以主应用
    /// 启动超过 10 秒后这个判断恒为 false —— 于是每次启动主应用，
    /// `deliverRunningWithRetry` 都会跑满 5 次重试、把同一份完整配置白发 6 遍
    /// （约 25KB），最后再打一条「配置推送重试已达上限」的 error。
    /// 统一日志实测每次启动必现（5 次启动 5 条，PID 各不相同）。
    ///
    /// 改成直接查进程：主应用无沙盒，`runningApplications` 能看到扩展进程。
    /// 这样「扩展还没起来就重试」的原意得以保留，扩展已在跑时则一次即达。
    ///
    /// 注意别换回通知式的判断：本机 NSWorkspace 的启动/退出通知从不触发，
    /// 只有这个即时查询是可靠的（扩展那边也用同一招）。
    var pluginRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.extensionBundleID }
    }

    let messager = Messager.shared
    var showInDock = SharedSettings.bool(forKey: Key.showInDock)

    /// 发送用户通知。
    /// NSUserNotification / NSUserNotificationCenter 自 macOS 11 起废弃，在新系统上投递已不可靠，
    /// 统一改走 UserNotifications。标题与正文字面量沿用旧实现，用户看到的内容不变。
    func deliverNotification(title: String, informativeText: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = informativeText

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        // 回调在任意队列，不捕获 self（AppDelegate 是 @MainActor），避免并发隔离问题
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

        messager.on(name: Key.messageFromFinder) { payload in
            self.logger.info("recive mess from finder by app \(payload.description)")
            switch payload.action {
            case "open":
                self.openApp(rid: payload.rid, target: payload.target)
            case "actioning":
                self.actionHandler(rid: payload.rid, target: payload.target, trigger: payload.trigger)
            case "Create File":
                self.createFile(rid: payload.rid, target: payload.target)
            case "common-dirs":
                self.openCommonDirs(target: payload.target)
            case "heartbeat":
                // 响应时发送完整配置数据，确保扩展有最新设置
                self.sendConfigToExtension()
            case "authorize-dir":
                self.authorizeDir(target: payload.target)
            default:
                self.logger.warning("actioning payload no matched")
            }
        }
        sendObserveDirMessage()
        
    }
    
    func openCommonDirs(target: [String]) {
        for dirPath in target {
            let path = dirPath.removingPercentEncoding ?? dirPath
            openInFinder(path: path)
        }
    }

    /// 打开目录：NSWorkspace.open → /usr/bin/open（无需沙盒授权）
    @discardableResult
    private func openInFinder(path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            logger.warning("路径不存在或不是目录: \(path, privacy: .public)")
            return false
        }

        // 第 1 层：NSWorkspace.open
        if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            return true
        }

        // 第 2 层：/usr/bin/open
        logger.debug("NSWorkspace.open 失败，回退 /usr/bin/open: \(path, privacy: .public)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [path]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return true
            }
        } catch {
            logger.error("打开目录失败 \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    /// 调用 AppleScript 子程序所需的 AppleEvent 常量。
    /// 它们在 AppleScript.h / OpenScripting.h 里，Swift 侧不自动可见；直接写 FourCC
    /// 字面量，免得为了这几个常量去 `import Carbon`（那会把整个 Carbon 拖进来）。
    private enum ASEvent {
        static let applescriptSuite: FourCharCode = 0x6173_6372 // 'ascr' kASAppleScriptSuite
        static let subroutine: FourCharCode = 0x7073_6272       // 'psbr' kASSubroutineEvent
        static let subroutineName: FourCharCode = 0x736E_616D   // 'snam' keyASSubroutineName
    }

    /// 只编译一次的 Finder 删除脚本。
    ///
    /// 路径是通过 AppleEvent 参数传进去的，**不是拼进脚本源码**，所以：
    /// 1. 不需要手工转义反斜杠/引号（原来那两行 replaceOccurrences 已删掉，
    ///    含引号的文件名也不会再把脚本拼坏）；
    /// 2. 只编译这一次。原来每个路径都 `NSAppleScript(source:)` 新建一个 ——
    ///    在批量删除的循环里就是 N 次编译 + N 次 Finder IPC，全部压在主线程上。
    ///
    /// 线程说明：NSAppleScript 不是线程安全的。这里只由 `deleteFolderFile` 调用，
    /// 而它经 `Messager` 的 `DispatchQueue.main.async` 进来，始终在主线程串行执行。
    private static let finderDeleteScript: NSAppleScript? = {
        // `set f to POSIX file p` 必须留在 tell 块**外面**。
        // 写成 `tell application "Finder" to delete (POSIX file p)` 时，AppleScript 会把
        // `POSIX file` 当成 Finder 的元素去解析，直接报 -1728「Can't get POSIX file ...」——
        // 实测四种写法，只有把强制转换提到 tell 之外（或写成 `p as POSIX file`）能通过。
        // 原来的实现是顶层一句 tell、路径又是源码字面量，所以没踩到这个坑。
        let source = """
        on iclickDelete(p)
            set f to POSIX file p
            tell application "Finder" to delete f
        end iclickDelete
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        return error == nil ? script : nil
    }()

    /// 通过 AppleScript 让 Finder 删除文件（绕过沙盒限制）
    @discardableResult
    private func deleteViaFinder(path: String) -> Bool {
        guard let script = Self.finderDeleteScript else {
            logger.error("deleteViaFinder AppleScript 不可用: \(path)")
            return false
        }

        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(ASEvent.applescriptSuite),
            eventID: AEEventID(ASEvent.subroutine),
            targetDescriptor: nil,
            returnID: AEReturnID(-1),       // kAutoGenerateReturnID
            transactionID: AETransactionID(0) // kAnyTransactionID
        )
        event.setParam(NSAppleEventDescriptor(string: "iclickDelete"),
                       forKeyword: AEKeyword(ASEvent.subroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: path), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var error: NSDictionary?
        script.executeAppleEvent(event, error: &error)
        if let error = error {
            logger.error("deleteViaFinder 执行失败: \(error), path: \(path)")
            return false
        }
        logger.info("deleteViaFinder 已删除: \(path)")
        return true
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

                // 主应用无沙盒，始终观察整个文件系统
                self.messager.sendMessage(name: "running", data: self.buildRunningPayload(target: ["/"]))
                self.logger.info("已注册目录: \(path)")
                completion?(true)
            } else {
                completion?(false)
            }
        }
    }

    /// 重试计数。只在「开始一次新的推送序列」时复位。
    /// 不复位的话，上一次把 5 次耗尽之后，后续任何调用都不会再安排重试，
    /// 扩展先于主应用启动时就会永远收不到配置。
    private var observeRetryCount = 0

    /// 开始观测并推送配置（有限次重试，等待扩展就绪）
    func sendObserveDirMessage() {
        observeRetryCount = 0
        deliverRunningWithRetry()
    }

    /// 向扩展推送当前配置
    func sendConfigToExtension() {
        observeRetryCount = 0
        if pluginRunning {
            // 扩展刚回过心跳，一次即达
            sendRunningMessage()
        } else {
            deliverRunningWithRetry()
        }
    }

    /// 单次「running」消息：主应用无沙盒，始终观察整个文件系统
    private func sendRunningMessage() {
        messager.sendMessage(name: "running", data: buildRunningPayload(target: ["/"]))
    }

    /// 推送配置，未收到心跳时每 3 秒重试，最多 5 次
    private func deliverRunningWithRetry() {
        sendRunningMessage()

        // 扩展已回心跳 → 配置已送达，无需继续重试
        guard !pluginRunning else {
            observeRetryCount = 0
            return
        }
        guard observeRetryCount < 5 else {
            logger.warning("配置推送重试已达上限，放弃")
            return
        }
        observeRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.deliverRunningWithRetry()
        }
    }

    /// 构建包含配置数据的 running 消息
    private func buildRunningPayload(target: [String]) -> MessagePayload {
        // 序列化 SharedSettings 为 JSON（Data 值转 base64）
        let allConfig = SharedSettings.exportAllForIPC()
        let configJSON: String?
        if let jsonData = try? JSONSerialization.data(withJSONObject: allConfig, options: .fragmentsAllowed),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            configJSON = jsonStr
        } else {
            logger.warning("Failed to serialize config for IPC")
            configJSON = nil
        }
        return MessagePayload(action: "running", target: target, configJSON: configJSON)
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

    func showAirDrop(_ target: [String], _ trigger: String) {
        logger.info("---- showAirDrop  trigger:\(trigger)")
        let fm = FileManager.default
        var fileURLs: [URL] = []

        if trigger == "ctx-container" {
            // 显示警告对话框
            let alert = NSAlert()
            alert.messageText = "警告"
            alert.informativeText = "无法共享当前文件夹，请选择文件或子文件夹进行共享。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }

        for item in target {
            let decodedPath = item.removingPercentEncoding ?? item
            logger.info("airdrop path \(decodedPath)")

            if Utils.isProtectedFolder(decodedPath) {
                // 显示警告对话框
                let alert = NSAlert()
                alert.messageText = "警告"
                alert.informativeText = "无法分享系统保护文件夹：\(decodedPath)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "确定")
                alert.runModal()

                logger.warning("试图分享受保护的系统文件夹，操作已被阻止: \(decodedPath)")
                continue
            }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: decodedPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    logger.warning("不能通过 AirDrop 分享文件夹: \(decodedPath)")
                    let alert = NSAlert()
                    alert.messageText = "提示"
                    alert.informativeText = "不能通过 AirDrop 分享文件夹：\(decodedPath)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "确定")
                    alert.runModal()
                    continue
                } else {
                    fileURLs.append(URL(fileURLWithPath: decodedPath))
                }
            }
        }

        if !fileURLs.isEmpty {
            if let airDropService = NSSharingService(named: .sendViaAirDrop) {
                airDropService.perform(withItems: fileURLs)
                logger.info("已通过 AirDrop 分享文件: \(fileURLs.map { $0.path }.joined(separator: ", "))")
            } else {
                logger.warning("无法获取 AirDrop 服务")
            }
        }
    }

    // 显示目标文件夹下的隐藏的所有文件和文件夹
    func unhideFilesAndDirs(_ target: [String], _ trigger: String) {
        logger.info("开始取消隐藏文件和目录，目标路径: \(target), 触发器: \(trigger)")
        let decodedTarget = target.map { $0.removingPercentEncoding ?? $0 }

        if trigger == "ctx-items" {
            for path in decodedTarget {
                self.setFileHidden(path: path, hidden: false)
            }
        } else {
            guard let dirPath = decodedTarget.first else { return }
            self.setDirContentsHidden(dirPath: dirPath, hidden: false)
        }
        logger.info("取消隐藏操作完成")
    }

    // 隐藏目标文件或文件夹
    func hideFilesAndDirs(_ target: [String], _ trigger: String) {
        logger.info("开始隐藏文件和目录，目标路径: \(target), 触发器: \(trigger)")
        let decodedTarget = target.map { $0.removingPercentEncoding ?? $0 }

        if trigger == "ctx-items" {
            for path in decodedTarget {
                if Utils.isProtectedFolder(path) {
                    logger.warning("跳过受保护的文件路径: \(path)")
                    continue
                }
                self.setFileHidden(path: path, hidden: true)
            }
        } else {
            guard let dirPath = decodedTarget.first else { return }
            // 容器菜单（在文件夹空白处右键）走的是这条分支：会批量改该目录下
            // **所有**子项的 hidden 标志。上面 ctx-items 分支拦了受保护路径，这里漏了——
            // 对 /Applications 这类目录执行，Finder 里看起来就像被清空了。
            // 注：unhide 有意不加这道拦截，它是「误隐藏」之后的恢复路径，
            // 拦掉反而会把人困住。
            if Utils.isProtectedFolder(dirPath) {
                logger.warning("跳过受保护的目录路径: \(dirPath)")
                return
            }
            self.setDirContentsHidden(dirPath: dirPath, hidden: true)
        }
        logger.info("隐藏操作完成")
    }

    /// 设置目录下所有内容的隐藏状态（不含目录自身）
    private func setDirContentsHidden(dirPath: String, hidden: Bool) {
        let action = hidden ? "隐藏" : "取消隐藏"
        if setDirContentsResourceValuesHidden(dir: URL(fileURLWithPath: dirPath), hidden: hidden) {
            logger.info("\(action)目录内容操作完成: \(dirPath)")
        }
    }

    /// 使用 FileManager 设置目录内容的隐藏状态
    private func setDirContentsResourceValuesHidden(dir: URL, hidden: Bool) -> Bool {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants])
        } catch {
            logger.warning("读取目录内容失败: \(dir.path), error: \(error.localizedDescription)")
            return false
        }

        // 每个条目单独 try。原先 `try` 在循环内、`catch` 在循环外，第一项失败
        // （只读卷、或对该目录没有写权限——设置 hidden 标志需要父目录的写权限）
        // 就会中止整个循环，后面的条目一个都不处理；而且失败只打 .debug
        // （默认不落盘），用户看到的就是「点了没反应」。现在逐项兜住并汇报失败数。
        var failed = 0
        for case var fileURL in contents {
            var values = URLResourceValues()
            values.isHidden = hidden
            do {
                try fileURL.setResourceValues(values)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            logger.warning("目录内容设置失败 \(failed)/\(contents.count) 项: \(dir.path)")
            return false
        }
        return true
    }

    /// 设置单个文件/目录的隐藏状态
    private func setFileHidden(path: String, hidden: Bool) {
        let action = hidden ? "隐藏" : "取消隐藏"
        if setHiddenFlag(path: path, hidden: hidden) {
            logger.info("\(action)成功: \(path)")
        }
    }

    /// 设置文件隐藏标志
    private func setHiddenFlag(path: String, hidden: Bool) -> Bool {
        do {
            var fileURL = URL(fileURLWithPath: path)
            var values = URLResourceValues()
            values.isHidden = hidden
            try fileURL.setResourceValues(values)
            return true
        } catch {
            logger.debug("setResourceValues 失败: \(path), error: \(error.localizedDescription)")
            return false
        }
    }


    /// 复制路径到剪贴板。
    ///
    /// 多选时**只复制第一个**路径，这是有意为之（2026-09-19 与用户确认过）。
    /// 看起来像漏了 `joined(separator:)`，但「剪切」那边多选拼全部、这边只取一条，
    /// 是两套刻意区分的行为 —— 别再当成 bug 改成复制全部。
    func copyPath(_ target: [String]) {
        if let dirPath = target.first {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(dirPath.removingPercentEncoding ?? dirPath, forType: .string)
        }
    }

    /// 剪切文件：将选中文件路径存入剪切板，等待粘贴
    func cutToPasteboard(_ target: [String]) {
        logger.info("---- cutToPasteboard  target:\(target)")
        // 解码路径后存储，确保与授权目录路径格式一致
        let decodedTargets = target.map { $0.removingPercentEncoding ?? $0 }
        SharedSettings.set(decodedTargets, forKey: Key.actions + ".cut-files")
        // 同时写入选贴板：文件 URL（Finder 可识别） + 路径文本
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = decodedTargets.map { URL(fileURLWithPath: $0) }
        pasteboard.writeObjects(urls as [NSURL])
        // 也保留路径文本作为后备
        let paths = decodedTargets.joined(separator: "\n")
        pasteboard.setString(paths, forType: .string)

        // 显示通知
        deliverNotification(
            title: "已剪切 \(target.count) 项",
            informativeText: "在目标 Finder 窗口按 ⌘⌥V 粘贴，或使用右键菜单「粘贴」"
        )
    }

    /// 从系统剪贴板读取文件 URL 列表（来自 Finder Cmd+C 复制）
    private func readFileURLsFromSystemPasteboard() -> [String] {
        let pasteboard = NSPasteboard.general

        // 方式1：通过 readObjects 读取 NSURL
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            return urls.map { $0.path }
        }

        // 方式2：通过 .fileURL 类型读取 file:// URL 字符串。
        // propertyList(forType: .fileURL) 返回的是**单个 String**，不是数组
        // （实测：往该类型写 String 取回 __NSCFConstantString，写 [String] 则返回 nil），
        // 所以原来那句 `as? [String]` 恒为 nil —— 这条回退分支从来没生效过。
        if let plist = pasteboard.propertyList(forType: .fileURL) {
            var strings: [String] = []
            if let one = plist as? String {
                strings = [one]
            } else if let many = plist as? [String] {
                strings = many
            }
            // 只认 file:// —— URL(string:).path 对 https:// 也会给出一个看起来像路径的值
            let paths = strings.compactMap { str -> String? in
                guard let url = URL(string: str), url.isFileURL else { return nil }
                return url.path
            }
            if !paths.isEmpty { return paths }
        }

        // 方式3：通过 .string 类型读取路径文本
        if let text = pasteboard.string(forType: .string) {
            let paths = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            if paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                return paths
            }
        }

        return []
    }

    /// 粘贴文件：支持 IClick 剪切（移动）和系统复制（拷贝）
    func pasteFromClipboard(_ target: [String], _ trigger: String) {
        logger.info("---- pasteFromClipboard  target:\(target) trigger:\(trigger)")

        // 1. 先检查 IClick 自定义剪切存储（移动操作）
        var filesToOperate: [String] = []
        var isCutOperation = false

        if let cutFiles = SharedSettings.stringArray(forKey: Key.actions + ".cut-files"),
           !cutFiles.isEmpty {
            filesToOperate = cutFiles.map { $0.removingPercentEncoding ?? $0 }
            isCutOperation = true
        } else {
            // 2. 回退到系统剪贴板（Finder Cmd+C 复制操作）
            filesToOperate = readFileURLsFromSystemPasteboard()
            isCutOperation = false
        }

        guard !filesToOperate.isEmpty else {
            logger.warning("没有要粘贴的文件")
            let alert = NSAlert()
            alert.messageText = "无法粘贴"
            alert.informativeText = "请先使用「剪切」选中要移动的文件，或使用「拷贝」（Cmd+C）复制文件后粘贴。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }

        // 获取目标文件夹路径
        let rawDest: String
        if trigger == "ctx-container" || trigger == "toolbar" {
            guard let dirPath = target.first else {
                logger.warning("未获取到目标文件夹路径")
                return
            }
            rawDest = dirPath.removingPercentEncoding ?? dirPath
        } else {
            guard let filePath = target.first else { return }
            rawDest = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        }

        // 无沙盒：直接使用文件路径
        let fm = FileManager.default
        let destBaseURL = URL(fileURLWithPath: rawDest)
        try? fm.createDirectory(at: destBaseURL, withIntermediateDirectories: true)

        var successCount = 0
        var failCount = 0

        for filePath in filesToOperate {
            let sourceURL = URL(fileURLWithPath: filePath)
            let fileName = sourceURL.lastPathComponent
            let destItemURL = destBaseURL.appendingPathComponent(fileName)

            // 文件名冲突时添加序号。
            // ext / nameWithoutExt 是循环不变量，移出循环只算一次。
            let ext = sourceURL.pathExtension
            let nameWithoutExt = (!ext.isEmpty && fileName.hasSuffix("." + ext))
                ? String(fileName.dropLast(ext.count + 1))
                : fileName
            var finalURL = destItemURL
            var counter = 1
            while fm.fileExists(atPath: finalURL.path) {
                // 无扩展名时不能再补那个「.」，否则 "Photos" 会变成 "Photos 1."（尾随点号）。
                // createFile 里的写法（"\(baseName)\(counter)\(safeExt)"）就没有这个点。
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                finalURL = destBaseURL.appendingPathComponent("\(nameWithoutExt) \(counter)\(suffix)")
                counter += 1
            }

            do {
                if isCutOperation {
                    try fm.moveItem(at: sourceURL, to: finalURL)
                    logger.info("移动成功: \(filePath) → \(finalURL.path)")
                } else {
                    try fm.copyItem(at: sourceURL, to: finalURL)
                    logger.info("复制成功: \(filePath) → \(finalURL.path)")
                }
                successCount += 1
            } catch {
                failCount += 1
                logger.error("\(isCutOperation ? "移动" : "复制")失败: \(filePath) -> \(error.localizedDescription)")
            }
        }

        // 清理 IClick 自定义剪切存储
        if isCutOperation {
            SharedSettings.removeObject(forKey: Key.actions + ".cut-files")
        }

        if failCount == 0 {
            deliverNotification(
                title: isCutOperation ? "粘贴完成" : "复制完成",
                informativeText: isCutOperation
                    ? "已移动 \(successCount) 项到目标目录"
                    : "已复制 \(successCount) 项到目标目录"
            )
        } else {
            deliverNotification(
                title: isCutOperation ? "粘贴完成（部分失败）" : "复制完成（部分失败）",
                informativeText: "成功 \(successCount) 项，失败 \(failCount) 项"
            )
        }
    }


    func deleteFolderFile(_ target: [String], _ trigger: String) {
        // 防止重入：在模态弹窗期间收到新的删除请求时直接忽略
        guard !isProcessingDelete else {
            logger.warning("deleteFolderFile 正在处理中，忽略重复请求")
            return
        }
        isProcessingDelete = true
        defer { isProcessingDelete = false }

        logger.info("---- deleteFolderFile  trigger:\(trigger)")
        if trigger == "ctx-container" {
            let alert = NSAlert()
            alert.messageText = "警告"
            alert.informativeText = "无法删除当前文件夹，请选择文件或子文件夹进行删除。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }

        var failedItems: [String] = []

        for item in target {
            let decodedPath = item.removingPercentEncoding ?? item

            if Utils.isProtectedFolder(decodedPath) {
                let alert = NSAlert()
                alert.messageText = "警告"
                alert.informativeText = "无法删除系统保护文件夹：\(decodedPath)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "确定")
                alert.runModal()
                logger.warning("试图删除受保护的系统文件夹，操作已被阻止: \(decodedPath)")
                continue
            }

            // 1. 移入废纸篓（可恢复），不再用 removeItem 做不可逆的永久删除
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: decodedPath), resultingItemURL: nil)
                logger.info("已移入废纸篓: \(decodedPath)")
                continue
            } catch {
                logger.warning("移入废纸篓失败，回退 Finder: \(decodedPath), error: \(error.localizedDescription)")
            }

            // 2. 通过 AppleScript 让 Finder 删除（同样进废纸篓）
            if deleteViaFinder(path: decodedPath) {
                logger.info("通过 Finder 删除成功: \(decodedPath)")
                continue
            }

            failedItems.append(decodedPath)
        }

        // 3. 两条路径都失败时明确告知用户，不再静默失败
        if !failedItems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "删除失败"
            alert.informativeText = "以下项目无法删除：\n" + failedItems.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    func createFile(rid: String, target: [String]) {
        logger.info("createFile called with rid: \(rid), target: \(target)")
        guard let rcitem = appState.getFileType(rid: rid), let dirPath = target.first else {
            logger.warning("createFile: file type not found \(rid)")
            return
        }
        let decodedDir = dirPath.removingPercentEncoding ?? dirPath
        _ = doCreateFile(in: URL(fileURLWithPath: decodedDir), rcitem: rcitem, ext: rcitem.ext)
    }

    /// 在指定目录中创建文件
    private func doCreateFile(in dirURL: URL, rcitem: NewFile, ext: String) -> Bool {
        // 名称/后缀都来自可编辑的模板配置，必须清洗掉路径分隔符。
        // 否则 defaultName 为 "a/b" 时会写到子目录，".." 时会写到目标目录之外。
        let cleanedName = rcitem.defaultName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let baseName = (cleanedName.isEmpty || cleanedName.allSatisfy { $0 == "." }) ? "未命名" : cleanedName

        let rawExt = ext.hasPrefix(".") || ext.isEmpty ? ext : ".\(ext)"
        let safeExt = rawExt
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ":", with: "")

        let fileName = "\(baseName)\(safeExt)"
        var fileURL = dirURL.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = dirURL.appendingPathComponent("\(baseName)\(counter)\(safeExt)")
            counter += 1
        }

        // 兜底校验：最终路径必须仍在目标目录内
        let dirPrefix = dirURL.standardizedFileURL.path + "/"
        guard fileURL.standardizedFileURL.path.hasPrefix(dirPrefix) else {
            logger.error("拒绝在目标目录之外创建文件: \(fileURL.path)")
            return false
        }

        do {
            if let templateUrl = rcitem.template {
                try FileManager.default.copyItem(at: templateUrl, to: fileURL)
            } else if let defaultTemplateURL = Bundle.main.url(forResource: "template", withExtension: ext.replacingOccurrences(of: ".", with: "")) {
                try FileManager.default.copyItem(at: defaultTemplateURL, to: fileURL)
            } else {
                try Data().write(to: fileURL)
            }
            logger.info("已创建文件: \(fileURL.path)")
            return true
        } catch {
            logger.error("文件创建失败: \(fileURL.path), error: \(error.localizedDescription)")
            return false
        }
    }


    // MARK: - 打开应用

    func openApp(rid: String, target: [String]) {
        guard let rcitem = appState.getAppItem(rid: rid) else {
            logger.warning("openApp: app not found \(rid)")
            return
        }

        for dirPath in target {
            let decodedPath = dirPath.removingPercentEncoding ?? dirPath
            doOpenApp(rcitem: rcitem, url: URL(fileURLWithPath: decodedPath, isDirectory: true))
        }
    }

    /// 执行打开应用操作
    private func doOpenApp(rcitem: OpenWithApp, url dir: URL) {
        let appURL = resolveAppURL(rcitem.url)
        let appName = appURL.deletingPathExtension().lastPathComponent
        let bundleID = readBundleIdentifier(from: appURL)
        let log = logger
        logger.info("打开目录: \(dir.path), 应用: \(appName), bundleID: \(bundleID ?? "nil")")

        let config = NSWorkspace.OpenConfiguration()
        config.promptsUserIfNeeded = false
        config.arguments = rcitem.arguments
        config.environment = rcitem.environment

        // Step 1: 启动应用。NSWorkspace.openApplication 是沙箱兼容的 API
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { runningApp, error in
            if let error = error {
                log.error("启动应用失败: \(appName), \(error.localizedDescription)")
                return
            }
            log.info("应用已启动: \(runningApp?.localizedName ?? appName)")

            // Step 2: 应用已运行，用 open 发送目录——此时不会触发 Cryptexes 可执行文件访问
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                if let bid = bundleID {
                    process.arguments = ["-b", bid, dir.path]
                } else {
                    process.arguments = ["-a", appName, dir.path]
                }
                process.terminationHandler = { proc in
                    if proc.terminationStatus == 0 {
                        log.info("成功在 \(appName) 中打开: \(dir.path)")
                    } else {
                        log.error("发送目录失败, exit code: \(proc.terminationStatus)")
                    }
                }
                try? process.run()
            }
        }
    }

    /// 从应用包读取 CFBundleIdentifier
    private func readBundleIdentifier(from appURL: URL) -> String? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlistURL),
              let bundleID = info["CFBundleIdentifier"] as? String else {
            return nil
        }
        return bundleID
    }

    /// 将应用 URL 解析为 NSWorkspace 可用的规范路径
    /// macOS 15 中系统应用（Safari 等）位于 /System/Volumes/Preboot/Cryptexes/ 安全卷，
    /// 沙箱无法直接访问该路径。从 URL 提取应用名后在标准位置查找。
    private func resolveAppURL(_ url: URL) -> URL {
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path

        // 1. Cryptexes 路径：提取应用名在标准位置查找
        if path.contains("/Cryptexes/") {
            let appName = URL(fileURLWithPath: path).lastPathComponent  // "Safari.app"
            let searchPaths = [
                "/Applications/\(appName)",
                "/System/Applications/\(appName)",
                "/System/Applications/Utilities/\(appName)",
            ]
            for searchPath in searchPaths {
                if FileManager.default.fileExists(atPath: searchPath) {
                    logger.info("resolveAppURL: Cryptexes → \(searchPath)")
                    return URL(fileURLWithPath: searchPath)
                }
            }
            logger.warning("resolveAppURL: 未找到 \(appName) 的标准路径")
        }

        // 2. 非 Cryptexes 路径：尝试通过 bundle identifier 获取规范路径
        if let bundle = Bundle(url: URL(fileURLWithPath: path)),
           let bundleID = bundle.bundleIdentifier,
           let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return found
        }

        // 3. 降级：使用原始 URL
        return url
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        messager.sendMessage(name: "quit", data: MessagePayload(action: "quit", target: [], trigger: "unknown"))
        logger.info("applicationWillTerminate")
    }

    /// 检查扩展是否已启用（使用 FIFinderSyncController 和 pluginkit 双重验证）
    private var isExtensionEnabled: Bool {
        // 主检测：FIFinderSyncController 系统 API
        if FIFinderSyncController.isExtensionEnabled { return true }

        // 辅助检测：通过 pluginkit 查询扩展状态（先按协议，再按 bundle ID）
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
            logger.warning("pluginkit 执行失败(沙盒限制): \(error.localizedDescription)，跳过检测")
            return true
        }
    }

    /// 每次启动时检查扩展是否已启用，未启用则提醒一次
    private func checkAndGuideExtension() {
        // 已启用则跳过
        guard !isExtensionEnabled else { return }

        // 延迟弹窗，等应用完全启动
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.showExtensionGuide()
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
