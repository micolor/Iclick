//
//  AppDelegate+FileActions.swift
//  IClick
//
//  AirDrop 分享与新建文件：从 IClickApp.swift 拆出，纯移动，不改变行为。
//

import AppKit
import Foundation
import os.log

extension AppDelegate {
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

    func createFile(rid: String, target: [String]) {
        logger.info("createFile called with rid: \(rid), target: \(target)")
        guard let rcitem = appState.getFileType(rid: rid), let dirPath = target.first else {
            logger.warning("createFile: file type not found \(rid)")
            // 配置里没有这个文件类型（旧菜单快照 / 用户刚重置过），别让点击静默消失
            deliverNotification(
                title: "创建文件失败",
                informativeText: "找不到要创建的文件类型。请打开 IClick 设置确认「新建文件」列表。"
            )
            return
        }
        let decodedDir = dirPath.removingPercentEncoding ?? dirPath

        // 右键「选中文件」时走的是 .contextualMenuForItems，target 拿到的是那个文件本身。
        // 直接当目录用会拼出 /path/a.txt/未命名.txt，copyItem/write 抛 ENOTDIR，
        // 而返回值又被调用方丢弃 —— 界面上毫无反馈，文件就是没建出来。
        // 非目录时退到它所在的目录，与 pasteFromClipboard 对文件的处理保持一致。
        var dirURL = URL(fileURLWithPath: decodedDir)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            dirURL = dirURL.deletingLastPathComponent()
        }

        if !doCreateFile(in: dirURL, rcitem: rcitem, ext: rcitem.ext) {
            // 只读目录、没有写权限、模板文件丢失都会走到这里。原来返回值被丢弃，
            // 界面上完全没有反馈。
            deliverNotification(
                title: "创建文件失败",
                informativeText: "无法在「\(dirURL.lastPathComponent)」中创建 \(rcitem.defaultName)\(rcitem.ext)。"
            )
        }
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
            DiagnosticLog.shared.write("create ok \(fileURL.path)")
            return true
        } catch {
            logger.error("文件创建失败: \(fileURL.path), error: \(error.localizedDescription)")
            DiagnosticLog.shared.write("create failed \(fileURL.path) error=\(error.localizedDescription)")
            return false
        }
    }
}
