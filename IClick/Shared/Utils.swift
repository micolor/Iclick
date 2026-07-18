import AppKit
import Foundation
import UniformTypeIdentifiers

public class Utils {
    public static func isProtectedFolder(_ path: String) -> Bool {
        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        // 只检查路径本身是否是受保护目录，而不是检查是否在受保护目录下
        return Constants.protectedDirs.contains { protectedDir in
            normalizedPath == protectedDir || normalizedPath == protectedDir + "/"
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
