//
//  IClickApp.swift
//  IClick
//
//  Created by 李旭 on 2024/4/4.
//
import AppKit
import Foundation
import SwiftUI
import SwiftData

import FinderSync
import os.log

@main
struct IClickApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    @AppStorage(Key.showMenuBarExtra, store: .group) private var showMenuBarExtra = true

    @AppLog(category: "main")
    private var logger
    let messager = Messager.shared

    @StateObject var appState = AppState.shared

    #if !APP_STORE
    @StateObject private var updateManager = UpdateManager(
        owner: "anwen",
        repo: "IClick",
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    )
    #endif

    var body: some Scene {
        SettingsWindow(appState: appState, onAppear: {})
            .defaultAppStorage(.group)
            #if !APP_STORE
            .environmentObject(updateManager)
            #endif
            .modelContainer(SharedDataManager.sharedModelContainer)

        // showMenuBarExtra 为 true 时显示菜单条
        MenuBarExtra(
            "Iclick", image: "MenuBar", isInserted: $showMenuBarExtra
        ) {
            MenuBarView()
        }.defaultAppStorage(.group)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    @AppLog(category: "AppDelegate")
    private var logger

    var appState: AppState = .shared
    var pluginRunning: Bool = false
    private var isProcessingDelete = false

    let messager = Messager.shared
    var showInDock = UserDefaults.group.bool(forKey: Key.showInDock)

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 在 app 启动后执行的函数

        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
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
                self.pluginRunning = true
            case "authorize-dir":
                self.authorizeDir(target: payload.target)
            default:
                self.logger.warning("actioning payload no matched")
            }
        }
        sendObserveDirMessage()
        
    }
    
    func openCommonDirs(target: [String]) {
        NSLog("[IClick-App] ===== openCommonDirs 被调用 =====")
        NSLog("[IClick-App] target=\(target)")
        for dirPath in target {
            let path = dirPath.removingPercentEncoding ?? dirPath
            NSLog("[IClick-App] 正在尝试打开: \(path)")
            openInFinder(path: path)
        }
    }

    /// 打开目录：NSWorkspace.open → /usr/bin/open（无需沙盒授权）
    @discardableResult
    private func openInFinder(path: String) -> Bool {
        NSLog("[IClick-App] openInFinder: path=\(path)")

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            NSLog("[IClick-App] ❌ 路径不存在或不是目录: \(path)")
            return false
        }

        // 第 1 层：NSWorkspace.open
        if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            NSLog("[IClick-App] ✓ NSWorkspace.open 成功")
            return true
        }

        // 第 2 层：/usr/bin/open
        NSLog("[IClick-App] 尝试 /usr/bin/open")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [path]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                NSLog("[IClick-App] ✓ /usr/bin/open 成功")
                return true
            }
        } catch {
            NSLog("[IClick-App] ❌ /usr/bin/open 失败: \(error.localizedDescription)")
        }
        return false
    }

    /// 通过 AppleScript 让 Finder 删除文件（绕过沙盒限制）
    @discardableResult
    private func deleteViaFinder(path: String) -> Bool {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Finder\" to delete (POSIX file \"\(escaped)\")"
        guard let script = NSAppleScript(source: source) else {
            logger.error("deleteViaFinder AppleScript 创建失败: \(path)")
            return false
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            logger.error("deleteViaFinder AppleScript 执行失败: \(error), path: \(path)")
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

                let observeDirs = self.appState.dirs.map { $0.url.path }
                self.messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: observeDirs))

                self.logger.info("已注册目录: \(path)")
                completion?(true)
            } else {
                completion?(false)
            }
        }
    }

    func sendObserveDirMessage() {
        let target: [String]
        if appState.fullDiskAccess {
            target = ["/"]
        } else {
            target = appState.dirs.map { $0.url.path() }
        }

        messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: target))
        if !pluginRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.sendObserveDirMessage()
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
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants])
            for case var fileURL in contents {
                var values = URLResourceValues()
                values.isHidden = hidden
                try fileURL.setResourceValues(values)
            }
            return true
        } catch {
            logger.debug("setResourceValues 目录内容失败: \(dir.path), error: \(error.localizedDescription)")
            return false
        }
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


    func copyPath(_ target: [String]) {
        if let dirPath = target.first {
            let pasteboard = NSPasteboard.general
            // must do to fix bug
            pasteboard.clearContents()

            pasteboard.setString(dirPath.removingPercentEncoding ?? dirPath, forType: .string)
        }
    }

    /// 剪切文件：将选中文件路径存入剪切板，等待粘贴
    func cutToPasteboard(_ target: [String]) {
        logger.info("---- cutToPasteboard  target:\(target)")
        // 解码路径后存储，确保与授权目录路径格式一致
        let decodedTargets = target.map { $0.removingPercentEncoding ?? $0 }
        UserDefaults.group.set(decodedTargets, forKey: Key.actions + ".cut-files")
        // 同时写入选贴板：文件 URL（Finder 可识别） + 路径文本
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = decodedTargets.map { URL(fileURLWithPath: $0) }
        pasteboard.writeObjects(urls as [NSURL])
        // 也保留路径文本作为后备
        let paths = decodedTargets.joined(separator: "\n")
        pasteboard.setString(paths, forType: .string)

        // 显示通知
        let notification = NSUserNotification()
        notification.title = "已剪切 \(target.count) 项"
        notification.informativeText = "在目标 Finder 窗口按 ⌘⌥V 粘贴，或使用右键菜单「粘贴」"
        NSUserNotificationCenter.default.deliver(notification)
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

        // 方式2：通过 .fileURL 类型读取 file:// URL 字符串
        if let fileURLStrings = pasteboard.propertyList(forType: .fileURL) as? [String] {
            return fileURLStrings.compactMap { URL(string: $0)?.path }
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

        if let cutFiles = UserDefaults.group.stringArray(forKey: Key.actions + ".cut-files"),
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

            // 文件名冲突时添加序号
            var finalURL = destItemURL
            var counter = 1
            while fm.fileExists(atPath: finalURL.path) {
                let ext = sourceURL.pathExtension
                let nameWithoutExt = fileName.hasSuffix("." + ext) ? String(fileName.dropLast(ext.count + 1)) : fileName
                finalURL = destBaseURL.appendingPathComponent("\(nameWithoutExt) \(counter).\(ext)")
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
            UserDefaults.group.removeObject(forKey: Key.actions + ".cut-files")
        }

        let notification = NSUserNotification()
        if failCount == 0 {
            notification.title = isCutOperation ? "粘贴完成" : "复制完成"
            notification.informativeText = isCutOperation
                ? "已移动 \(successCount) 项到目标目录"
                : "已复制 \(successCount) 项到目标目录"
        } else {
            notification.title = isCutOperation ? "粘贴完成（部分失败）" : "复制完成（部分失败）"
            notification.informativeText = "成功 \(successCount) 项，失败 \(failCount) 项"
        }
        NSUserNotificationCenter.default.deliver(notification)
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

            // 1. 直接 FileManager 删除（无沙盒限制）
            if (try? FileManager.default.removeItem(atPath: decodedPath)) != nil {
                logger.info("删除成功: \(decodedPath)")
                continue
            }

            // 2. 通过 AppleScript 让 Finder 删除（备用）
            if deleteViaFinder(path: decodedPath) {
                logger.info("通过 Finder 删除成功: \(decodedPath)")
                continue
            }
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
        let fileName = "\(rcitem.defaultName)\(ext)"
        var fileURL = dirURL.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = dirURL.appendingPathComponent("\(rcitem.defaultName)\(counter)\(ext)")
            counter += 1
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

        // 辅助检测：通过 pluginkit 查询系统扩展状态
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        task.arguments = ["-m", "-p", "com.apple.FinderSync"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // 检查是否包含 +（已启用）且扩展 bundle ID 匹配
            let extBundleID = "cn.anwen.IClick.FinderSyncExt"
            return output.contains("+") && output.contains(extBundleID)
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
