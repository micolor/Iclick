//
//  AppDelegate+Hide.swift
//  IClick
//
//  隐藏 / 取消隐藏：从 IClickApp.swift 拆出，纯移动，不改变行为。
//

import AppKit
import Foundation
import os.log

extension AppDelegate {
    /// 批量设置 hidden 标志的结果（后台线程 → 主线程传递）。
    /// 只包含 Sendable 值，避免把 Error / URL 之类的对象跨队列传递。
    private struct HiddenOutcome: Sendable {
        var readError: String?
        var failed: Int = 0
        var total: Int = 0
        var firstError: String?
    }

    // 显示目标文件夹下的隐藏的所有文件和文件夹
    func unhideFilesAndDirs(_ target: [String], _ trigger: String) {
        logger.info("开始取消隐藏文件和目录，目标路径: \(target), 触发器: \(trigger)")
        let decodedTarget = target.map { $0.removingPercentEncoding ?? $0 }

        if trigger == "ctx-items" {
            setHiddenFlags(paths: decodedTarget, hidden: false)
        } else {
            guard let dirPath = decodedTarget.first else { return }
            setDirContentsHidden(dirPath: dirPath, hidden: false)
        }
    }

    // 隐藏目标文件或文件夹
    func hideFilesAndDirs(_ target: [String], _ trigger: String) {
        logger.info("开始隐藏文件和目录，目标路径: \(target), 触发器: \(trigger)")
        let decodedTarget = target.map { $0.removingPercentEncoding ?? $0 }

        if trigger == "ctx-items" {
            // 受保护路径的拦截留在主线程（纯字符串比较，不涉及 I/O）；
            // 真正逐个写 hidden 标志的部分移到后台。
            let allowed = decodedTarget.filter { path in
                if Utils.isProtectedFolder(path) {
                    logger.warning("跳过受保护的文件路径: \(path)")
                    DiagnosticLog.shared.write("hide blocked protected path=\(path)")
                    return false
                }
                return true
            }
            setHiddenFlags(paths: allowed, hidden: true)
        } else {
            guard let dirPath = decodedTarget.first else { return }
            // 容器菜单（在文件夹空白处右键）走这条分支：会批量改该目录下
            // **所有**子项的 hidden 标志。上面 ctx-items 分支拦了受保护路径，这里漏了——
            // 对 /Applications 这类目录执行，Finder 里看起来就像被清空了。
            //
            // 这里必须用更窄的 isSystemFolder，**不能用 isProtectedFolder**：
            // 后者含 ~/Desktop、~/Applications，而「把桌面图标收起来」是正当需求，
            // 拦掉就变成静默无操作（bd1f356 就是这么越界的）。
            // 注：unhide 有意不加这道拦截，它是「误隐藏」之后的恢复路径，
            // 拦掉反而会把人困住。
            if Utils.isSystemFolder(dirPath) {
                logger.warning("跳过系统目录，不对其内容做整体隐藏: \(dirPath)")
                DiagnosticLog.shared.write("hide blocked system dir=\(dirPath)")
                return
            }
            setDirContentsHidden(dirPath: dirPath, hidden: true)
        }
    }

    /// 设置目录下所有内容的隐藏状态（不含目录自身）。
    ///
    /// 枚举与逐个 setResourceValues 都放到后台队列：一个目录可能有上万个条目，
    /// 这段原本整段跑在主线程上，大目录会让整个应用（包括设置窗口）卡住。
    /// 日志与汇总回到主线程写。
    private func setDirContentsHidden(dirPath: String, hidden: Bool) {
        let dir = URL(fileURLWithPath: dirPath)
        // 外层也 weak：内层闭包要 weak self，外层不声明就会为了传递而隐式强持有
        // AppDelegate（Swift 6 的 ImplicitStrongCapture 警告）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = AppDelegate.applyHiddenToDirectoryContents(dir: dir, hidden: hidden)
            DispatchQueue.main.async {
                self?.reportHiddenOutcome(outcome, scope: dirPath, hidden: hidden)
            }
        }
    }

    /// 批量设置一组路径的 hidden 标志（后台执行，逐项容错）。
    private func setHiddenFlags(paths: [String], hidden: Bool) {
        guard !paths.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let log = Logger(subsystem: subsystem, category: "AppDelegate")
            var outcome = HiddenOutcome(failed: 0, total: paths.count, firstError: nil)

            for path in paths {
                do {
                    var fileURL = URL(fileURLWithPath: path)
                    var values = URLResourceValues()
                    values.isHidden = hidden
                    try fileURL.setResourceValues(values)
                } catch {
                    outcome.failed += 1
                    if outcome.firstError == nil {
                        outcome.firstError = "\((error as NSError).code) \(error.localizedDescription)"
                    }
                    // 隐藏标志要改父目录 / 文件本身，TCC、只读卷、权限不足都会走这里。
                    // 以前只打 .debug（默认不落盘），用户看到的就是「点了没反应」。
                    log.warning("setResourceValues 失败: \(path), error: \(error.localizedDescription)")
                    DiagnosticLog.shared.write(
                        "hidden failed path=\(path) hidden=\(hidden) err=\((error as NSError).code) \(error.localizedDescription)"
                    )
                }
            }

            DispatchQueue.main.async {
                self?.reportHiddenOutcome(outcome, scope: "\(paths.count) 项", hidden: hidden)
            }
        }
    }

    /// 后台：枚举目录内容并逐个设置 hidden。每个条目单独 try ——
    /// 只读卷、或没有父目录写权限时，第一项失败不应中止后面的条目。
    nonisolated private static func applyHiddenToDirectoryContents(
        dir: URL,
        hidden: Bool
    ) -> HiddenOutcome {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]
            )
        } catch {
            return HiddenOutcome(
                readError: "\((error as NSError).code) \(error.localizedDescription)",
                failed: 0,
                total: 0,
                firstError: nil
            )
        }

        var outcome = HiddenOutcome(failed: 0, total: contents.count, firstError: nil)
        for case var fileURL in contents {
            var values = URLResourceValues()
            values.isHidden = hidden
            do {
                try fileURL.setResourceValues(values)
            } catch {
                outcome.failed += 1
                if outcome.firstError == nil {
                    outcome.firstError = "\((error as NSError).code) \(error.localizedDescription)"
                    DiagnosticLog.shared.write(
                        "dir-hidden item failed dir=\(dir.path) path=\(fileURL.path) "
                        + "err=\((error as NSError).code) \(error.localizedDescription)"
                    )
                }
            }
        }
        return outcome
    }

    /// 主线程：把后台批量操作的结果写进日志。
    @MainActor
    private func reportHiddenOutcome(_ outcome: HiddenOutcome, scope: String, hidden: Bool) {
        let action = hidden ? "隐藏" : "取消隐藏"
        if let readError = outcome.readError {
            logger.warning("读取目录内容失败: \(scope), \(readError)")
            DiagnosticLog.shared.write("dir-hidden read failed dir=\(scope) err=\(readError)")
            return
        }
        if outcome.failed > 0 {
            logger.warning("\(action)失败 \(outcome.failed)/\(outcome.total) 项: \(scope)")
            DiagnosticLog.shared.write(
                "dir-hidden failed scope=\(scope) hidden=\(hidden) "
                + "failed=\(outcome.failed)/\(outcome.total) err=\(outcome.firstError ?? "")"
            )
        } else {
            logger.info("\(action)完成 \(outcome.total) 项: \(scope)")
        }
    }
}
