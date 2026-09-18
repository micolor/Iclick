import AppKit
import Foundation
import UniformTypeIdentifiers

public class Utils {
    /// 判断路径本身是否是受保护目录（只看自身，不匹配其子项）
    public static func isProtectedFolder(_ path: String) -> Bool {
        // 先规范化：展开 ~、折叠 . 与 .. 与重复斜杠，避免 "/System/../System" 这类写法绕过
        let expanded = (path as NSString).expandingTildeInPath
        var normalized = (expanded as NSString).standardizingPath
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        // 空路径无从判断，按危险处理
        if normalized.isEmpty { return true }

        return Constants.protectedDirs.contains { protectedDir in
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

    /// 从 NSOpenPanel 选择图片并复制到应用自定义图标目录，返回目标路径
    @MainActor
    @discardableResult
    static func pickAndCopyIcon() -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择图标"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let iconsDir = appSupport.appendingPathComponent("CustomIcons")
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        let dest = iconsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        return dest.path
    }
}
