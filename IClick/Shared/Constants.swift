//
//  Constants.swift
//  IClick
//
//  Created by 李旭 on 2024/9/25.
//

import Foundation


public enum Constants {
    static let HomedirPath = Utils.getRealHomeDir()
    /// The identifier for the settings window.
    static let settingsWindowID = "iclick-settings"

    /// Get the app version string.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    /// 系统目录：不属于用户，破坏性或批量操作都不该落在它们头上。
    static let systemDirs = [
        "/Applications/",
        "/System/",
        "/Library/",
        "/Users/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/var/"
    ]

    /// 受保护目录 = 需要保护的用户目录 + 全部系统目录。
    /// 用户目录单独列出来是因为「删除」这类操作落在 ~/Desktop 上同样危险；
    /// 但「隐藏该目录下全部子项」不是 —— 那个只在系统目录上才只可能是误操作，
    /// 所以后者用的是更窄的 systemDirs（见 Utils.isSystemFolder）。
    /// 写成拼接而非手抄两份，是为了结构上保证 systemDirs 恒为 protectedDirs 的子集。
    static let protectedDirs = [
        HomedirPath + "/Desktop/",
        HomedirPath + "/Desktop/danger/",
        HomedirPath + "/Applications/"
    ] + systemDirs
    static let suitName = "group.33WRMMC62L.cn.anwen.IClick"

    enum FullDiskAccessStatus {
        case granted
        case denied
        case unknown
    }

    /// 检测是否拥有完全磁盘访问权限（FDA）。
    ///
    /// 没有官方的 TCC 查询 API。业界通行的做法是实际打开一个受 TCC 保护的
    /// 数据库文件：能读 = 基本可以认为 FDA 已授权；被拒 = 没授权。
    /// 原来的实现检查 `/Library/Preferences`，那个目录普通用户本来就能读，
    /// 所以永远返回 true —— 是个假检测。
    ///
    /// 注意：这是启发式，不是权威结果；不同 macOS 版本保护的文件可能不同。
    /// 返回三态而不是 Bool：两个候选文件都不存在时是 `.unknown`，
    /// 设置页需要把「检测不到」和「明确被拒」区分开。
    static var fullDiskAccessStatus: FullDiskAccessStatus {
        let userDB = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: userDB) {
            return canReadProtectedFile(userDB) ? .granted : .denied
        }
        // 用户级数据库不存在时退到系统级 TCC.db
        let systemDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        if FileManager.default.fileExists(atPath: systemDB) {
            return canReadProtectedFile(systemDB) ? .granted : .denied
        }
        return .unknown
    }

    static var hasFullDiskAccess: Bool {
        fullDiskAccessStatus == .granted
    }

    /// 真正打开并读一个字节 —— 只看 `isReadableFile` 不可靠：
    /// 它不经过 TCC 的读取判定，而且文件存在/权限位可读 ≠ 能读内容。
    private static func canReadProtectedFile(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            _ = try handle.read(upToCount: 1)
            return true
        } catch {
            return false
        }
    }
}
