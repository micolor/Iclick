//
//  AppDelegate+Delete.swift
//  IClick
//
//  移入废纸篓（失败回退 Finder AppleScript）：从 IClickApp.swift 拆出，纯移动。
//

import AppKit
import Foundation
import os.log

extension AppDelegate {
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
    /// 而动作经 IPC 进入后已切到 MainActor，始终在主线程串行执行。
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
                DiagnosticLog.shared.write("delete blocked protected path=\(decodedPath)")
                continue
            }

            // 1. 移入废纸篓（可恢复），不再用 removeItem 做不可逆的永久删除
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: decodedPath), resultingItemURL: nil)
                logger.info("已移入废纸篓: \(decodedPath)")
                continue
            } catch {
                logger.warning("移入废纸篓失败，回退 Finder: \(decodedPath), error: \(error.localizedDescription)")
                DiagnosticLog.shared.write(
                    "trash failed path=\(decodedPath) err=\((error as NSError).code) \(error.localizedDescription)"
                )
            }

            // 2. 通过 AppleScript 让 Finder 删除（同样进废纸篓）
            if deleteViaFinder(path: decodedPath) {
                logger.info("通过 Finder 删除成功: \(decodedPath)")
                continue
            }

            failedItems.append(decodedPath)
            DiagnosticLog.shared.write("delete failed path=\(decodedPath)")
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
}
