import AppKit
import Foundation
import UniformTypeIdentifiers
import os.log

public class Utils {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Utils", category: "utils")

    /// 判断路径本身是否是受保护目录（含用户目录，只看自身，不匹配其子项）。
    /// 用于删除等破坏性操作 —— 落在 ~/Desktop 上同样危险。
    public static func isProtectedFolder(_ path: String) -> Bool {
        isFolder(path, in: Constants.protectedDirs)
    }

    /// 判断路径本身是否落在**系统目录**上（只看自身，不匹配其子项）。
    ///
    /// 比 isProtectedFolder 窄：**不含用户目录**（~/Desktop、~/Applications）。
    /// 用于「隐藏该目录下的全部子项」这类批量操作 —— 那在用户自己的目录里是正当需求
    /// （就想要个干净桌面），只有在系统目录上才只可能是误操作。
    /// bd1f356 曾在这里误用 isProtectedFolder，导致桌面上右键「隐藏」变成静默无操作。
    public static func isSystemFolder(_ path: String) -> Bool {
        isFolder(path, in: Constants.systemDirs)
    }

    /// 两个判断共用的规范化 + 比对，避免两处各写一份日后漂移
    private static func isFolder(_ path: String, in list: [String]) -> Bool {
        // 先规范化：展开 ~、折叠 . 与 .. 与重复斜杠，避免 "/System/../System" 这类写法绕过
        let expanded = (path as NSString).expandingTildeInPath
        var normalized = (expanded as NSString).standardizingPath
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        // 空路径无从判断，按危险处理
        if normalized.isEmpty { return true }

        return list.contains { protectedDir in
            var dir = protectedDir
            while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
            // 大小写不敏感：APFS 默认大小写不敏感，/system 与 /System 是同一个目录
            return normalized.compare(dir, options: .caseInsensitive) == .orderedSame
        }
    }

    public static func getRealHomeDir() -> String {
        let fullPath = NSHomeDirectory()
        let components = fullPath.components(separatedBy: "/")
        let limitedComponents = Array(components.prefix(3))
        return limitedComponents.joined(separator: "/")
    }

    /// 以无 Dock 图标（.accessory）身份运行时，NSOpenPanel.runModal() 可能不会
    /// 顶到前面：面板躲在别的窗口后面，用户看到的是「点了按钮没反应」，而且模态
    /// 循环已经占住了应用。这里临时切到 .regular 并激活，关闭后恢复原来的策略。
    /// （CommonDirsSettingTabView 里原本就是这段逻辑，另外几个面板漏了。）
    @MainActor
    static func runOpenPanel(_ configure: (NSOpenPanel) -> Void) -> URL? {
        let oldPolicy = NSApp.activationPolicy()
        if oldPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        configure(panel)
        let response = panel.runModal()

        if oldPolicy != .regular {
            NSApp.setActivationPolicy(oldPolicy)
        }
        return response == .OK ? panel.url : nil
    }

    /// 自定义图标的存放目录。
    ///
    /// 必须落在 **App Group 容器**里。FinderSync 扩展是沙盒进程，读不到
    /// `~/Library/Application Support`（那是主应用的真实路径，不是它的容器），
    /// 图标存在那儿时扩展里的 `NSImage(contentsOfFile:)` 恒为 nil ——
    /// 表现是设置界面里图标正常、Finder 右键菜单里静默变回系统图标。
    /// 扩展的 entitlements 里已经有 group.33WRMMC62L.cn.anwen.IClick 的访问权限。
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` 在这里不能用：主应用**没有**
    /// 沙盒，也就没有该 entitlement，这个 API 会返回 nil，所以直接拼标准路径。
    ///
    /// 返回 nil = 群组容器不可用。此时**不能**退到 Application Support：
    /// 扩展读不到那里，结果就是设置里图标正常、Finder 里静默变回系统图标，
    /// 而且这个坏路径已经被写进配置。宁可让调用方保持原图标，也不制造静默故障。
    static var customIconsDir: URL? {
        let fm = FileManager.default
        let groupDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(Constants.suitName)
        if !fm.fileExists(atPath: groupDir.path) {
            do {
                try fm.createDirectory(at: groupDir, withIntermediateDirectories: true)
            } catch {
                logger.error("App Group 容器不可用，无法保存自定义图标: \(error.localizedDescription)")
                return nil
            }
        }
        return groupDir.appendingPathComponent("CustomIcons")
    }

    /// 从 NSOpenPanel 选择图片并复制到自定义图标目录，返回目标路径
    @MainActor
    @discardableResult
    static func pickAndCopyIcon() -> String? {
        guard let picked = runOpenPanel({ panel in
            panel.title = "选择图标"
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
        }) else { return nil }
        let url = picked

        guard let iconsDir = customIconsDir else { return nil }
        let fm = FileManager.default
        let desired = iconsDir.appendingPathComponent(url.lastPathComponent)

        do {
            try fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)

            // 同名文件不能无条件覆盖：另一个 App / 子菜单可能正引用着这个路径，
            // 用户给 B 选了同名的 icon.png，A 的图标会跟着变。
            // 内容相同就复用原路径；内容不同则换一个唯一的文件名。
            var dest = desired
            if fm.fileExists(atPath: desired.path) {
                // 只有两边都成功读出来且逐字节相同时才复用；任一边读取失败都不能
                // 当成「相同」（nil == nil 会错误地返回一个可能不可用的旧路径）。
                if let old = try? Data(contentsOf: desired),
                   let new = try? Data(contentsOf: url),
                   old == new {
                    return desired.path
                }
                let base = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                var n = 1
                repeat {
                    let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                    dest = iconsDir.appendingPathComponent(name)
                    n += 1
                    if n > 1000 { throw CocoaError(.fileWriteFileExists) }
                } while fm.fileExists(atPath: dest.path)
            }

            try fm.copyItem(at: url, to: dest)
            return dest.path
        } catch {
            // 失败必须返回 nil，不能返回 dest.path。返回路径会让设置里记下一个并不存在
            // 的文件（三个调用点都是 `if let`，nil 会保持原图标不动），
            // 而症状又恰好是「设置界面看着正常、Finder 菜单里变回系统图标」这种静默故障 ——
            // 正是 customIconsDir 那条注释里描述的现象，别再制造一次。
            logger.error("复制自定义图标失败: \(url.path) -> \(error.localizedDescription)")
            return nil
        }
    }
}
