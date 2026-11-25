//
//  AppDelegate+Open.swift
//  IClick
//
//  打开目录 / 打开应用：从 IClickApp.swift 拆出，纯移动，不改变行为。
//

import AppKit
import Foundation
import os.log

extension AppDelegate {
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
            DiagnosticLog.shared.write("open-dir missing path=\(path)")
            return false
        }

        // 第 1 层：NSWorkspace.open
        if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            return true
        }

        // 第 2 层：/usr/bin/open。
        // 不在主线程 waitUntilExit：它没有超时，LaunchServices 一旦卡住就会把
        // 整个应用（连同设置窗口）一起钉住。调用方也不依赖这里的返回值。
        logger.debug("NSWorkspace.open 失败，回退 /usr/bin/open: \(path, privacy: .public)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [path]
        task.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                DiagnosticLog.shared.write("open-dir failed path=\(path) exit=\(proc.terminationStatus)")
                Logger(subsystem: subsystem, category: "AppDelegate")
                    .error("回退 open 失败 \(path, privacy: .public), exit \(proc.terminationStatus)")
            }
        }
        do {
            try task.run()
            return true
        } catch {
            logger.error("打开目录失败 \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            DiagnosticLog.shared.write(
                "open-dir failed path=\(path) err=\((error as NSError).code) \(error.localizedDescription)"
            )
            return false
        }
    }

    // MARK: - 打开应用

    func openApp(rid: String, target: [String]) {
        var rcitem = appState.getAppItem(rid: rid)
        if rcitem == nil {
            // 菜单是扩展按「推送快照」建的，主应用内存里的列表可能已经过期：
            // 同一个 bundle 的另一个副本（旧构建、登录项拉起的旧版）改写了
            // SharedSettings.plist，但本进程只在启动时读过一次。现象就是
            // 「右键菜单里有这个 App，点了没反应」。
            // 从磁盘重读一次再匹配，不要求用户重启应用。
            logger.info("openApp: 内存中没有 rid，从磁盘重读配置后重试")
            appState.refresh()
            rcitem = appState.getAppItem(rid: rid)
        }
        guard let rcitem else {
            logger.warning("openApp: app not found \(rid)")
            DiagnosticLog.shared.write("open not-found rid=\(rid)")
            // 重读磁盘后仍然找不到：说明配置里已经没有这个 App（被删掉，或菜单是
            // 很久以前的旧快照）。只写日志用户只会看到「点了没反应」，给一条通知。
            deliverNotification(
                title: "打开失败",
                informativeText: "找不到要打开的应用。请打开 IClick 设置，确认「常用 App」里这一项仍然存在。"
            )
            return
        }

        let paths = target.map { $0.removingPercentEncoding ?? $0 }
        guard !paths.isEmpty else { return }

        // 应用解析、Info.plist 读取、启动都只做一次。原来是在 target 循环里逐个做：
        // 选中 20 个文件 = 20 次 LaunchServices 查询 + 20 次 Info.plist 读取 +
        // 20 个 /usr/bin/open 进程 + 20 次 0.5 秒延迟。
        let appURL = resolveAppURL(rcitem.url)
        let appName = appURL.deletingPathExtension().lastPathComponent
        let bundleID = readBundleIdentifier(from: appURL)
        let log = logger
        log.info("打开: \(paths.joined(separator: ", ")), 应用: \(appName), bundleID: \(bundleID ?? "nil")")
        DiagnosticLog.shared.write("open app=\(appName) targets=\(paths.count)")

        let config = NSWorkspace.OpenConfiguration()
        config.promptsUserIfNeeded = false
        config.arguments = rcitem.arguments
        config.environment = rcitem.environment

        // 启动应用和交付目标项必须走同一个 open 事件。
        //
        // 原来是两步：先 openApplication 启动应用，0.5 秒后再用 /usr/bin/open -b
        // 把路径交给它。对 Terminal 这类「启动就开一个窗口」的应用，两步就是两次
        // 开窗：应用当时没有窗口时，第一步的 reopen 先开一个空白窗口，第二步再开
        // 目标目录的窗口——用户看到的就是「点一次，打开两次」。
        //
        // NSWorkspace.open(_:withApplicationAt:) 在同一个 LaunchServices 事件里
        // 启动应用并交付全部目标项，冷启动只产生一个窗口；它和 openApplication
        // 一样是沙箱兼容的 API。
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config) { runningApp, error in
            if let error = error {
                log.warning("NSWorkspace 打开失败，回退 /usr/bin/open: \(error.localizedDescription)")
                DiagnosticLog.shared.write(
                    "open fallback app=\(appName) error=\(error.localizedDescription)"
                )
                Self.sendTargetsWithOpenCLI(
                    appURL: appURL,
                    bundleID: bundleID,
                    appName: appName,
                    appArguments: rcitem.arguments,
                    environment: rcitem.environment,
                    paths: paths
                )
                return
            }
            log.info("已在 \(runningApp?.localizedName ?? appName) 中打开 \(urls.count) 项")
            DiagnosticLog.shared.write("open ok app=\(appName) targets=\(urls.count)")
        }
    }

    /// 回退路径：用 /usr/bin/open 把全部目标项交给应用。
    ///
    /// 只在 NSWorkspace.open 报错时走到这里（应用无法启动、或 LaunchServices
    /// 不接受这个应用 URL）。多选时只起一个进程，而不是每个文件一个。
    /// 路径仍然交不出去时，退回到旧行为：至少把应用本身启动起来。
    nonisolated private static func sendTargetsWithOpenCLI(
        appURL: URL,
        bundleID: String?,
        appName: String,
        appArguments: [String],
        environment: [String: String],
        paths: [String]
    ) {
        let log = Logger(subsystem: subsystem, category: "AppDelegate")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = bundleID.map { ["-b", $0] } ?? ["-a", appName]
        arguments.append(contentsOf: paths)
        process.arguments = arguments
        process.terminationHandler = { proc in
            if proc.terminationStatus == 0 {
                log.info("回退 open 成功: \(appName) \(paths.count) 项")
                DiagnosticLog.shared.write("open fallback ok app=\(appName) targets=\(paths.count)")
                return
            }

            log.error("回退 open 失败, exit code: \(proc.terminationStatus)")
            DiagnosticLog.shared.write(
                "open fallback failed app=\(appName) targets=\(paths.count) "
                + "exit=\(proc.terminationStatus)"
            )

            // 目标项交不出去（应用不支持这种类型、被移动/删除、签名损坏）时，
            // 旧行为是「应用照常启动、路径发送失败」。保持这一点：只启动应用。
            let config = NSWorkspace.OpenConfiguration()
            config.promptsUserIfNeeded = false
            config.arguments = appArguments
            config.environment = environment
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                if let error {
                    log.error("单独启动应用也失败: \(appName), \(error.localizedDescription)")
                    DiagnosticLog.shared.write(
                        "open launch-only failed app=\(appName) error=\(error.localizedDescription)"
                    )
                    AppDelegate.postUserNotification(
                        title: "打开失败",
                        informativeText: "无法启动「\(appName)」：\(error.localizedDescription)"
                    )
                } else {
                    log.info("目标项未能交付，已单独启动: \(appName)")
                    DiagnosticLog.shared.write("open launch-only app=\(appName)")
                }
            }
        }
        do {
            try process.run()
        } catch {
            log.error("启动 /usr/bin/open 失败: \(error.localizedDescription)")
            DiagnosticLog.shared.write(
                "open fallback spawn failed app=\(appName) err=\((error as NSError).code)"
            )
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
}
