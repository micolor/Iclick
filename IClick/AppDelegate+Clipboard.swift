//
//  AppDelegate+Clipboard.swift
//  IClick
//
//  复制路径、剪切 / 粘贴：从 IClickApp.swift 拆出，纯移动，不改变行为。
//

import AppKit
import Foundation
import os.log

extension AppDelegate {
    /// 自定义剪切列表。`changeCount` 记录写入时的剪贴板序号：粘贴时若序号变了，
    /// 说明剪切之后又有别的复制操作（Finder Cmd+C、其它 App 拷贝、截图等），
    /// 以最近一次剪贴板操作为准，不再移动旧文件。
    private enum CutKey {
        static let files = Key.actions + ".cut-files"
        static let changeCount = Key.actions + ".cut-files-change-count"
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
        SharedSettings.set(decodedTargets, forKey: CutKey.files)
        // 同时写入选贴板：文件 URL（Finder 可识别） + 路径文本
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = decodedTargets.map { URL(fileURLWithPath: $0) }
        pasteboard.writeObjects(urls as [NSURL])
        // 也保留路径文本作为后备
        let paths = decodedTargets.joined(separator: "\n")
        pasteboard.setString(paths, forType: .string)
        // 记下写完之后（而不是之前）的序号，粘贴时用它判断列表是否已过期
        SharedSettings.set(NSPasteboard.general.changeCount, forKey: CutKey.changeCount)

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

    /// 粘贴文件：支持 IClick 剪切（移动）和系统复制（拷贝）。
    ///
    /// 复制/移动循环放到后台队列：多选大文件时原来整段跑在主线程上，
    /// 期间菜单栏应用完全无响应。剪贴板读取、弹窗、通知仍留在主线程。
    func pasteFromClipboard(_ target: [String], _ trigger: String) {
        logger.info("---- pasteFromClipboard  target:\(target) trigger:\(trigger)")

        guard !isProcessingPaste else {
            logger.warning("pasteFromClipboard 正在处理中，忽略重复请求")
            return
        }

        // 1. 先检查 IClick 自定义剪切存储（移动操作）。
        //    但只有「剪切之后剪贴板没再变过」才用它：用户剪切后又去 Finder 复制了
        //    别的东西（或截图、复制文本），最近一次剪贴板操作才是用户意图，继续
        //    移动旧文件会让人以为粘贴选中了错误的内容。
        var filesToOperate: [String] = []
        var isCutOperation = false

        var cutFiles = SharedSettings.stringArray(forKey: CutKey.files)
        if let files = cutFiles, !files.isEmpty {
            let recordedCount = SharedSettings.integer(forKey: CutKey.changeCount)
            let currentCount = NSPasteboard.general.changeCount
            // recordedCount == 0：旧版本写下的列表没有序号，保持原行为
            if recordedCount != 0, recordedCount != currentCount {
                logger.info("剪切列表已过期，改用系统剪贴板: \(recordedCount) -> \(currentCount)")
                DiagnosticLog.shared.write("cut stale recorded=\(recordedCount) current=\(currentCount)")
                SharedSettings.removeObject(forKey: CutKey.files)
                SharedSettings.removeObject(forKey: CutKey.changeCount)
                cutFiles = nil
            }
        }
        if let cutFiles, !cutFiles.isEmpty {
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
        let destBaseURL = URL(fileURLWithPath: rawDest)
        try? FileManager.default.createDirectory(at: destBaseURL, withIntermediateDirectories: true)

        isProcessingPaste = true
        let files = filesToOperate
        let isCut = isCutOperation
        // 外层闭包也用 [weak self]：否则它为了把 self 递进内层闭包会隐式强持有
        // AppDelegate，与内层的 weak 不一致（Swift 6 会给出 ImplicitStrongCapture 警告）。
        // 后台工作本身只依赖值类型，用显式类型名调用静态方法。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = AppDelegate.performPaste(files: files, destBaseURL: destBaseURL, isCut: isCut)

            // 清理 IClick 自定义剪切存储（在后台完成，主线程忙时也不会残留）。
            // 只保留移动失败的项：成功的源文件已经不在原位，留在列表里下次粘贴
            // 只会再报一次失败；失败项留着则可以直接再粘贴重试。
            // 剪贴板没有变化，之前记录的 changeCount 仍然有效。
            if isCut {
                let failedSet = Set(result.failedPaths)
                let remaining = files.filter { failedSet.contains($0) }
                if remaining.isEmpty {
                    SharedSettings.removeObject(forKey: CutKey.files)
                    SharedSettings.removeObject(forKey: CutKey.changeCount)
                } else {
                    SharedSettings.set(remaining, forKey: CutKey.files)
                }
            }

            DispatchQueue.main.async {
                self?.isProcessingPaste = false
                self?.deliverPasteNotification(success: result.success, failed: result.failed, isCut: isCut)
            }
        }
    }

    /// 后台执行复制/移动。只依赖传入值，不读写任何 MainActor 状态。
    nonisolated private static func performPaste(
        files: [String],
        destBaseURL: URL,
        isCut: Bool
    ) -> (success: Int, failed: Int, failedPaths: [String]) {
        let fm = FileManager.default
        // AppDelegate 的 @AppLog 实例属性是 MainActor 隔离的，后台用同 subsystem/
        // category 的局部 Logger，日志归属不变。
        let log = Logger(subsystem: subsystem, category: "AppDelegate")
        var successCount = 0
        var failCount = 0
        var failedPaths: [String] = []

        for filePath in files {
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
                if isCut {
                    try fm.moveItem(at: sourceURL, to: finalURL)
                    log.info("移动成功: \(filePath) → \(finalURL.path)")
                } else {
                    try fm.copyItem(at: sourceURL, to: finalURL)
                    log.info("复制成功: \(filePath) → \(finalURL.path)")
                }
                successCount += 1
            } catch {
                failCount += 1
                failedPaths.append(filePath)
                log.error("\(isCut ? "移动" : "复制")失败: \(filePath) -> \(error.localizedDescription)")
                DiagnosticLog.shared.write(
                    "paste failed op=\(isCut ? "move" : "copy") path=\(filePath) "
                    + "dest=\(finalURL.path) err=\((error as NSError).code) \(error.localizedDescription)"
                )
            }
        }

        return (successCount, failCount, failedPaths)
    }

    @MainActor
    private func deliverPasteNotification(success: Int, failed: Int, isCut: Bool) {
        if failed == 0 {
            deliverNotification(
                title: isCut ? "粘贴完成" : "复制完成",
                informativeText: isCut
                    ? "已移动 \(success) 项到目标目录"
                    : "已复制 \(success) 项到目标目录"
            )
        } else {
            deliverNotification(
                title: isCut ? "粘贴完成（部分失败）" : "复制完成（部分失败）",
                informativeText: "成功 \(success) 项，失败 \(failed) 项"
            )
        }
    }
}
