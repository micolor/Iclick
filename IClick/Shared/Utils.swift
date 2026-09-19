import AppKit
import Foundation
import UniformTypeIdentifiers

public class Utils {
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
    static var customIconsDir: URL {
        let groupDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(Constants.suitName)
        if FileManager.default.fileExists(atPath: groupDir.path) {
            return groupDir.appendingPathComponent("CustomIcons")
        }
        // 容器不存在（异常情况）时退回原位置：至少不比改动前更差
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CustomIcons")
    }

    /// 从 NSOpenPanel 选择图片并复制到自定义图标目录，返回目标路径
    @MainActor
    @discardableResult
    static func pickAndCopyIcon() -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择图标"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let iconsDir = customIconsDir
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        let dest = iconsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        return dest.path
    }
}
